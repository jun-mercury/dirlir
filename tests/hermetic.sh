#!/usr/bin/env bash
# Hermeticity proof, rung-0 style: tools/dirlir-run owns the enclosure
# (allowlist computation, staged masking, daemon policy, ns invariant,
# teardown); this script only warms caches and asserts.
#
# Run from the devshell: nix develop -c ./tests/hermetic.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Warm the hermetic isolation dir fully OUTSIDE the mask (downloads are the
# expensive part); inside the mask a salt bump re-runs every shim-wrapped
# action and nar-unpack while native downloads stay cached.
# Self-heal a stale namespaced-daemon record before the warm build (same
# logic as dirlir-run's outer policy).
STALE="$HOME/.buck/buckd$(pwd)/hermetic"
if [ -e "$STALE/buckd.pid" ] &&
   buck2 --isolation-dir hermetic status 2>&1 | grep -q "no buckd running"; then
    rm -rf "$STALE"
fi

echo "=== warming caches in the hermetic isolation dir"
buck2 --isolation-dir hermetic build \
    root//examples/hello_c:main root//examples/tls_demo:main root//examples/hello_hs:main >/dev/null
buck2 --isolation-dir hermetic kill >/dev/null 2>&1 || true

HERMETIC_SALT="hermetic-$(date +%s)"
export HERMETIC_SALT

exec tools/dirlir-run --isolation-dir hermetic --kill-daemon -- \
    bash tests/hermetic-checks.sh
