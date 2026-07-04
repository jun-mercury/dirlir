# A hermetic Haskell toolchain from a dirlir layer (nixpkgs ghc), same
# shim-wrapping pattern as nix_cxx.bzl. The nixpkgs ghc wrapper carries its
# own cc/binutils in its closure, so one ghc layer is self-sufficient.

load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo")
load("@root//dirlir:providers.bzl", "NixLayerInfo")
load("@root//dirlir:shim.bzl", "shim_run")

def _tool(ctx, name):
    layer = ctx.attrs.layer[NixLayerInfo]
    shim = ctx.attrs._shim[DefaultInfo].default_outputs[0]
    return RunInfo(args = shim_run(
        shim,
        [cmd_args(layer.dir, format = "{}/nix/store")],
        ["{}/{}".format(ctx.attrs.bin, name)],
    ))

def _nix_haskell_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = _tool(ctx, "ghc"),
            packager = _tool(ctx, "ghc-pkg"),
            linker = _tool(ctx, "ghc"),
            haddock = _tool(ctx, "haddock"),
            compiler_flags = ctx.attrs.compiler_flags,
            linker_flags = ctx.attrs.linker_flags,
            compiler_major_version = ctx.attrs.compiler_major_version,
        ),
        HaskellPlatformInfo(name = "x86_64"),
    ]

nix_haskell_toolchain = rule(
    impl = _nix_haskell_toolchain_impl,
    attrs = {
        "bin": attrs.string(doc = "absolute store bin dir, e.g. /nix/store/<ghc>/bin"),
        "compiler_flags": attrs.list(attrs.arg(), default = []),
        "compiler_major_version": attrs.string(default = "9"),
        "layer": attrs.exec_dep(providers = [NixLayerInfo]),
        "linker_flags": attrs.list(attrs.arg(), default = []),
        "_shim": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
    },
    is_toolchain_rule = True,
)
