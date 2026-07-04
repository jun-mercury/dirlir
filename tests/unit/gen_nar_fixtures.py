"""Generate NAR fixtures for nar-unpack's adversarial unit corpus.

usage: python3 gen_nar_fixtures.py OUTDIR

Writes OUTDIR/good.nar plus a set of bad-*.nar files that must all be
rejected, and OUTDIR/truncations/NNN.nar (every proper prefix of good.nar,
all of which must fail).
"""

import os
import struct
import sys


def s(data):
    if isinstance(data, str):
        data = data.encode()
    pad = (8 - len(data) % 8) % 8
    return struct.pack("<Q", len(data)) + data + b"\0" * pad


def regular(contents, executable=False):
    out = s("(") + s("type") + s("regular")
    if executable:
        out += s("executable") + s("")
    return out + s("contents") + s(contents) + s(")")


def symlink(target):
    return s("(") + s("type") + s("symlink") + s("target") + s(target) + s(")")


def directory(entries):
    out = s("(") + s("type") + s("directory")
    for name, node in entries:
        out += s("entry") + s("(") + s("name") + s(name) + s("node") + node + s(")")
    return out + s(")")


def archive(node):
    return s("nix-archive-1") + node


GOOD = archive(directory([
    ("bin", directory([("tool", regular(b"#!/bin/sh\necho hi\n", executable=True))])),
    ("data.txt", regular(b"hello world\n")),
    ("link-abs", symlink("/nix/store/00000000000000000000000000000000-x/lib/y")),
    ("link-rel", symlink("../link-escaping-target")),
]))

BAD = {
    # illegal entry names
    "bad-name-dotdot": archive(directory([("..", regular(b"x"))])),
    "bad-name-dot": archive(directory([(".", regular(b"x"))])),
    "bad-name-empty": archive(directory([("", regular(b"x"))])),
    "bad-name-slash": archive(directory([("a/b", regular(b"x"))])),
    # ordering / duplicates
    "bad-dup-entry": archive(directory([("a", regular(b"1")), ("a", regular(b"2"))])),
    "bad-order": archive(directory([("b", regular(b"1")), ("a", regular(b"2"))])),
    # structure
    "bad-magic": s("nix-archive-2") + regular(b"x"),
    "bad-node-type": archive(s("(") + s("type") + s("fifo") + s(")")),
    "bad-padding": archive(regular(b"x"))[:-7] + b"\x01" + archive(regular(b"x"))[-6:],
    "bad-trailing": archive(regular(b"x")) + b"junk",
    "bad-empty-symlink": archive(symlink("")),
    "bad-nul-in-name": archive(directory([("a\0b", regular(b"x"))])),
}


def main():
    outdir = sys.argv[1]
    os.makedirs(os.path.join(outdir, "truncations"), exist_ok=True)
    with open(os.path.join(outdir, "good.nar"), "wb") as f:
        f.write(GOOD)
    for name, data in BAD.items():
        with open(os.path.join(outdir, f"{name}.nar"), "wb") as f:
            f.write(data)
    # every proper prefix must fail (truncation at every byte)
    for n in range(len(GOOD)):
        with open(os.path.join(outdir, "truncations", f"{n:04d}.nar"), "wb") as f:
            f.write(GOOD[:n])
    print(f"wrote good.nar, {len(BAD)} bad fixtures, {len(GOOD)} truncations")


if __name__ == "__main__":
    main()
