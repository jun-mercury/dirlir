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
    out = ctx.actions.declare_output("out", dir = ctx.attrs.is_dir)
    # -L dereferences forest symlinks: the excised subtree must stand alone.
    cmd = cmd_args(
        "cp",
        "-rL",
        cmd_args(layer.dir, format = "{{}}/{}".format(ctx.attrs.path)),
        out.as_output(),
    )
    ctx.actions.run(cmd, category = "dirlir_subpath")
    return [DefaultInfo(default_output = out)]

# Excise a subtree (header dir, a shared library, ...) from a layer as a
# plain artifact, e.g. for prebuilt_cxx_library. RE-able.
dir_subpath = rule(
    impl = _dir_subpath_impl,
    attrs = {
        "is_dir": attrs.bool(default = True),
        "layer": attrs.dep(providers = [NixLayerInfo]),
        "path": attrs.string(),
    },
)
