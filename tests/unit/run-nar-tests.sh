#!/usr/bin/env bash
# Adversarial unit corpus for nar-unpack (PLAN-v2 M3).
# usage: run-nar-tests.sh <path-to-nar-unpack>
set -euo pipefail
UNPACK=$1
cd "$(git rev-parse --show-toplevel)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 tests/unit/gen_nar_fixtures.py "$WORK/fixtures" >/dev/null

fail=0

# good.nar must unpack, and the tree must match expectations exactly.
if "$UNPACK" "$WORK/fixtures/good.nar" "$WORK/out"; then
    [ "$(cat "$WORK/out/data.txt")" = "hello world" ] || { echo "FAIL: contents"; fail=1; }
    [ -x "$WORK/out/bin/tool" ] || { echo "FAIL: executable bit"; fail=1; }
    [ "$(readlink "$WORK/out/link-abs")" = "/nix/store/00000000000000000000000000000000-x/lib/y" ] || { echo "FAIL: abs symlink"; fail=1; }
    [ "$(readlink "$WORK/out/link-rel")" = "../link-escaping-target" ] || { echo "FAIL: rel symlink"; fail=1; }
else
    echo "FAIL: good.nar rejected"
    fail=1
fi

# --size: cap below the archive size must fail; at size must pass.
size=$(stat -c %s "$WORK/fixtures/good.nar")
if "$UNPACK" --size $((size - 1)) "$WORK/fixtures/good.nar" "$WORK/capped" 2>/dev/null; then
    echo "FAIL: --size cap not enforced"
    fail=1
fi
"$UNPACK" --size "$size" "$WORK/fixtures/good.nar" "$WORK/at-cap" >/dev/null 2>&1 ||
    { echo "FAIL: --size at exact size rejected"; fail=1; }

# every bad fixture must be rejected without leaving output outside its dir
for f in "$WORK"/fixtures/bad-*.nar; do
    dest="$WORK/bad-out-$(basename "$f" .nar)"
    if "$UNPACK" "$f" "$dest" 2>/dev/null; then
        echo "FAIL: $(basename "$f") accepted"
        fail=1
    fi
done

# every truncation must be rejected
tfail=0
for f in "$WORK"/fixtures/truncations/*.nar; do
    if "$UNPACK" "$f" "$WORK/trunc-out-$(basename "$f" .nar)" 2>/dev/null; then
        echo "FAIL: truncation $(basename "$f") accepted"
        tfail=1
    fi
done
[ "$tfail" -eq 0 ] || fail=1

if [ "$fail" -eq 0 ]; then
    echo "nar-unpack unit corpus passed"
fi
exit "$fail"
