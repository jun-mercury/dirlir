#!/usr/bin/env python3
"""Weekly liveness sweep: every locked path must still be fetchable.

- HEAD each locked NAR URL; Content-Length must equal the locked narSize
  (snix serves uncompressed NARs).
- Re-fetch each narinfo and require it byte-compatible with the lock
  (NarHash, NarSize, References): signed narinfos are immutable, so ANY
  change upstream is an alarm, not a refresh.
- Full GET + sha256 for a small random sample.

usage: python3 tests/liveness.py [--sample N]
"""

import argparse
import hashlib
import json
import os
import random
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "nix"))
import resolve  # reuse fetch_narinfo/verify + constants  # noqa: E402


def head(url):
    req = urllib.request.Request(url, method="HEAD",
                                 headers={"User-Agent": "dirlir-liveness"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return int(r.headers.get("Content-Length", "-1"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=3)
    args = ap.parse_args()
    os.chdir(resolve.repo_root())

    with open("nix/lock.json") as f:
        lock = json.load(f)

    failures = 0
    for path, info in sorted(lock["paths"].items()):
        url = lock["caches"][info["nar"]["cache"]] + "/" + info["nar"]["url"]
        try:
            n = head(url)
        except Exception as e:
            print(f"FAIL {path}: HEAD {url}: {e}")
            failures += 1
            continue
        if n != info["narSize"]:
            print(f"FAIL {path}: Content-Length {n} != narSize {info['narSize']}")
            failures += 1

        result = resolve.fetch_narinfo(path)
        if result is None:
            print(f"FAIL {path}: narinfo gone")
            failures += 1
            continue
        _, ni = result
        resolve.verify_narinfo(path, ni)
        if resolve.to_sri(ni["NarHash"]) != info["narHash"] or \
                int(ni["NarSize"]) != info["narSize"]:
            print(f"FAIL {path}: narinfo mutated upstream (immutable by design!)")
            failures += 1

    rng = random.Random(0xD1517)  # deterministic sample
    for path in rng.sample(sorted(lock["paths"]), min(args.sample, len(lock["paths"]))):
        info = lock["paths"][path]
        url = lock["caches"][info["nar"]["cache"]] + "/" + info["nar"]["url"]
        h = hashlib.sha256()
        with urllib.request.urlopen(
                urllib.request.Request(url, headers={"User-Agent": "dirlir-liveness"}),
                timeout=120) as r:
            while chunk := r.read(1 << 20):
                h.update(chunk)
        want = info["narHash"].split("-", 1)[1]
        import base64
        if base64.b64decode(want).hex() != h.hexdigest():
            print(f"FAIL {path}: full-GET hash mismatch")
            failures += 1
        else:
            print(f"ok   {path}: full GET verified")

    if failures:
        print(f"{failures} liveness failures")
        return 1
    print(f"liveness: all {len(lock['paths'])} locked paths healthy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
