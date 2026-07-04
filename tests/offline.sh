#!/usr/bin/env bash
# Offline: with downloads warm, a salt bump re-runs every dirlir action
# (shim-wrapped AND nar-unpack) inside a namespace WITHOUT network. The
# claim, precisely: all dirlir actions re-run offline except native
# downloads and the bootstrap tool builds (bootstrap runs `nix build` and
# is allowed network by design -- it is warmed here and cache-hits...
# except buck2 has no persistent local action cache across daemons, so the
# bootstrap re-runs too; nix build of an already-realized derivation needs
# no network, which keeps the claim intact).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ISO=offline
D="$HOME/.buck/buckd$(pwd)/$ISO"
if [ -e "$D/buckd.pid" ] && buck2 --isolation-dir "$ISO" status 2>&1 | grep -q "no buckd running"; then
    rm -rf "$D"
fi

TARGETS=(root//examples/hello_c:main root//examples/tls_demo:main root//layers:app)

echo "=== warming downloads + bootstrap (online)"
buck2 --isolation-dir "$ISO" build "${TARGETS[@]}" >/dev/null
buck2 --isolation-dir "$ISO" kill >/dev/null 2>&1 || true
rm -rf "$D"

SALT="offline-$(date +%s)"
echo "=== rebuilding with salt=$SALT inside unshare -rn (no external network)"
# loopback up: buckd listens on 127.0.0.1; external interfaces stay absent.
if unshare -rn -- sh -c \
    'ip link set lo up && exec buck2 --isolation-dir '"$ISO"' build -c dirlir.salt='"$SALT"' '"${TARGETS[*]}" >/dev/null 2>&1; then
    ran=$(buck2 --isolation-dir "$ISO" log what-ran 2>/dev/null |
        grep -c "dirlir_layer\|dirlir_subpath\|nar_unpack\|c_compile\|cxx_link" || true)
    echo "OFFLINE TEST PASSED ($ran dirlir/compile actions re-ran without network)"
else
    echo "OFFLINE TEST FAILED: build needed the network"
    exit 1
fi