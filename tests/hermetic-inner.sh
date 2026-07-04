#!/usr/bin/env bash
# Runs inside `unshare -rm` (root-mapped user+mount namespace); see
# hermetic.sh. Masks /nix/store down to $HERMETIC_ALLOW, then builds.
#
# The masking is staged: all allowlisted paths are bind-mounted into a
# tmpfs while the real store is still fully visible (so mount/mkdir/touch
# keep working), and the very last mount flips /nix/store to the staged
# view in one step.
set -euo pipefail

ISO=hermetic
HOST_COUNT=$(ls /nix/store | wc -l)

STAGE=/tmp/.hermetic-store
mkdir -p "$STAGE"
mount -t tmpfs none "$STAGE"
for p in $HERMETIC_ALLOW; do
    base=${p##*/}
    if [ -d "$p" ]; then
        mkdir "$STAGE/$base"
    else
        touch "$STAGE/$base"
    fi
    mount --bind "$p" "$STAGE/$base"
done
mount --rbind "$STAGE" /nix/store

echo "=== store entries visible inside sandbox: $(ls /nix/store | wc -l) (host had $HOST_COUNT)"

# The host /etc/ssl chain resolves through masked intermediate store paths;
# hand the daemon the final cert bundle directly.
if [ -n "${CERT_FILE:-}" ]; then
    export SSL_CERT_FILE="$CERT_FILE"
fi

fail=0
buck2() { "$BUCK2_BIN" --isolation-dir "$ISO" "$@"; }

echo "=== building C and Haskell examples inside masked namespace (fresh isolation dir)"
if ! buck2 build root//examples/hello_c:main root//examples/tls_demo:main root//examples/hello_hs:main; then
    echo "HERMETIC TEST FAILED: build inside masked namespace failed"
    buck2 kill >/dev/null 2>&1 || true
    exit 1
fi

out_of() { buck2 build "$1" --show-full-output 2>/dev/null | awk '{print $2}'; }
SHIM=$(out_of root//nix:shim)/bin/nix-store-shim
CXXLAYER=$(out_of root//layers:cxx-toolchain)
OPENSSL=$(out_of root//layers:openssl)
GHCLAYER=$(out_of root//layers:ghc)
HELLO=$(out_of root//examples/hello_c:main)
TLS=$(out_of root//examples/tls_demo:main)
HS=$(out_of root//examples/hello_hs:main)

echo "=== running built binaries through the shim (store still masked)"
"$SHIM" --store "$CXXLAYER/nix/store" -- "$HELLO" || fail=1
# tls needs libstdc++ (g++ link) from the gcc layer AND libssl from the
# openssl layer: the shim merges both stores (multi-store tmpfs path).
"$SHIM" --store "$CXXLAYER/nix/store" --store "$OPENSSL/nix/store" -- "$TLS" || fail=1
"$SHIM" --store "$GHCLAYER/nix/store" -- "$HS" || fail=1

echo "=== actions that ran inside the sandbox:"
buck2 log what-ran 2>/dev/null |
    grep -o 'dirlir_[a-z_]*\|cxx_compile\|cxx_link[a-z_]*\|write_json\|symlinked_dir' |
    sort | uniq -c | sort -rn || true

buck2 kill >/dev/null 2>&1 || true

if [ "$fail" -eq 0 ]; then
    echo "HERMETIC TEST PASSED"
else
    echo "HERMETIC TEST FAILED: binaries did not run under the shim"
fi
exit "$fail"
