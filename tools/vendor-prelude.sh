#!/usr/bin/env bash
# Vendor the buck2 prelude matching the nixpkgs-pinned buck2 into prelude/.
# Only needed if the bundled external cell ([external_cells] prelude = bundled)
# does not work with the nixpkgs build of buck2.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tarball=$(nix build --no-link --print-out-paths \
    .#legacyPackages.x86_64-linux.buck2.passthru.prelude)
rm -rf prelude
mkdir prelude
tar -xzf "$tarball" --strip-components=1 -C prelude
echo "vendored prelude from $tarball"
