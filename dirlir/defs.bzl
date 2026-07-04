# dirlir layers.
#
# nix_closure: a featureless layer — zero-copy composition of per-path
# artifacts (variant C), facts written at analysis time.
#
# dir_layer: antlir2's image.layer analog with features. ONE action
# (category dirlir_layer) runs layer.py through dirlir-shim with the
# buildtools closure provisioned: validate (the depgraph, first, cheap) →
# toposort → assemble → slim facts. Hermetic and RE-able: every input is
# an artifact; no network, no lockfile, no host interpreter.

load(":features.bzl", "feature_rule")
load(":lock_util.bzl", "closure", "parse_spec")
load(":nar.bzl", "NixStorePathInfo")
load(":providers.bzl", "NixFeatureInfo", "NixLayerInfo")
load(":shim.bzl", "shim_run")

_PYTHON3 = parse_spec("python3") + "/bin/python3"

def _nix_closure_impl(ctx):
    entries = {}
    facts = {"nix": {"type": "dir"}, "nix/store": {"type": "dir"}}
    for dep in ctx.attrs.store_paths:
        info = dep[NixStorePathInfo]
        rel = "nix/store/" + info.store_path.split("/")[-1]
        entries[rel] = info.dir
        facts[rel] = {"type": "store_path"}
    out = ctx.actions.symlinked_dir("layer", entries)
    facts_out = ctx.actions.write_json("facts.json", facts)
    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {"facts": [DefaultInfo(default_output = facts_out)]},
        ),
        NixLayerInfo(dir = out, facts = facts_out),
    ]

_nix_closure = rule(
    impl = _nix_closure_impl,
    attrs = {
        "store_paths": attrs.list(attrs.dep(providers = [NixStorePathInfo])),
    },
)

def nix_closure(name, packages, visibility = None):
    """A featureless layer: the closure of `packages`, composed zero-copy."""
    paths = closure([parse_spec(s) for s in packages])
    _nix_closure(
        name = name,
        store_paths = ["root//nix:" + p.split("/")[-1] for p in paths],
        visibility = visibility,
    )

def _dir_layer_impl(ctx):
    features = [f[NixFeatureInfo] for f in ctx.attrs.features]
    parent = ctx.attrs.parent_layer[NixLayerInfo] if ctx.attrs.parent_layer else None
    tools = ctx.attrs._pytools[DefaultInfo].default_outputs[0]
    shim = ctx.attrs._shim[DefaultInfo].default_outputs[0]
    buildtools = ctx.attrs._buildtools[NixLayerInfo]

    srcs = {}
    for i, f in enumerate(features):
        for name, artifact in f.srcs.items():
            srcs["{}:{}".format(i, name)] = artifact
    srcs_json = ctx.actions.write_json("srcs.json", srcs, with_inputs = True)

    store_map = {}
    for dep in ctx.attrs.store_paths:
        info = dep[NixStorePathInfo]
        store_map[info.store_path] = info.dir
    store_map_json = ctx.actions.write_json(
        "store_map.json",
        store_map,
        with_inputs = True,
    )

    out = ctx.actions.declare_output("layer", dir = True)
    facts = ctx.actions.declare_output("facts.json")
    argv = cmd_args(
        _PYTHON3,
        cmd_args(tools, format = "{}/tools/layer.py"),
        "--store-map",
        store_map_json,
        "--srcs",
        srcs_json,
        "--out",
        out.as_output(),
        "--facts-out",
        facts.as_output(),
    )
    for f in features:
        argv.add("--feature", f.feature_json)
    if parent:
        argv.add("--parent", parent.dir, "--parent-facts", parent.facts)

    cmd = shim_run(
        shim,
        [cmd_args(buildtools.dir, format = "{}/nix/store")],
        [argv],
        audit = struct(buildtools = buildtools.dir, pytools = tools),
    )
    ctx.actions.run(cmd, category = "dirlir_layer")

    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {"facts": [DefaultInfo(default_output = facts)]},
        ),
        NixLayerInfo(dir = out, facts = facts),
    ]

_dir_layer = rule(
    impl = _dir_layer_impl,
    attrs = {
        "features": attrs.list(
            attrs.dep(providers = [NixFeatureInfo]),
            default = [],
        ),
        "parent_layer": attrs.option(
            attrs.dep(providers = [NixLayerInfo]),
            default = None,
        ),
        "store_paths": attrs.list(
            attrs.dep(providers = [NixStorePathInfo]),
            default = [],
        ),
        "_buildtools": attrs.default_only(attrs.exec_dep(
            providers = [NixLayerInfo],
            default = "root//layers:buildtools",
        )),
        "_pytools": attrs.default_only(attrs.dep(default = "root//dirlir:tools")),
        "_shim": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
    },
)

def dir_layer(name, features = [], parent_layer = None, visibility = None):
    """Define a directory layer from a list of feature.* records.

    nix_packages closures resolve here, at load time; the layer action
    receives per-path artifacts, never the lockfile.
    """
    deps = []
    all_paths = {}
    for i, f in enumerate(features):
        spec = dict(f.spec)
        if f.kind == "nix_packages":
            paths = closure([parse_spec(s) for s in spec["packages"]])
            spec["closure"] = paths
            for p in paths:
                all_paths[p] = True
        fname = "{}--feature-{}".format(name, i)
        feature_rule(
            name = fname,
            kind = f.kind,
            spec_json = json.encode(spec),
            srcs = f.srcs,
        )
        deps.append(":" + fname)

    _dir_layer(
        name = name,
        features = deps,
        parent_layer = parent_layer,
        store_paths = ["root//nix:" + p.split("/")[-1] for p in all_paths],
        visibility = visibility,
    )
