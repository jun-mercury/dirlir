#!/usr/bin/env bash
# The hermetic test's assertions, run INSIDE dirlir-run's masked namespace
# (the enclosure itself lives in tools/dirlir-run — this is a thin client).
set -euo pipefail

ISO=${ISODIR:-hermetic}
SALT=${HERMETIC_SALT:-hermetic-manual}
buck2() { "$BUCK2_BIN" --isolation-dir "$ISO" "$@"; }

echo "=== building C and Haskell examples inside masked namespace (salt: $SALT)"
buck2 build -c "dirlir.salt=$SALT" \
    root//examples/hello_c:main root//examples/tls_demo:main root//examples/hello_hs:main
ran=$(buck2 log what-ran 2>/dev/null | grep -c "dirlir_layer\|nar_unpack\|c_compile\|cxx_link\|haskell" || true)
echo "=== actions re-executed inside the mask: $ran"
[ "$ran" -gt 0 ] || { echo "HERMETIC TEST FAILED: nothing re-ran (salt ineffective)"; exit 1; }

out_of() { buck2 build "$1" --show-full-output 2>/dev/null | awk '{print $2}'; }
SHIM=$(out_of root//nix:dirlir-tools)/bin/dirlir-shim
CXXLAYER=$(out_of root//layers:cxx-toolchain)
OPENSSL=$(out_of root//layers:openssl)
GHCLAYER=$(out_of root//layers:ghc)

echo "=== running built binaries through the shim (store still masked)"
"$SHIM" --store "$CXXLAYER/nix/store" -- "$(out_of root//examples/hello_c:main)"
"$SHIM" --store "$CXXLAYER/nix/store" --store "$OPENSSL/nix/store" -- "$(out_of root//examples/tls_demo:main)"
"$SHIM" --store "$GHCLAYER/nix/store" -- "$(out_of root//examples/hello_hs:main)"

echo "HERMETIC TEST PASSED"
