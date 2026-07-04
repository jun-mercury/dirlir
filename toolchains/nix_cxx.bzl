# A hermetic C/C++ toolchain from a dirlir layer (nixpkgs wrapped gcc +
# binutils), modeled on the prelude's _cxx_toolchain_from_cxx_tools_info
# (toolchains/cxx.bzl) but with every tool shim-wrapped so the layer's store
# is mounted at /nix/store for the tool and its children (cc1, as, ld).
#
# Differences from the prelude version, deliberately:
#   - no -fuse-ld=lld injection (we use the gnu ld from the binutils layer)
#   - binutils (nm/objcopy/...) come from the layer, not host PATH
#   - link/archive actions are NOT forced local: all tool inputs are tracked
#     artifacts, so everything is remote-execution compatible.

load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "CxxPlatformInfo",
    "CxxToolchainInfo",
    "DepTrackingMode",
    "LinkerInfo",
    "LinkerType",
    "PicBehavior",
    "RuntimeDependencyHandling",
    "ShlibInterfacesMode",
)
load("@prelude//cxx:headers.bzl", "HeaderMode")
load("@prelude//linking:link_info.bzl", "LinkStyle")
load("@prelude//linking:lto.bzl", "LtoMode")
load("@root//dirlir:providers.bzl", "NixLayerInfo")

def _tool(shim, layer_dir, rel):
    return RunInfo(args = cmd_args(
        cmd_args(shim, format = "{}/bin/nix-store-shim"),
        "--store",
        cmd_args(layer_dir, format = "{}/nix/store"),
        "--",
        cmd_args(layer_dir, format = "{{}}/{}".format(rel)),
    ))

def _nix_cxx_toolchain_impl(ctx):
    layer = ctx.attrs.layer[NixLayerInfo]
    shim = ctx.attrs._shim[DefaultInfo].default_outputs[0]
    dep_tracking = DepTrackingMode(ctx.attrs.cpp_dep_tracking_mode)

    return [
        DefaultInfo(),
        CxxToolchainInfo(
            internal_tools = ctx.attrs._internal_tools[CxxInternalTools],
            linker_info = LinkerInfo(
                linker = _tool(shim, layer.dir, "bin/g++"),
                linker_flags = ctx.attrs.link_flags,
                post_linker_flags = [],
                archiver = _tool(shim, layer.dir, "bin/ar"),
                archiver_type = "gnu",
                archiver_supports_argfiles = True,
                generate_linker_maps = False,
                lto_mode = LtoMode("none"),
                type = LinkerType("gnu"),
                link_binaries_locally = False,
                link_libraries_locally = False,
                archive_objects_locally = False,
                use_archiver_flags = True,
                static_dep_runtime_ld_flags = [],
                static_pic_dep_runtime_ld_flags = [],
                shared_dep_runtime_ld_flags = [],
                independent_shlib_interface_linker_flags = [],
                shlib_interfaces = ShlibInterfacesMode("disabled"),
                link_style = LinkStyle(ctx.attrs.link_style),
                link_weight = 1,
                binary_extension = "",
                object_file_extension = "o",
                shared_library_name_default_prefix = "lib",
                shared_library_name_format = "{}.so",
                shared_library_versioned_name_format = "{}.so.{}",
                static_library_extension = "a",
                force_full_hybrid_if_capable = False,
                is_pdb_generated = False,
                link_ordering = None,
            ),
            bolt_enabled = False,
            binary_utilities_info = BinaryUtilitiesInfo(
                nm = _tool(shim, layer.dir, "bin/nm"),
                objcopy = _tool(shim, layer.dir, "bin/objcopy"),
                objdump = _tool(shim, layer.dir, "bin/objdump"),
                ranlib = _tool(shim, layer.dir, "bin/ranlib"),
                strip = _tool(shim, layer.dir, "bin/strip"),
                dwp = None,
                bolt_msdk = None,
            ),
            cxx_compiler_info = CxxCompilerInfo(
                compiler = _tool(shim, layer.dir, "bin/g++"),
                preprocessor_flags = [],
                compiler_flags = ctx.attrs.cxx_flags,
                compiler_type = "gcc",
            ),
            c_compiler_info = CCompilerInfo(
                compiler = _tool(shim, layer.dir, "bin/gcc"),
                preprocessor_flags = [],
                compiler_flags = ctx.attrs.c_flags,
                compiler_type = "gcc",
            ),
            as_compiler_info = CCompilerInfo(
                compiler = _tool(shim, layer.dir, "bin/gcc"),
                compiler_type = "gcc",
            ),
            asm_compiler_info = CCompilerInfo(
                compiler = _tool(shim, layer.dir, "bin/gcc"),
                compiler_type = "gcc",
            ),
            header_mode = HeaderMode("symlink_tree_only"),
            cpp_dep_tracking_mode = dep_tracking,
            pic_behavior = PicBehavior("supported"),
            llvm_link = None,
            use_dep_files = dep_tracking != DepTrackingMode("none"),
            runtime_dependency_handling = RuntimeDependencyHandling("no_symlink"),
        ),
        CxxPlatformInfo(name = "linux-x86_64"),
    ]

nix_cxx_toolchain = rule(
    impl = _nix_cxx_toolchain_impl,
    attrs = {
        "c_flags": attrs.list(attrs.arg(), default = []),
        "cpp_dep_tracking_mode": attrs.string(default = "makefile"),
        "cxx_flags": attrs.list(attrs.arg(), default = []),
        "layer": attrs.exec_dep(providers = [NixLayerInfo]),
        "link_flags": attrs.list(attrs.arg(), default = []),
        "link_style": attrs.string(default = "shared"),
        "_internal_tools": attrs.default_only(attrs.exec_dep(
            providers = [CxxInternalTools],
            default = "prelude//cxx/tools:internal_tools",
        )),
        "_shim": attrs.default_only(attrs.exec_dep(default = "root//nix:shim")),
    },
    is_toolchain_rule = True,
)
