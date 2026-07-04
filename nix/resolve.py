#!/usr/bin/env python3
"""Generate nix/lock.json and nix/lock.bzl from the flake-pinned nixpkgs.

The dirlir analog of antlir2's RPM snapshot + versionlock: run occasionally
(tools/resolve.sh carries the canonical attr list), commit the outputs.
Buck2 actions never evaluate nix — per-path NARs are fetched natively by
buck2 (download_file, sha256 == NarHash) from the locked URLs.

v2 (PLAN-v2 M4):
- cache = https://nixos.snix.store (serves UNCOMPRESSED NARs, so the NAR
  file's sha256 IS the NarHash; URL comes from the narinfo, castore-form)
- every narinfo's ed25519 signature is verified against TRUSTED_KEYS before
  anything is locked; unsigned or badly-signed paths abort the resolve
- schema per path: narHash, narSize, references, url (no FileHash — snix
  has none; no compression — always identity)

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ed25519  # noqa: E402

SYSTEM = "x86_64-linux"
CACHES = ["https://nixos.snix.store"]
STORE = "/nix/store"

# Signatures accepted for locked paths. snix mirrors cache.nixos.org
# narinfos, so its entries carry the upstream signature.
TRUSTED_KEYS = {
    "cache.nixos.org-1": "6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=",
}

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
    """One nix eval for all attrs -> {attr: {default, outputs}}."""
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


def parse_narinfo(text: str) -> dict:
    fields = {}
    sigs = []
    for line in text.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "Sig":
            sigs.append(value.strip())
        else:
            fields[key.strip()] = value.strip()
    fields["Sigs"] = sigs
    return fields


def verify_narinfo(store_path: str, info: dict) -> None:
    """Abort unless a trusted key validly signs this narinfo's fingerprint."""
    refs = [f"{STORE}/{r}" for r in info.get("References", "").split()]
    fingerprint = "1;{};{};{};{}".format(
        store_path, info["NarHash"], info["NarSize"], ",".join(refs))
    for sig in info["Sigs"]:
        key_name, _, sig_b64 = sig.partition(":")
        pub_b64 = TRUSTED_KEYS.get(key_name)
        if pub_b64 is None:
            continue
        if ed25519.verify(base64.b64decode(sig_b64), fingerprint.encode(),
                          base64.b64decode(pub_b64)):
            return
        raise SystemExit(
            f"error: INVALID signature by {key_name} on {store_path} — "
            f"refusing to lock")
    raise SystemExit(
        f"error: no signature from a trusted key on {store_path} "
        f"(sigs: {[s.split(':')[0] for s in info['Sigs']] or 'none'})")


def fetch_narinfo(store_path: str):
    hashpart = os.path.basename(store_path)[:32]
    for idx, cache in enumerate(CACHES):
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
    return None


def walk_closure(roots: list) -> dict:
    """BFS the closure via narinfo References; verify every signature."""
    paths = {}
    pending = set(roots)
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        while pending:
            batch = sorted(pending)
            pending.clear()
            for store_path, result in zip(
                batch, pool.map(fetch_narinfo, batch)
            ):
                if result is None:
                    raise SystemExit(
                        f"error: {store_path} has no narinfo in {CACHES}")
                idx, info = result
                verify_narinfo(store_path, info)
                refs = sorted(
                    f"{STORE}/{r}"
                    for r in info.get("References", "").split()
                    if f"{STORE}/{r}" != store_path
                )
                paths[store_path] = {
                    "narHash": to_sri(info["NarHash"]),
                    "narSize": int(info["NarSize"]),
                    "references": refs,
                    "nar": {"cache": idx, "url": info["URL"]},
                }
                pending.update(r for r in refs if r not in paths and r not in batch)
    return paths


def emit_lock_bzl(packages: dict, paths: dict) -> str:
    lines = [
        "# @generated by nix/resolve.py -- do not edit",
        "# Load-time mirror of nix/lock.json (Starlark cannot read JSON at",
        "# load/analysis time). PATHS urls are absolute; sha256 is the",
        "# NarHash as hex (snix serves uncompressed NARs, so buck2's native",
        "# download_file verifies the NarHash itself).",
        "",
        # The pinned local-action interpreter; deleted in M6 with dir_layer v2.
    ]
    py = packages.get("python314")
    if py:
        lines.append(f'PYTHON3 = "{py["storePath"]}/bin/python3"')
        lines.append("")
    lines.append("PACKAGES = {")
    for name in sorted(packages):
        pkg = packages[name]
        lines.append(f'    "{name}": {{')
        lines.append(f'        "storePath": "{pkg["storePath"]}",')
        lines.append('        "outputs": {')
        for out in sorted(pkg["outputs"]):
            lines.append(f'            "{out}": "{pkg["outputs"][out]}",')
        lines.append("        },")
        lines.append("    },")
    lines.append("}")
    lines.append("")
    lines.append("PATHS = {")
    for path in sorted(paths):
        p = paths[path]
        sha_hex = base64.b64decode(p["narHash"].split("-", 1)[1]).hex()
        url = CACHES[p["nar"]["cache"]] + "/" + p["nar"]["url"]
        lines.append(f'    "{path}": {{')
        lines.append(f'        "nar_size": {p["narSize"]},')
        lines.append('        "references": [')
        for r in p["references"]:
            lines.append(f'            "{r}",')
        lines.append("        ],")
        lines.append(f'        "sha256": "{sha_hex}",')
        lines.append(f'        "url": "{url}",')
        lines.append("    },")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("attrs", nargs="+", help="nixpkgs attrs (gcc, openssl, ...)")
    ap.add_argument("--check", action="store_true",
                    help="verify committed lock files are up to date")
    args = ap.parse_args()

    os.chdir(repo_root())

    with open("flake.lock") as f:
        flake_lock = json.load(f)
    nixpkgs_node = flake_lock["nodes"]["nixpkgs"]["locked"]

    for attr in args.attrs:
        if "." in attr or attr.startswith("#"):
            raise SystemExit(
                f"error: pass plain nixpkgs package attrs, not '{attr}' "
                f"(features select outputs as e.g. 'openssl.dev')")

    print(f"evaluating {len(args.attrs)} nixpkgs attrs...", file=sys.stderr)
    evaluated = eval_nixpkgs_attrs(args.attrs)
    packages = {
        attr: {
            "attr": attr,
            "storePath": info["default"],
            "outputs": info["outputs"],
        }
        for attr, info in evaluated.items()
    }

    roots = sorted({p for pkg in packages.values() for p in pkg["outputs"].values()})
    print(f"walking closure of {len(roots)} roots via signed narinfo...",
          file=sys.stderr)
    paths = walk_closure(roots)
    print(f"closure: {len(paths)} store paths, all signatures verified",
          file=sys.stderr)

    lock = {
        "version": 2,
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
    lock_bzl = emit_lock_bzl(packages, paths)

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
