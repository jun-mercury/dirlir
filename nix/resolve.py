#!/usr/bin/env python3
"""Generate nix/lock.json and nix/lock.bzl from the flake-pinned nixpkgs.

This is the dirlir analog of antlir2's RPM snapshot + versionlock: run it
once (and re-run to bump packages), commit the outputs. Buck2 build actions
never evaluate nix -- they fetch NARs from binary caches using the hashes
recorded here.

Resolution is evaluation-only for nixpkgs attrs: output store paths come
from `nix eval` against this repo's flake.lock, and the closure is walked
through .narinfo files on cache.nixos.org. That walk doubles as the
guarantee that every path is fetchable at materialize time (a missing
narinfo fails resolution, not some later build).

Flake-local packages (passed as `.#name`, e.g. `.#nix-store-shim`) are not
on the public cache: they are built locally and pushed into the committed
repo-local file cache at nix/cache/.

usage: python3 nix/resolve.py [--check] ATTR...
       (from the repo root, with `nix` on PATH; e.g. via `nix develop`)
"""

import argparse
import base64
import concurrent.futures
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

SYSTEM = "x86_64-linux"
CACHES = ["https://cache.nixos.org", "nix/cache"]  # nix/cache is repo-relative
STORE = "/nix/store"

NIX32_ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"


def nix32_decode(s: str) -> bytes:
    """Decode nix's little-endian base32 (as used in narinfo hashes)."""
    out_len = len(s) * 5 // 8
    res = bytearray(out_len)
    for i, c in enumerate(reversed(s)):
        digit = NIX32_ALPHABET.index(c)
        b = i * 5
        j, k = b // 8, b % 8
        res[j] |= (digit << k) & 0xFF
        rest = digit >> (8 - k)
        if j + 1 < out_len:
            res[j + 1] |= rest
        elif rest:
            raise ValueError(f"invalid nix base32 string: {s}")
    return bytes(res)


def to_sri(hash_str: str) -> str:
    """Normalize 'sha256:<nix-base32>' (narinfo) to SRI 'sha256-<base64>'."""
    if hash_str.startswith("sha256-"):
        return hash_str
    algo, _, rest = hash_str.partition(":")
    if algo != "sha256":
        raise ValueError(f"unsupported hash algo: {hash_str}")
    return "sha256-" + base64.b64encode(nix32_decode(rest)).decode()


def repo_root() -> str:
    return subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def nix(*args: str) -> str:
    res = subprocess.run(
        ["nix", "--extra-experimental-features", "nix-command flakes", *args],
        check=True, capture_output=True, text=True,
    )
    return res.stdout


def eval_nixpkgs_attrs(attrs: list) -> dict:
    """One nix eval for all nixpkgs attrs -> {attr: {default, outputs}}."""
    if not attrs:
        return {}
    names = " ".join(f'"{a}"' for a in attrs)
    apply = (
        "pkgs: builtins.listToAttrs (map (n: { name = n; value = "
        "let p = pkgs.${n}; in { default = p.outPath; outputs = "
        "builtins.listToAttrs (map (o: { name = o; value = p.${o}.outPath; }) "
        f"p.outputs); }}; }}) [ {names} ])"
    )
    out = nix("eval", "--json", f".#legacyPackages.{SYSTEM}", "--apply", apply)
    return json.loads(out)


def eval_flake_package(name: str) -> dict:
    apply = (
        "p: { default = p.outPath; outputs = builtins.listToAttrs "
        "(map (o: { name = o; value = p.${o}.outPath; }) p.outputs); }"
    )
    out = nix("eval", "--json", f".#{name}", "--apply", apply)
    return json.loads(out)


def parse_narinfo(text: str) -> dict:
    fields = {}
    for line in text.splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def fetch_narinfo(root: str, store_path: str):
    """Try each cache in order; return (cache_index, narinfo_fields) or None."""
    hashpart = os.path.basename(store_path)[:32]
    for idx, cache in enumerate(CACHES):
        if cache.startswith("http"):
            url = f"{cache}/{hashpart}.narinfo"
            req = urllib.request.Request(url, headers={"User-Agent": "dirlir-resolve"})
            for _ in range(3):
                try:
                    with urllib.request.urlopen(req, timeout=30) as f:
                        return idx, parse_narinfo(f.read().decode())
                except urllib.error.HTTPError as e:
                    if e.code == 404:
                        break
                except urllib.error.URLError:
                    continue
        else:
            path = os.path.join(root, cache, f"{hashpart}.narinfo")
            if os.path.exists(path):
                with open(path) as f:
                    return idx, parse_narinfo(f.read())
    return None


def walk_closure(root: str, roots: list) -> dict:
    """BFS the closure of `roots` via narinfo References -> paths table."""
    paths = {}
    pending = set(roots)
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        while pending:
            batch = sorted(pending)
            pending.clear()
            for store_path, result in zip(
                batch, pool.map(lambda p: fetch_narinfo(root, p), batch)
            ):
                if result is None:
                    raise SystemExit(
                        f"error: {store_path} has no narinfo in any of "
                        f"{CACHES}; is it built by hydra for this nixpkgs pin?"
                    )
                idx, info = result
                refs = sorted(
                    f"{STORE}/{r}"
                    for r in info.get("References", "").split()
                    if f"{STORE}/{r}" != store_path
                )
                paths[store_path] = {
                    "narHash": to_sri(info["NarHash"]),
                    "narSize": int(info["NarSize"]),
                    "references": refs,
                    "nar": {
                        "cache": idx,
                        "url": info["URL"],
                        "compression": info.get("Compression", "none"),
                        "fileHash": to_sri(info.get("FileHash", info["NarHash"])),
                        "fileSize": int(info.get("FileSize", info["NarSize"])),
                    },
                }
                pending.update(r for r in refs if r not in paths and r not in batch)
    return paths


def push_to_file_cache(root: str, store_path: str) -> None:
    cache_dir = os.path.join(root, "nix/cache")
    os.makedirs(cache_dir, exist_ok=True)
    nix("copy", "--to", f"file://{cache_dir}?compression=xz", store_path)


def emit_lock_bzl(packages: dict) -> str:
    lines = [
        "# @generated by nix/resolve.py -- do not edit",
        "# Load-time mirror of nix/lock.json (Starlark cannot read JSON at",
        "# load/analysis time; rules need these store-path strings).",
        "",
    ]
    # The local-action interpreter: python 3.14+ (stdlib zstd for NARs).
    py = packages.get("python314")
    if py:
        lines.append(f'PYTHON3 = "{py["storePath"]}/bin/python3"')
        lines.append("")
    shim = packages.get("nix-store-shim")
    if shim:
        lines.append(f'SHIM_STORE_PATH = "{shim["storePath"]}"')
        lines.append("")
    lines.append("PACKAGES = {")
    for name in sorted(packages):
        lines.append(f'    "{name}": "{packages[name]["storePath"]}",')
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("attrs", nargs="+",
                    help="nixpkgs attrs (gcc) or flake-local packages (.#name)")
    ap.add_argument("--check", action="store_true",
                    help="verify committed lock files are up to date")
    args = ap.parse_args()

    root = repo_root()
    os.chdir(root)

    with open("flake.lock") as f:
        flake_lock = json.load(f)
    nixpkgs_node = flake_lock["nodes"]["nixpkgs"]["locked"]

    nixpkgs_attrs = [a for a in args.attrs if not a.startswith(".#")]
    local_attrs = [a[2:] for a in args.attrs if a.startswith(".#")]
    for attr in nixpkgs_attrs:
        if "." in attr:
            raise SystemExit(
                f"error: pass package attrs, not outputs ({attr}); features "
                f"select outputs as e.g. '{attr.split('.')[0]}.dev'")

    print(f"evaluating {len(nixpkgs_attrs)} nixpkgs attrs...", file=sys.stderr)
    evaluated = eval_nixpkgs_attrs(nixpkgs_attrs)

    packages = {}
    for attr, info in evaluated.items():
        packages[attr] = {
            "attr": attr,
            "storePath": info["default"],
            "outputs": info["outputs"],
        }

    for name in local_attrs:
        print(f"building flake package .#{name}...", file=sys.stderr)
        nix("build", "--no-link", f".#{name}")
        info = eval_flake_package(name)
        packages[name] = {
            "attr": f".#{name}",
            "storePath": info["default"],
            "outputs": info["outputs"],
        }
        print(f"pushing .#{name} to nix/cache...", file=sys.stderr)
        for out_path in info["outputs"].values():
            push_to_file_cache(root, out_path)

    roots = sorted({p for pkg in packages.values() for p in pkg["outputs"].values()})
    print(f"walking closure of {len(roots)} roots via narinfo...", file=sys.stderr)
    paths = walk_closure(root, roots)
    print(f"closure: {len(paths)} store paths", file=sys.stderr)

    lock = {
        "version": 1,
        "system": SYSTEM,
        "nixpkgs": {
            "rev": nixpkgs_node["rev"],
            "narHash": nixpkgs_node["narHash"],
        },
        "caches": CACHES,
        "packages": packages,
        "paths": paths,
    }
    lock_json = json.dumps(lock, indent=2, sort_keys=True) + "\n"
    lock_bzl = emit_lock_bzl(packages)

    if args.check:
        ok = True
        for fname, want in [("nix/lock.json", lock_json), ("nix/lock.bzl", lock_bzl)]:
            try:
                with open(fname) as f:
                    have = f.read()
            except FileNotFoundError:
                have = ""
            if have != want:
                print(f"error: {fname} is out of date", file=sys.stderr)
                ok = False
        return 0 if ok else 1

    with open("nix/lock.json", "w") as f:
        f.write(lock_json)
    with open("nix/lock.bzl", "w") as f:
        f.write(lock_bzl)
    print("wrote nix/lock.json and nix/lock.bzl", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
