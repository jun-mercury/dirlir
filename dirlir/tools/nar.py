"""Streaming NAR (Nix ARchive) unpacker, stdlib only.

Format (see nix/doc or the thesis): a NAR is a sequence of length-prefixed
strings, each padded to 8 bytes. An archive is:

    str("nix-archive-1") node
    node     := "(" "type" ("regular" [ "executable" "" ] "contents" str
                | "symlink" "target" str
                | "directory" entry*) ")"
    entry    := "entry" "(" "name" str "node" node ")"

restore() consumes the stream exactly and hashes every byte read, so the
sha256 of the consumed stream IS the NarHash.
"""

import hashlib
import os
import struct


class NarError(Exception):
    pass


class _HashingReader:
    def __init__(self, f, limit=None):
        self.f = f
        self.hasher = hashlib.sha256()
        self.size = 0
        self.limit = limit

    def read(self, n):
        data = self.f.read(n)
        self.hasher.update(data)
        self.size += len(data)
        if self.limit is not None and self.size > self.limit:
            raise NarError("NAR stream exceeds the locked NarSize")
        return data


class _NarReader:
    def __init__(self, f, limit=None):
        self.f = _HashingReader(f, limit)

    def read_exact(self, n):
        chunks = []
        remaining = n
        while remaining > 0:
            chunk = self.f.read(min(remaining, 1 << 20))
            if not chunk:
                raise NarError("unexpected EOF")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def read_u64(self):
        return struct.unpack("<Q", self.read_exact(8))[0]

    def read_padding(self, n):
        pad = (8 - n % 8) % 8
        if pad and self.read_exact(pad) != b"\0" * pad:
            raise NarError("non-zero padding")

    def read_bytes(self):
        n = self.read_u64()
        data = self.read_exact(n)
        self.read_padding(n)
        return data

    def read_str(self):
        return self.read_bytes().decode()

    def expect(self, expected):
        got = self.read_str()
        if got != expected:
            raise NarError(f"expected {expected!r}, got {got!r}")

    def copy_contents_to(self, path):
        n = self.read_u64()
        with open(path, "wb") as out:
            remaining = n
            while remaining > 0:
                chunk = self.f.read(min(remaining, 1 << 20))
                if not chunk:
                    raise NarError("unexpected EOF in contents")
                out.write(chunk)
                remaining -= len(chunk)
        self.read_padding(n)


def _restore_node(r, path):
    r.expect("(")
    r.expect("type")
    node_type = r.read_str()
    if node_type == "regular":
        tok = r.read_str()
        executable = False
        if tok == "executable":
            executable = True
            r.expect("")
            tok = r.read_str()
        if tok != "contents":
            raise NarError(f"expected contents, got {tok!r}")
        r.copy_contents_to(path)
        os.chmod(path, 0o755 if executable else 0o644)
        r.expect(")")
    elif node_type == "symlink":
        r.expect("target")
        target = r.read_str()
        os.symlink(target, path)
        r.expect(")")
    elif node_type == "directory":
        os.mkdir(path)
        os.chmod(path, 0o755)
        while True:
            tok = r.read_str()
            if tok == ")":
                break
            if tok != "entry":
                raise NarError(f"expected entry, got {tok!r}")
            r.expect("(")
            r.expect("name")
            name = r.read_str()
            if not name or "/" in name or name in (".", ".."):
                raise NarError(f"illegal entry name {name!r}")
            r.expect("node")
            _restore_node(r, os.path.join(path, name))
            r.expect(")")
    else:
        raise NarError(f"unknown node type {node_type!r}")


def restore(stream, dest, limit=None):
    """Unpack a NAR stream to `dest`; returns (sha256_hex, nar_size).

    `limit` caps the bytes consumed (defense against decompression bombs
    when the compressed input is not independently verifiable).
    """
    r = _NarReader(stream, limit)
    r.expect("nix-archive-1")
    _restore_node(r, dest)
    return r.f.hasher.hexdigest(), r.f.size
