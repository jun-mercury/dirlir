# Symlink round-trip fixtures (graduated M1 spikes): re-prove on every
# buck2 rev bump and every RE backend that absolute + escaping symlinks
# survive artifact round-trips bit-exact (variant C stands on this).
# Actions run through the shim on the buildtools layer — they must work on
# store-less RE workers like every other dirlir action.

load("@root//dirlir:lock_util.bzl", "parse_spec")
load("@root//dirlir:providers.bzl", "NixLayerInfo")
load("@root//dirlir:shim.bzl", "shim_run")

_PY = parse_spec("python3") + "/bin/python3"

def _py_action(ctx, script, args, category, local_only):
    layer = ctx.attrs._buildtools[NixLayerInfo]
    shim = ctx.attrs._tools[DefaultInfo].default_outputs[0]
    cmd = shim_run(
        shim,
        [cmd_args(layer.dir, format = "{}/nix/store")],
        [_PY, script] + args,
        audit = struct(
            buildtools = layer.dir,
            pytools = ctx.attrs._pytools[DefaultInfo].default_outputs[0],
        ),
    )
    ctx.actions.run(cmd, category = category, local_only = local_only)

_COMMON_ATTRS = {
    "_buildtools": attrs.default_only(attrs.exec_dep(
        providers = [NixLayerInfo],
        default = "root//layers:buildtools",
    )),
    "_pytools": attrs.default_only(attrs.dep(default = "root//dirlir:tools")),
    "_tools": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
}

def _symlink_fixture_impl(ctx):
    out = ctx.actions.declare_output("fixture", dir = True)
    _py_action(
        ctx,
        ctx.attrs.fixture_py,
        [out.as_output()],
        "spike_fixture",
        ctx.attrs.local_producer,
    )
    return [DefaultInfo(default_output = out)]

# A dir artifact containing an absolute /nix/store symlink (dangling on the
# host) and a relative symlink escaping the artifact root.
symlink_fixture = rule(
    impl = _symlink_fixture_impl,
    attrs = dict(
        local_producer = attrs.bool(default = True),
        fixture_py = attrs.source(),
        **_COMMON_ATTRS
    ),
)

def _symlink_reader_impl(ctx):
    src = ctx.attrs.fixture[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("manifest.txt")
    _py_action(
        ctx,
        ctx.attrs.reader_py,
        [src, out.as_output()],
        "spike_reader",
        ctx.attrs.local_reader,
    )
    return [DefaultInfo(default_output = out)]

symlink_reader = rule(
    impl = _symlink_reader_impl,
    attrs = dict(
        fixture = attrs.dep(),
        local_reader = attrs.bool(default = False),
        reader_py = attrs.source(),
        **_COMMON_ATTRS
    ),
)
