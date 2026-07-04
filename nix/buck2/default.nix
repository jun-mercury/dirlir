# Buck2 built from source at an exact pinned rev, patch-ready (PLAN-v2 ADR-1).
#
# Why not the nixpkgs package: it repackages prebuilt release binaries and
# cannot take source patches. This derivation is the mechanism for carrying
# .patch files against the RE client (or anything else) on demand — the
# primary remedy for RE-client misbehavior per ADR-4. `patches = [ ]` until
# one is needed.
#
# The {buck2, prelude} pair is matched BY CONSTRUCTION: the prelude is an
# in-tree directory of this rev (not a submodule), and
# app/buck2_external_cells_bundled/build.rs embeds it into the binary at
# cargo build time — the `bundled` external cell in .buckconfig therefore
# always matches the running binary.
#
# Version bumps: change `rev`, `hash`, regenerate Cargo.lock (upstream ships
# none; `cargo generate-lockfile` in the source tree), and update `channel`
# from the rev's rust-toolchain file. One variable per commit: this initial
# pin is the exact version dirlir v1 was characterized against
# (FindMissingBlobs negative-cache behavior, ttl=0 outputs, soft-error
# hardening), keeping the re-demo assertions interpretable.

{ pkgs, rustBin }:

let
  rev = "7600cb80070a88b88be67aa5d20d6a93cffa0223"; # buck2 2026-04-14
  channel = "2026-01-18"; # from the rev's rust-toolchain file

  toolchain = rustBin.nightly.${channel}.default;
  rustPlatform = pkgs.makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "buck2";
  version = "2026-04-14-${builtins.substring 0 8 rev}";

  src = pkgs.fetchFromGitHub {
    owner = "facebook";
    repo = "buck2";
    inherit rev;
    hash = "sha256-1GWZeCwX/lyJsBNTiPX/q0U68DLIQCWxE6NS514wemY=";
  };

  patches = [
    # ADR-4 in action: the OSS RE client's FindMissingBlobs cache never
    # learns about this client's own uploads, so a stale Missing entry
    # poisons any later remote action whose input is byte-identical to a
    # previously uploaded blob (chained remote layers, subpath excisions).
    ./patches/0001-find-missing-cache-upload-invalidation.patch
  ];

  cargoLock = {
    lockFile = ./Cargo.lock;
    allowBuiltinFetchGit = true; # a few git deps; no manual outputHashes
  };

  # Upstream commits no Cargo.lock (they build buck2 with buck2).
  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
  '';

  cargoBuildFlags = [ "--bin" "buck2" ];
  doCheck = false;

  env = {
    # The vendored protoc prebuilts don't run on nix hosts; upstream's own
    # flake devshell does this same override.
    BUCK2_BUILD_PROTOC = "${pkgs.protobuf}/bin/protoc";
    BUCK2_BUILD_PROTOC_INCLUDE = "${pkgs.protobuf}/include";
    # Upstream sets this in .cargo/config.toml, which buildRustPackage's
    # vendoring config shadows; without it the tokio_unstable metrics APIs
    # buck2 uses do not exist.
    RUSTFLAGS = "--cfg tokio_unstable";
  };
}
