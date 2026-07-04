# Bridges between layers and the rest of the buck2 graph.

load("//nix:lock.bzl", "PYTHON3")
load(":providers.bzl", "NixLayerInfo")

def _tools_dir(ctx):
    return ctx.attrs._tools[DefaultInfo].default_outputs[0]

def _nix_store_import_impl(ctx):
    out = ctx.actions.declare_output("out", dir = True)
    cmd = cmd_args(
        PYTHON3,
        cmd_args(_tools_dir(ctx), format = "{}/tools/import_path.py"),
        "--lock",
        ctx.attrs.lock,
        "--path",
        ctx.attrs.store_path,
        "--out",
        out.as_output(),
    )
    ctx.actions.run(cmd, category = "dirlir_import", local_only = True)
    return [DefaultInfo(default_output = out)]

# Import a locked store path as a tracked artifact (via the NAR pipeline,
# not the host store -- works from the committed repo file cache too).
nix_store_import = rule(
    impl = _nix_store_import_impl,
    attrs = {
        "lock": attrs.source(default = "root//nix:lock.json"),
        "store_path": attrs.string(),
        "_tools": attrs.default_only(attrs.dep(default = "root//dirlir:tools")),
    },
)

def _nix_tool_impl(ctx):
    layer = ctx.attrs.layer[NixLayerInfo]
    shim = ctx.attrs._shim[DefaultInfo].default_outputs[0]
    run = cmd_args(
        cmd_args(shim, format = "{}/bin/nix-store-shim"),
        "--store",
        cmd_args(layer.dir, format = "{}/nix/store"),
        "--",
        cmd_args(layer.dir, format = "{{}}/{}".format(ctx.attrs.path)),
    )
    return [DefaultInfo(), RunInfo(args = run)]

# A runnable tool from a layer: shim-wrapped so the layer's store is
# mounted at /nix/store for the tool and all its children.
nix_tool = rule(
    impl = _nix_tool_impl,
    attrs = {
        "layer": attrs.dep(providers = [NixLayerInfo]),
        "path": attrs.string(),
        "_shim": attrs.default_only(attrs.exec_dep(default = "root//nix:shim")),
    },
)

def _dir_subpath_impl(ctx):
    layer = ctx.attrs.layer[NixLayerInfo]
    coreutils = ctx.attrs._coreutils[NixLayerInfo]
    shim = ctx.attrs._shim[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("out", dir = ctx.attrs.is_dir)
    # cp comes from the coreutils layer via the shim (RE workers have no
    # host tools at all); -L dereferences forest symlinks so the excised
    # subtree stands alone.
    cmd = cmd_args(
        cmd_args(shim, format = "{}/bin/nix-store-shim"),
        "--store",
        cmd_args(coreutils.dir, format = "{}/nix/store"),
        "--",
        cmd_args(coreutils.dir, format = "{}/bin/cp"),
        "-rL",
        cmd_args(layer.dir, format = "{{}}/{}".format(ctx.attrs.path)),
        out.as_output(),
    )
    # local_only, like the rest of the dirlir machinery. It would run fine
    # on RE, but this buck2's OSS RE client caches FindMissingBlobs
    # responses without invalidating them after its own uploads, and every
    # soft error is fatal in OSS builds -- so a remote subpath output whose
    # blobs buck2 itself uploaded earlier (layer contents) poisons later
    # remote actions that consume it.
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
        "_shim": attrs.default_only(attrs.exec_dep(default = "root//nix:shim")),
    },
)
