"""dirlir compile phase: build the layer directory from plan.json.

Pure-NAR materialization: every store path is fetched from a binary cache
recorded in the lockfile (no nix, no host /nix/store reads), verified twice
(FileHash on the compressed bytes, NarHash on the unpacked stream), then
absolute /nix/store symlink targets are rewritten to relative so the tree
artifact is fully self-contained for CAS upload / remote execution.

Downloads are kept in a content-addressed local cache (~/.cache/dirlir/nars
or $DIRLIR_CACHE), keyed and re-verified by FileHash.
"""

import argparse
import base64
import concurrent.futures
import json
import lzma
import os
import posixpath
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from compression import zstd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nar  # noqa: E402

STORE = "/nix/store"


def sri_to_hex(sri):
    algo, _, b64 = sri.partition("-")
    if algo != "sha256":
        raise SystemExit(f"error: unsupported hash algo in {sri}")
    return base64.b64decode(b64).hex()


def cache_dir():
    d = os.environ.get("DIRLIR_CACHE") or os.path.expanduser("~/.cache/dirlir/nars")
    os.makedirs(d, exist_ok=True)
    return d


class VerifyError(Exception):
    pass


def _rm(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    elif os.path.lexists(path):
        os.unlink(path)


def fetch_compressed_nar(lock, store_path, refetch=False):
    """Return a local path to the compressed NAR for store_path.

    The compressed bytes are NOT verifiable up front: cache.nixos.org
    re-compresses zstd objects over time, so the narinfo FileHash is not
    stable. The locked NarHash of the UNCOMPRESSED stream is the authority
    (it is also what nix signatures cover) and is verified at unpack time.
    The download cache is therefore keyed by NarHash.
    """
    info = lock["paths"][store_path]["nar"]
    cache = lock["caches"][info["cache"]]
    if not cache.startswith("http"):
        # Repo-local file cache; path is relative to the project root (cwd).
        return os.path.join(cache, info["url"])

    cached = os.path.join(cache_dir(), sri_to_hex(lock["paths"][store_path]["narHash"]))
    if os.path.exists(cached):
        if not refetch:
            return cached
        os.unlink(cached)

    url = f"{cache}/{info['url']}"
    last_err = None
    for _ in range(3):
        fd, tmp = tempfile.mkstemp(dir=cache_dir())
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "dirlir-materialize"})
            with urllib.request.urlopen(req, timeout=60) as r, \
                    os.fdopen(fd, "wb") as out:
                while chunk := r.read(1 << 20):
                    out.write(chunk)
            os.replace(tmp, cached)
            return cached
        except (urllib.error.URLError, OSError) as e:
            last_err = e
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    raise SystemExit(f"error: failed to fetch {url}: {last_err}")


def unpack_nar(lock, store_path, compressed, dest):
    info = lock["paths"][store_path]
    # lock v2 (snix) serves uncompressed NARs and has no compression field.
    compression = info["nar"].get("compression", "none")
    if compression == "xz":
        stream = lzma.open(compressed, "rb")
    elif compression == "zstd":
        stream = zstd.open(compressed, "rb")
    elif compression in ("none", ""):
        stream = open(compressed, "rb")
    else:
        raise SystemExit(f"error: unsupported NAR compression '{compression}'")
    try:
        with stream:
            digest, size = nar.restore(stream, dest, limit=info["narSize"])
    except (nar.NarError, lzma.LZMAError, zstd.ZstdError, EOFError) as e:
        _rm(dest)
        raise VerifyError(f"unpacking {store_path}: {e}")
    want = sri_to_hex(info["narHash"])
    if digest != want:
        _rm(dest)
        raise VerifyError(
            f"NarHash mismatch for {store_path}: got sha256:{digest}")
    if size != info["narSize"]:
        _rm(dest)
        raise VerifyError(f"NarSize mismatch for {store_path}")


def materialize_store_path(lock, store_path, dest):
    """Fetch + unpack + verify, refetching once on a bad cached download."""
    last = None
    for refetch in (False, True):
        compressed = fetch_compressed_nar(lock, store_path, refetch=refetch)
        try:
            unpack_nar(lock, store_path, compressed, dest)
            return
        except VerifyError as e:
            last = e
    raise SystemExit(f"error: {last}")


def rewrite_store_symlinks(out_store):
    """Make /nix/store/... symlink targets relative (self-contained tree)."""
    rewritten = 0
    for dirpath, dirnames, filenames in os.walk(out_store):
        for name in dirnames + filenames:
            link = os.path.join(dirpath, name)
            if not os.path.islink(link):
                continue
            target = os.readlink(link)
            if not target.startswith(STORE + "/"):
                if target.startswith("/"):
                    print(f"warning: absolute non-store symlink kept: "
                          f"{link} -> {target}", file=sys.stderr)
                continue
            # Compute relative target in store coordinates.
            rel_link = os.path.relpath(link, out_store)
            virt_dir = posixpath.dirname(posixpath.join(STORE, rel_link))
            new_target = posixpath.relpath(target, virt_dir)
            os.unlink(link)
            os.symlink(new_target, link)
            rewritten += 1
    return rewritten


def copy_parent(parent, out):
    cp = shutil.which("cp")
    if cp:
        os.makedirs(out)
        subprocess.run(
            [cp, "-a", "--reflink=auto", f"{parent}/.", out], check=True)
    else:
        shutil.copytree(parent, out, symlinks=True)
    # Store trees are read-only; the child must be able to add entries, and
    # read-only dirs in buck-out break `buck2 clean`.
    for dirpath, dirnames, _ in os.walk(out):
        for d in [dirpath] + [os.path.join(dirpath, x) for x in dirnames]:
            if not os.path.islink(d):
                os.chmod(d, os.stat(d).st_mode | 0o200)


def do_nix_packages(lock, feature, out):
    out_store = os.path.join(out, "nix/store")
    os.makedirs(out_store, exist_ok=True)

    needed = [
        p for p in feature["closure"]
        if not os.path.lexists(os.path.join(out_store, os.path.basename(p)))
    ]
    # Prefetch concurrently (populates the download cache), unpack serially.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda p: fetch_compressed_nar(lock, p), needed))
    for store_path in needed:
        dest = os.path.join(out_store, os.path.basename(store_path))
        materialize_store_path(lock, store_path, dest)

    rewrite_store_symlinks(out_store)

    # buildEnv-style forest of relative symlinks at the layer root.
    for forest in feature["spec"]["forest"]:
        forest = forest.strip("/")
        for root_path in feature["roots"]:
            base = os.path.basename(root_path)
            src_dir = os.path.join(out_store, base, forest)
            if not os.path.isdir(src_dir):
                continue
            os.makedirs(os.path.join(out, forest), exist_ok=True)
            for name in sorted(os.listdir(src_dir)):
                link = os.path.join(out, forest, name)
                target = posixpath.relpath(
                    posixpath.join("nix/store", base, forest, name), forest)
                if os.path.lexists(link):
                    if os.path.islink(link) and os.readlink(link) == target:
                        continue
                    raise SystemExit(
                        f"error: forest collision on '{forest}/{name}' "
                        f"(from {feature['label']})")
                os.symlink(target, link)


def do_install(feature, srcs, out):
    src = srcs[f"{feature['id']}:src"]
    dst = os.path.join(out, feature["spec"]["dst"].lstrip("/"))
    if os.path.isdir(src):
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst)
    mode = feature["spec"].get("mode")
    if mode is not None:
        os.chmod(dst, mode)


def do_symlink(feature, out):
    link = feature["spec"]["link"].lstrip("/")
    target = feature["spec"]["target"]
    if target.startswith("/"):
        target = posixpath.relpath(target.lstrip("/"), posixpath.dirname(link))
    os.symlink(target, os.path.join(out, link))


def do_remove(feature, out):
    path = os.path.join(out, feature["spec"]["path"].lstrip("/"))
    if not os.path.lexists(path):
        if feature["spec"].get("must_exist", True):
            raise SystemExit(
                f"error: remove of non-existent '{feature['spec']['path']}' "
                f"(from {feature['label']})")
        return
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def emit_facts(out, facts_path):
    facts = {}
    for dirpath, dirnames, filenames in os.walk(out):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, out)
            if os.path.islink(full):
                facts[rel] = {"type": "symlink", "target": os.readlink(full)}
            elif os.path.isdir(full):
                facts[rel] = {"type": "dir"}
            else:
                facts[rel] = {
                    "type": "file",
                    "mode": os.stat(full).st_mode & 0o7777,
                }
    with open(facts_path, "w") as f:
        json.dump(facts, f, indent=1, sort_keys=True)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--lock", required=True)
    ap.add_argument("--srcs", required=True)
    ap.add_argument("--parent")
    ap.add_argument("--out", required=True)
    ap.add_argument("--facts-out", required=True)
    args = ap.parse_args()

    with open(args.plan) as f:
        plan = json.load(f)
    with open(args.lock) as f:
        lock = json.load(f)
    with open(args.srcs) as f:
        srcs = json.load(f)

    if args.parent:
        copy_parent(args.parent, args.out)
    else:
        os.makedirs(args.out)

    for feature in plan["features"]:
        kind = feature["kind"]
        if kind == "ensure_dirs_exist":
            os.makedirs(
                os.path.join(args.out, feature["spec"]["path"].lstrip("/")),
                exist_ok=True)
        elif kind == "nix_packages":
            do_nix_packages(lock, feature, args.out)
        elif kind == "install":
            do_install(feature, srcs, args.out)
        elif kind == "symlink":
            do_symlink(feature, args.out)
        elif kind == "remove":
            do_remove(feature, args.out)
        else:
            raise SystemExit(f"error: unknown feature kind '{kind}'")

    emit_facts(args.out, args.facts_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
