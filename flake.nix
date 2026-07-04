{
  description = "dirlir: antlir2-shaped directory layers from Nix, as hermetic Buck2 toolchains";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      system = "x86_64-linux";
      # Plain nixpkgs: the package universe resolve.py locks. Keep it
      # overlay-free so locked store paths never depend on our tooling.
      pkgs = nixpkgs.legacyPackages.${system};
      rustBin = (import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      }).rust-bin;
      buck2 = import ./nix/buck2 { inherit pkgs rustBin; };
    in
    {
      # The package universe for nix/resolve.py: every locked package is
      # evaluated as .#legacyPackages.<system>.<attr>, pinned by this repo's
      # flake.lock (the antlir2 "flavor").
      legacyPackages.${system} = pkgs;

      packages.${system} = {
        dirlir-tools = pkgs.pkgsStatic.callPackage ./nix/shim { };
        inherit buck2;
      };

      devShells.${system}.default = pkgs.mkShell {
        # buck2 is our from-source, patch-ready build (nix/buck2/), NOT the
        # nixpkgs binary repackage. python314: the interpreter for local
        # buck2 actions until M6 removes the pin.
        packages = [ buck2 pkgs.python314 pkgs.jq ];
      };
    };
}
