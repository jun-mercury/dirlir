# M1 spike rules (PLAN-v2.md). S2 fixtures graduate to tests/symlink-roundtrip.

def _nar_download_impl(ctx):
    out = ctx.actions.declare_output("download.nar")
    ctx.actions.download_file(
        out,
        ctx.attrs.url,
        sha256 = ctx.attrs.sha256,
        size_bytes = ctx.attrs.size_bytes,
    )
    return [DefaultInfo(default_output = out)]

# S1: buck2-native NAR download where sha256 == the locked NarHash (snix
# serves uncompressed NARs).
nar_download = rule(
    impl = _nar_download_impl,
    attrs = {
        "sha256": attrs.string(),
        "size_bytes": attrs.int(),
        "url": attrs.string(),
    },
)

_FIXTURE_CMD = (
    'mkdir -p "$1/sub" && echo hi > "$1/sub/real.txt" && ' +
    'ln -s /nix/store/00000000000000000000000000000000-spike/bin/x "$1/abs-link" && ' +
    'ln -s ../outside/escaping "$1/sub/escape-link" && ' +
    'ln -s sub/real.txt "$1/internal-link"'
)

# The redirect must open $2 before the cd (it is exec-root relative).
_READER_CMD = (
    '{ cd "$1" && find . | sort && find . -type l | sort | while read -r l; do ' +
    'printf "%s -> %s\\n" "$l" "$(readlink "$l")"; done; } > "$2"'
)

# The spike probes CAS symlink fidelity, not worker tooling: hand actions a
# host PATH (spike runs against a plain-host NativeLink worker).
_SPIKE_ENV = {"PATH": "/run/current-system/sw/bin:/usr/bin:/bin"}

def _symlink_fixture_impl(ctx):
    out = ctx.actions.declare_output("fixture", dir = True)
    ctx.actions.run(
        ["sh", "-c", _FIXTURE_CMD, "sh", out.as_output()],
        category = "spike_fixture",
        env = _SPIKE_ENV,
        local_only = ctx.attrs.local_producer,
    )
    return [DefaultInfo(default_output = out)]

# S2: a dir artifact containing an absolute /nix/store symlink (dangling on
# the host) and a relative symlink escaping the artifact root.
symlink_fixture = rule(
    impl = _symlink_fixture_impl,
    attrs = {
        "local_producer": attrs.bool(default = True),
    },
)

def _symlink_reader_impl(ctx):
    src = ctx.attrs.fixture[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("manifest.txt")
    ctx.actions.run(
        ["sh", "-c", _READER_CMD, "sh", src, out.as_output()],
        category = "spike_reader",
        env = _SPIKE_ENV,
        local_only = ctx.attrs.local_reader,
    )
    return [DefaultInfo(default_output = out)]

symlink_reader = rule(
    impl = _symlink_reader_impl,
    attrs = {
        "fixture": attrs.dep(),
        "local_reader": attrs.bool(default = False),
    },
)
