# The two static dirlir bootstrap tools, one derivation (one nix build in
# the bootstrap action): dirlir-shim (provision/enclose/exec) and nar-unpack.

{ stdenv }:

stdenv.mkDerivation {
  pname = "dirlir-tools";
  version = "0.2.0";

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -static -o dirlir-shim ${./dirlir-shim.c}
    $CC -O2 -Wall -Wextra -static -o nar-unpack ${./nar-unpack.c}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m755 dirlir-shim $out/bin/dirlir-shim
    install -D -m755 nar-unpack $out/bin/nar-unpack
    runHook postInstall
  '';
}
