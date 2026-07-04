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
    )
    # local_only: this buck2's OSS RE client caches FindMissingBlobs
    # responses without invalidating them after its own uploads, and every
    # soft error is fatal in OSS builds -- a remote subpath output whose
    # blobs buck2 itself uploaded earlier (layer contents) poisons later
    # remote actions that consume it. Primary remedy if this must go
    # remote: a carried buck2 patch (ADR-4).
    ctx.actions.run(cmd, category = "dirlir_subpath", local_only = True)
    return [DefaultInfo(default_output = out)]

# Excise a subtree (header dir, a shared library, ...) from a layer as a
# plain artifact, e.g. for prebuilt_cxx_library.
dir_subpath = rule(
    impl = _dir_subpath_impl,
    attrs = {
        "is_dir": attrs.bool(default = True),
        "layer": attrs.dep(providers = [NixLayerInfo]),
        "path": attrs.string(),
        "_coreutils": attrs.default_only(attrs.exec_dep(
            providers = [NixLayerInfo],
            default = "root//layers:coreutils",
        )),
        "_tools": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
    },
)
