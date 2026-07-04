# Feature declarations (antlir2's feature.* analogs for directory trees).
#
# Constructors return plain load-time records; the dir_layer macro turns each
# into a hidden `_feature` target whose JSON is consumed by the depgraph.

load(":providers.bzl", "NixFeatureInfo")

def _nix_packages(packages):
    """Materialize nix package closures into <layer>/nix/store.

    packages: list of lockfile package names, optionally with an output
        ("openssl.dev"). Closures resolve at load time from nix/lock.bzl;
    content is addressed by absolute store path (no forests).
    """
    return struct(
        kind = "nix_packages",
        spec = {"packages": packages},
        srcs = {},
    )

def _install(src, dst, mode = None):
    """Install a buck2 artifact (file or directory) at dst."""
    return struct(
        kind = "install",
        spec = {"dst": dst, "mode": mode},
        srcs = {"src": src},
    )

def _ensure_dirs_exist(path):
    """Create a directory chain."""
    return struct(
        kind = "ensure_dirs_exist",
        spec = {"path": path},
        srcs = {},
    )

def _symlink(link, target):
    """Create a symlink at `link`. Absolute targets are layer-absolute and
    get rewritten to relative so the tree stays self-contained."""
    return struct(
        kind = "symlink",
        spec = {"link": link, "target": target},
        srcs = {},
    )

def _remove(path, must_exist = True):
    """Remove a path (usually something inherited from parent_layer)."""
    return struct(
        kind = "remove",
        spec = {"must_exist": must_exist, "path": path},
        srcs = {},
    )

feature = struct(
    ensure_dirs_exist = _ensure_dirs_exist,
    install = _install,
    nix_packages = _nix_packages,
    remove = _remove,
    symlink = _symlink,
)

def _feature_impl(ctx):
    payload = {
        "kind": ctx.attrs.kind,
        "label": str(ctx.label.raw_target()),
        "spec": json.decode(ctx.attrs.spec_json),
    }
    out = ctx.actions.write_json("feature.json", payload)
    return [
        DefaultInfo(default_output = out),
        NixFeatureInfo(feature_json = out, srcs = ctx.attrs.srcs),
    ]

feature_rule = rule(
    impl = _feature_impl,
    attrs = {
        "kind": attrs.string(),
        "spec_json": attrs.string(),
        "srcs": attrs.dict(
            key = attrs.string(),
            value = attrs.source(allow_directory = True),
            default = {},
        ),
    },
)
