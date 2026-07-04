#!/usr/bin/env bash
# Determinism: build the layer set + binaries twice in two fresh isolation
# dirs; type-aware manifests must be IDENTICAL, and must match the
# committed goldens (regenerate with --update on lock bumps; cross-machine
# drift shows up as a golden mismatch in CI).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

TARGETS=(root//layers:cxx-toolchain root//layers:app root//examples/hello_c:main)

build_manifest() {
    local iso=$1 out=$2
    local d="$HOME/.buck/buckd$(pwd)/$iso"
    if [ -e "$d/buckd.pid" ] && buck2 --isolation-dir "$iso" status 2>&1 | grep -q "no buckd running"; then
        rm -rf "$d"
    fi
    rm -rf "buck-out/$iso"
    buck2 --isolation-dir "$iso" build "${TARGETS[@]}" >/dev/null 2>&1
    {
        for t in "${TARGETS[@]}"; do
            p=$(buck2 --isolation-dir "$iso" build "$t" --show-full-output 2>/dev/null | awk '{print $2}')
            echo "== $t"
            python3 tests/manifest.py "$p"
        done
    } > "$out"
    buck2 --isolation-dir "$iso" kill >/dev/null 2>&1 || true
}

echo "=== building twice in fresh isolation dirs"
build_manifest det-a /tmp/dirlir-manifest-a
build_manifest det-b /tmp/dirlir-manifest-b

echo "=== double-build identity"
diff /tmp/dirlir-manifest-a /tmp/dirlir-manifest-b >/dev/null ||
    { echo "DETERMINISM FAILED: double builds differ"; diff /tmp/dirlir-manifest-a /tmp/dirlir-manifest-b | head; exit 1; }

mkdir -p tests/golden
if [ "$UPDATE" -eq 1 ]; then
    cp /tmp/dirlir-manifest-a tests/golden/manifest.txt
    echo "golden updated: tests/golden/manifest.txt"
    exit 0
fi

echo "=== golden comparison"
diff tests/golden/manifest.txt /tmp/dirlir-manifest-a >/dev/null ||
    { echo "DETERMINISM FAILED: manifest differs from committed golden"; diff tests/golden/manifest.txt /tmp/dirlir-manifest-a | head; exit 1; }

echo "DETERMINISM TEST PASSED ($(wc -l < /tmp/dirlir-manifest-a) manifest lines)"
