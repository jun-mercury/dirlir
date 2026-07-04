{
  description = "dirlir: antlir2-shaped directory layers from Nix, as hermetic Buck2 toolchains";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The package universe for nix/resolve.py: every locked package is
      # evaluated as .#legacyPackages.<system>.<attr>, pinned by this repo's
      # flake.lock (the antlir2 "flavor").
      legacyPackages.${system} = pkgs;

      packages.${system} = {
        nix-store-shim = pkgs.pkgsStatic.callPackage ./nix/shim { };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ buck2 python3 jq ];
      };
    };
}
