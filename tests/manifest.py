#!/usr/bin/env python3
"""Type-aware tree manifest for determinism checks.

Regular files are hashed; symlinks are recorded LITERALLY (path -> target)
-- never resolved, since variant C trees contain absolute /nix/store
targets that don't exist outside buck-out; directories are structure.

usage: manifest.py DIR...   (one manifest to stdout, stable order)
"""

import hashlib
import os
import sys


def manifest(root):
    if os.path.isfile(root):
        h = hashlib.sha256()
        with open(root, "rb") as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
        x = "x" if os.access(root, os.X_OK) else "-"
        return [f"file {os.path.basename(root)} {x} {h.hexdigest()}"]
    lines = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if os.path.islink(full):
                lines.append(f"link {rel} -> {os.readlink(full)}")
            elif os.path.isdir(full):
                lines.append(f"dir  {rel}")
            else:
                h = hashlib.sha256()
                with open(full, "rb") as f:
                    while chunk := f.read(1 << 20):
                        h.update(chunk)
                x = "x" if os.access(full, os.X_OK) else "-"
                lines.append(f"file {rel} {x} {h.hexdigest()}")
    return lines


def main():
    for root in sys.argv[1:]:
        for line in manifest(root):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
