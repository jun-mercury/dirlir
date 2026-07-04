# Per-store-path artifacts: buck2-native NAR download (hash-verified by
# buck2 itself: snix serves uncompressed NARs, so sha256 == the locked
# NarHash) + static nar-unpack. Both actions are RE-able by construction;
# neither needs an interpreter or network access inside an action (the
# download is executed by buck2, not as an action process).

load("@root//nix:lock.bzl", "PATHS")
load(":shim.bzl", "SALT")

NixStorePathInfo = provider(fields = {
    "dir": provider_field(typing.Any),  # Artifact: the unpacked store path
    "store_path": provider_field(typing.Any),  # str: /nix/store/<base>
})

def _nix_path_impl(ctx):
    nar = ctx.actions.declare_output("download.nar")
    ctx.actions.download_file(
        nar,
        ctx.attrs.url,
        sha256 = ctx.attrs.sha256,
        size_bytes = ctx.attrs.nar_size,
    )
    tools = ctx.attrs._tools[DefaultInfo].default_outputs[0]
    base = ctx.attrs.store_path.split("/")[-1]
    # Store entries can be directories OR single files (source tarballs in
    # closures); unpack inside a wrapper dir and project the entry out.
    out = ctx.actions.declare_output("root", dir = True)
    ctx.actions.run(
        cmd_args(
            cmd_args(tools, format = "{}/bin/nar-unpack"),
            "--size",
            str(ctx.attrs.nar_size),
            nar,
            cmd_args(out.as_output(), format = "{{}}/{}".format(base)),
        ),
        category = "nar_unpack",
        # The salt enters via env (digest-relevant); nar-unpack has no
        # argv slot for it and needs none.
        env = {"DIRLIR_SALT": SALT} if SALT else {},
    )
    entry = out.project(base)
    return [
        DefaultInfo(default_output = entry),
        NixStorePathInfo(dir = entry, store_path = ctx.attrs.store_path),
    ]

nix_path = rule(
    impl = _nix_path_impl,
    attrs = {
        "nar_size": attrs.int(),
        "sha256": attrs.string(),
        "store_path": attrs.string(),
        "url": attrs.string(),
        "_tools": attrs.default_only(attrs.exec_dep(default = "root//nix:dirlir-tools")),
    },
)

def nix_store_paths():
    """One nix_path target per locked store path: root//nix:<basename>.

    The antlir2 per-RPM-target analog: `buck2 uquery` shows the whole
    supply chain, downloads dedupe across every layer, and each path
    caches independently.
    """
    for path, info in PATHS.items():
        nix_path(
            name = path.split("/")[-1],
            nar_size = info["nar_size"],
            sha256 = info["sha256"],
            store_path = path,
            url = info["url"],
            visibility = ["PUBLIC"],
        )
