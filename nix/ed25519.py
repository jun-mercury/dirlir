"""Pure-python Ed25519 signature VERIFICATION (RFC 8032), stdlib only.

Vendored for dirlir's resolve step: nix binary-cache narinfo signatures are
checked before any path is locked (~10ms/verify; resolve touches ~100
paths). Verification only — no signing, no key generation. Derived from the
public-domain reference implementation (D. J. Bernstein et al.).

The nix fingerprint that is signed:
    1;<store-path>;<NarHash as sha256:base32>;<NarSize>;<ref1,ref2,...>
with references as full store paths, comma-joined, in narinfo order.
"""

import hashlib

_P = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493


def _inv(x):
    return pow(x, _P - 2, _P)


_D = (-121665 * _inv(121666)) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _recover_x(y, sign):
    xx = (y * y - 1) * _inv(_D * y * y + 1) % _P
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = x * _I % _P
    if (x * x - xx) % _P != 0:
        raise ValueError("invalid point")
    if x & 1 != sign:
        x = _P - x
    return x


def _add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = 2 * t1 * t2 * _D % _P
    d = 2 * z1 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _scalarmult(p, e):
    q = (0, 1, 1, 0)
    while e:
        if e & 1:
            q = _add(q, p)
        p = _add(p, p)
        e >>= 1
    return q


_BY = 4 * _inv(5) % _P
_BX = _recover_x(_BY, 0)
_B = (_BX, _BY, 1, _BX * _BY % _P)


def _decode_point(s):
    y = int.from_bytes(s, "little") & ((1 << 255) - 1)
    x = _recover_x(y, s[31] >> 7)
    return (x, y, 1, x * y % _P)


def _encode_point(p):
    x, y, z, _ = p
    zi = _inv(z)
    x, y = x * zi % _P, y * zi % _P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def verify(signature: bytes, message: bytes, public_key: bytes) -> bool:
    """True iff `signature` is a valid Ed25519 signature of `message`."""
    if len(signature) != 64 or len(public_key) != 32:
        return False
    try:
        a = _decode_point(public_key)
        r = _decode_point(signature[:32])
    except ValueError:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    h = int.from_bytes(
        hashlib.sha512(signature[:32] + public_key + message).digest(),
        "little") % _L
    left = _scalarmult(_B, s)
    right = _add(r, _scalarmult(a, h))
    return _encode_point(left) == _encode_point(right)
