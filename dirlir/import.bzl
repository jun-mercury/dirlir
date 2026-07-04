# Bridges between layers and the rest of the buck2 graph.

load(":lock_util.bzl", "parse_spec")
load(":providers.bzl", "NixLayerInfo")
load(":shim.bzl", "shim_run")

def _nix_tool_impl(ctx):
    layer = ctx.attrs.layer[NixLayerInfo]
    shim = ctx.attrs._tools[DefaultInfo].default_outputs[0]
    run = shim_run(
        shim,
        [cmd_args(layer.dir, format = "{}/nix/store")],
        [cmd_args(layer.dir, format = "{{}}/{}".format(ctx.attrs.path))],
        # A runnable tool for `buck2 run` keeps the host view; enclosure is
        # for build actions.
        isolation = "off",
    )
    return [DefaultInfo(), RunInfo(args = run)]

# A runnable tool from a layer: shim-wrapped so the layer's store is
# mounted at /nix/store for the tool and all its children.
nix_tool = rule(
    impl = _nix_tool_impl,
    attrs = {
        "layer": attrs.dep(providers = [NixLayerInfo]),
        "path": attrs.string(),
        "_tools": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
    },
)

def _dir_subpath_impl(ctx):
    layer = ctx.attrs.layer[NixLayerInfo]
    coreutils = ctx.attrs._coreutils[NixLayerInfo]
    shim = ctx.attrs._tools[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("out", dir = ctx.attrs.is_dir)
    # cp comes from the coreutils layer via the shim (RE workers have no
    # host tools); -L dereferences symlinks so the excised subtree stands
    # alone.
    cmd = shim_run(
        shim,
        [
            cmd_args(coreutils.dir, format = "{}/nix/store"),
            cmd_args(layer.dir, format = "{}/nix/store"),
        ],
        [
            parse_spec("coreutils") + "/bin/cp",
            "-rL",
            cmd_args(layer.dir, format = "{{}}/{}".format(ctx.attrs.path)),
            out.as_output(),
        ],
        audit = struct(
            buildtools = ctx.attrs._buildtools[NixLayerInfo].dir,
            pytools = ctx.attrs._pytools[DefaultInfo].default_outputs[0],
        ),
    )
    # RE-able since the ADR-4 carried patch
    # (nix/buck2/patches/0001-find-missing-cache-upload-invalidation.patch):
    # without it, the OSS RE client's stale FindMissingBlobs cache poisoned
    # remote consumers of subpath outputs whose blobs buck2 had uploaded
    # earlier as layer contents.
    ctx.actions.run(cmd, category = "dirlir_subpath")
    return [DefaultInfo(default_output = out)]

# Excise a subtree (header dir, a shared library, ...) from a layer as a
# plain artifact, e.g. for prebuilt_cxx_library.
dir_subpath = rule(
    impl = _dir_subpath_impl,
    attrs = {
        "is_dir": attrs.bool(default = True),
        "layer": attrs.dep(providers = [NixLayerInfo]),
        "path": attrs.string(),
        "_buildtools": attrs.default_only(attrs.exec_dep(
            providers = [NixLayerInfo],
            default = "root//layers:buildtools",
        )),
        "_coreutils": attrs.default_only(attrs.exec_dep(
            providers = [NixLayerInfo],
            default = "root//layers:coreutils",
        )),
        "_pytools": attrs.default_only(attrs.dep(default = "root//dirlir:tools")),
        "_tools": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
    },
)
