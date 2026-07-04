#!/usr/bin/env bash
# Hermeticity proof: rebuild the C examples from scratch inside a mount
# namespace where /nix/store is a tmpfs containing ONLY the closures of the
# build infrastructure itself (buck2, the pinned action python, coreutils,
# bash, CA certs). Nothing the compile/link actions use may come from the
# host store: the gcc layer, openssl, and the python-bootstrap interpreter
# are all buck2 artifacts reached through the static shim. Any leak =>
# ENOENT => red.
#
# A fresh --isolation-dir means the daemon starts INSIDE the namespace and
# every action (including layer materialization from the warm NAR cache)
# re-runs inside it.
#
# Run from the devshell: nix develop -c ./tests/hermetic.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TARGETS=(root//examples/hello_c:main root//examples/tls_demo:main root//examples/hello_hs:main)

echo "=== warming NAR download cache"
buck2 build "${TARGETS[@]}" >/dev/null

# Pre-warm ONLY the bootstrap tools in the hermetic isolation dir: their
# action runs `nix build` (flake eval needs the whole host store) and is the
# one sanctioned local-only step. Everything else in that isolation dir
# stays cold and must rebuild inside the mask.
echo "=== pre-warming bootstrap tools in the hermetic isolation dir"
buck2 --isolation-dir hermetic build root//nix:dirlir-tools >/dev/null 2>&1

BUCK2_BIN=$(realpath "$(command -v buck2)")
PYTHON3_BIN=$(sed -n 's/^PYTHON3 = "\(.*\)"$/\1/p' nix/lock.bzl)
CP_BIN=$(realpath "$(command -v cp)")
BASH_BIN=$(realpath "$(command -v bash)")
# The host /etc/ssl symlink chain goes through intermediate store paths
# (NixOS /etc/static) that stay masked, so resolve the final cert file and
# point SSL_CERT_FILE at it directly inside the sandbox.
CERT_FILE=$(realpath /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true)
CERT=$(sed -E 's|^(/nix/store/[^/]+).*|\1|' <<<"$CERT_FILE" || true)
export CERT_FILE

AWK_BIN=$(realpath "$(command -v awk)")
GREP_BIN=$(realpath "$(command -v grep)")
SED_BIN=$(realpath "$(command -v sed)")

closure() { nix path-info --recursive "$1"; }
HERMETIC_ALLOW=$({
    closure "$BUCK2_BIN"
    closure "$PYTHON3_BIN"
    closure "$CP_BIN"
    closure "$BASH_BIN"
    closure "$AWK_BIN"
    closure "$GREP_BIN"
    closure "$SED_BIN"
    if [ -n "${CERT:-}" ]; then closure "$CERT"; fi
} | sort -u)

export HERMETIC_ALLOW BUCK2_BIN PYTHON3_BIN CP_BIN BASH_BIN
echo "=== allowlisted store paths: $(wc -l <<<"$HERMETIC_ALLOW")"

exec unshare -rm bash tests/hermetic-inner.sh
