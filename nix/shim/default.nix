{ stdenv }:

stdenv.mkDerivation {
  pname = "nix-store-shim";
  version = "0.1.0";

  src = ./shim.c;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -static -o nix-store-shim $src
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m755 nix-store-shim $out/bin/nix-store-shim
    runHook postInstall
  '';
}
