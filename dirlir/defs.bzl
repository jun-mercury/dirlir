# dir_layer: antlir2's image.layer analog producing a plain directory tree.
#
# Two actions per layer, preserving antlir2's plan/compile split:
#   1. dirlir_plan (depgraph.py): validate feature provides/requires against
#      the lockfile and parent facts, toposort, resolve nix closures
#      -> plan.json. Conflicts fail here, before any materialization.
#   2. dirlir_materialize (materialize.py): copy parent, fetch+unpack NARs
#      from binary caches (verifying FileHash and NarHash), rewrite absolute
#      store symlinks to relative, apply features -> the tree + facts.json.
#
# Both actions are local_only: they need network and the lockfile-pinned
# python. Everything CONSUMING a layer sees only the tree artifact (+ the
# static shim) and is remote-execution compatible -- the same posture as
# antlir2's local-only btrfs builds with RE-able consumers.

load("//nix:lock.bzl", "PYTHON3")
load(":features.bzl", "feature_rule")
load(":providers.bzl", "NixFeatureInfo", "NixLayerInfo")

def _dir_layer_impl(ctx):
    features = [f[NixFeatureInfo] for f in ctx.attrs.features]
    parent = ctx.attrs.parent_layer[NixLayerInfo] if ctx.attrs.parent_layer else None
    tools = ctx.attrs._tools[DefaultInfo].default_outputs[0]

    plan = ctx.actions.declare_output("plan.json")
    plan_cmd = cmd_args(
        PYTHON3,
        cmd_args(tools, format = "{}/tools/depgraph.py"),
        "--lock",
        ctx.attrs.lock,
        "--out",
        plan.as_output(),
    )
    if parent:
        plan_cmd.add("--parent-facts", parent.facts)
    for f in features:
        plan_cmd.add("--feature", f.feature_json)
    ctx.actions.run(plan_cmd, category = "dirlir_plan", local_only = True)

    # Feature srcs, keyed by "<feature index>:<name>" to match plan ids.
    srcs = {}
    for i, f in enumerate(features):
        for name, artifact in f.srcs.items():
            srcs["{}:{}".format(i, name)] = artifact
    srcs_json = ctx.actions.write_json("srcs.json", srcs, with_inputs = True)

    out = ctx.actions.declare_output("layer", dir = True)
    facts = ctx.actions.declare_output("facts.json")
    mat_cmd = cmd_args(
        PYTHON3,
        cmd_args(tools, format = "{}/tools/materialize.py"),
        "--plan",
        plan,
        "--lock",
        ctx.attrs.lock,
        "--srcs",
        srcs_json,
        "--out",
        out.as_output(),
        "--facts-out",
        facts.as_output(),
    )
    if parent:
        mat_cmd.add("--parent", parent.dir)
    ctx.actions.run(mat_cmd, category = "dirlir_materialize", local_only = True)

    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {
                "facts": [DefaultInfo(default_output = facts)],
                "plan": [DefaultInfo(default_output = plan)],
            },
        ),
        NixLayerInfo(dir = out, facts = facts, lock = ctx.attrs.lock),
    ]

_dir_layer = rule(
    impl = _dir_layer_impl,
    attrs = {
        "features": attrs.list(
            attrs.dep(providers = [NixFeatureInfo]),
            default = [],
        ),
        "lock": attrs.source(default = "root//nix:lock.json"),
        "parent_layer": attrs.option(
            attrs.dep(providers = [NixLayerInfo]),
            default = None,
        ),
        "_tools": attrs.default_only(
            attrs.dep(default = "root//dirlir:tools"),
        ),
    },
)

def dir_layer(name, features = [], parent_layer = None, visibility = None, lock = None):
    """Define a directory layer from a list of features.

    features: feature.* records (inline) or labels of feature targets.
    """
    deps = []
    for i, f in enumerate(features):
        if type(f) == type(""):
            deps.append(f)
            continue
        fname = "{}--feature-{}".format(name, i)
        feature_rule(
            name = fname,
            kind = f.kind,
            spec_json = json.encode(f.spec),
            srcs = f.srcs,
        )
        deps.append(":" + fname)

    kwargs = {}
    if lock != None:
        kwargs["lock"] = lock
    _dir_layer(
        name = name,
        features = deps,
        parent_layer = parent_layer,
        visibility = visibility,
        **kwargs
    )
