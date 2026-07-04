# A hermetic Haskell toolchain from a dirlir layer (nixpkgs ghc), same
# shim-wrapping pattern as nix_cxx.bzl. The nixpkgs ghc wrapper carries its
# own cc/binutils in its closure, so one ghc layer is self-sufficient.

load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo")
load("@root//dirlir:providers.bzl", "NixLayerInfo")

def _tool(shim, layer_dir, rel):
    return RunInfo(args = cmd_args(
        cmd_args(shim, format = "{}/bin/nix-store-shim"),
        "--store",
        cmd_args(layer_dir, format = "{}/nix/store"),
        "--",
        cmd_args(layer_dir, format = "{{}}/{}".format(rel)),
    ))

def _nix_haskell_toolchain_impl(ctx):
    layer = ctx.attrs.layer[NixLayerInfo]
    shim = ctx.attrs._shim[DefaultInfo].default_outputs[0]

    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = _tool(shim, layer.dir, "bin/ghc"),
            packager = _tool(shim, layer.dir, "bin/ghc-pkg"),
            linker = _tool(shim, layer.dir, "bin/ghc"),
            haddock = _tool(shim, layer.dir, "bin/haddock"),
            compiler_flags = ctx.attrs.compiler_flags,
            linker_flags = ctx.attrs.linker_flags,
            compiler_major_version = ctx.attrs.compiler_major_version,
        ),
        HaskellPlatformInfo(name = "x86_64"),
    ]

nix_haskell_toolchain = rule(
    impl = _nix_haskell_toolchain_impl,
    attrs = {
        "compiler_flags": attrs.list(attrs.arg(), default = []),
        "compiler_major_version": attrs.string(default = "9"),
        "layer": attrs.exec_dep(providers = [NixLayerInfo]),
        "linker_flags": attrs.list(attrs.arg(), default = []),
        "_shim": attrs.default_only(attrs.exec_dep(default = "root//nix:shim")),
    },
    is_toolchain_rule = True,
)
