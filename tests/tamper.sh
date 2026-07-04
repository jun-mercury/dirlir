#!/usr/bin/env bash
# Supply-chain tamper: flip one hex digit of a locked sha256 -> the native
# download must fail hash verification and produce no artifact.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

cleanup() { git checkout -q nix/lock.bzl 2>/dev/null || true; }
trap cleanup EXIT

# Pick the hello path target; flip the last hex digit of its sha256.
BASE=$(python3 - <<'EOF'
import re
s = open("nix/lock.bzl").read()
m = re.search(r'"hello": \{\s*"storePath": "/nix/store/([^"]*)"', s)
print(m.group(1))
EOF
)
python3 - "$BASE" <<'EOF'
import re
import sys

base = sys.argv[1]
p = "nix/lock.bzl"
s = open(p).read()
# Flip a digit of THE BUILT PATH's sha256 (not just any entry).
block = re.search(
    r'"/nix/store/' + re.escape(base) + r'": \{.*?"sha256": "([0-9a-f]{64})"',
    s, re.S)
h = block.group(1)
flip = "0" if h[-1] != "0" else "1"
start = block.start(1)
s = s[:start] + h[:-1] + flip + s[start + 64:]
open(p, "w").write(s)
EOF

if out=$(buck2 build "root//nix:$BASE" 2>&1); then
    echo "TAMPER TEST FAILED: tampered download unexpectedly succeeded"
    exit 1
fi
grep -qi "digest\|sha256\|hash" <<<"$out" ||
    { echo "TAMPER TEST FAILED: failure not hash-related:"; tail -5 <<<"$out"; exit 1; }

echo "TAMPER TEST PASSED (flipped sha256 digit rejected by native download)"
