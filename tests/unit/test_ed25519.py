"""Signature verification unit tests against a REAL cache.nixos.org-1
signature (captured live from nixos.snix.store during M4), plus negatives.
Stdlib only; runs offline.

usage: python3 tests/unit/test_ed25519.py
"""

import base64
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "nix"))
import ed25519  # noqa: E402

PUB = base64.b64decode("6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=")
SIG = base64.b64decode(
    "KKAVZxBlWDIyEudYTewQby9rDHsYaI/W0MDZ3bEaaIN8zollUa0RB8uyggsn"
    "554gUSj9Kx+Zr+pe8yTdHcUJCw==")
FINGERPRINT = (
    "1;/nix/store/nm7p8wxflggcwxfzayhysq4z6a1wg373-hello-2.12.3;"
    "sha256:0f3gg73cybjfnzlav06r5ndr4711wv2gjkgk2s0lghp2h3cy6db7;279624;"
    "/nix/store/8kvxvr3pmsypxiypq4g8zy13glnfr7nx-glibc-2.42-67,"
    "/nix/store/nm7p8wxflggcwxfzayhysq4z6a1wg373-hello-2.12.3"
).encode()


def main():
    assert ed25519.verify(SIG, FINGERPRINT, PUB), "positive case failed"
    assert not ed25519.verify(
        bytes([SIG[0] ^ 1]) + SIG[1:], FINGERPRINT, PUB), "flipped sig accepted"
    assert not ed25519.verify(
        SIG, FINGERPRINT.replace(b"279624", b"279625"), PUB), "tampered size accepted"
    assert not ed25519.verify(
        SIG, FINGERPRINT.replace(b"glibc", b"glibd"), PUB), "tampered refs accepted"
    assert not ed25519.verify(SIG[:63], FINGERPRINT, PUB), "short sig accepted"
    assert not ed25519.verify(SIG, FINGERPRINT, PUB[:31]), "short key accepted"
    print("ed25519 unit tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
