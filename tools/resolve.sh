#!/usr/bin/env bash
# The canonical resolve invocation (attr list lives HERE; CI --check uses it).
# usage: tools/resolve.sh [--check]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 nix/resolve.py "$@" \
    gcc openssl python3 hello coreutils bash ghc strace
