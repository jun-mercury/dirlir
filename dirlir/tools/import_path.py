"""Materialize a single locked store path as a standalone artifact.

Used to import tools like the static shim into the build graph (so their
bytes live in CAS and can be exec_deps on remote execution). Goes through
the same NAR fetch/verify pipeline as layers -- for repo-built packages the
NAR comes from the committed nix/cache file cache, so this works on
machines that never built the package.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from materialize import materialize_store_path  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", required=True)
    ap.add_argument("--path", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.lock) as f:
        lock = json.load(f)
    if args.path not in lock["paths"]:
        raise SystemExit(
            f"error: {args.path} is not in the lockfile; re-run nix/resolve.py")
    materialize_store_path(lock, args.path, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
