# Bootstrap: build the static dirlir tools from this repo's flake via a
# local `nix build` action (the buck2.nix pattern, applied ONLY here).
# These are the sole local_only actions in dirlir v2 — leaf exec_deps whose
# outputs are CAS-cached, so RE workers never run them. No binaries in git,
# no drift: the tools always match the flake (PLAN-v2 ADR on bootstrap).

def _nix_flake_tool_impl(ctx):
    out = ctx.actions.declare_output("out", dir = True)
    # Explicit experimental-features: host nix.conf may be unreachable
    # (inside dirlir-run's mask, /etc/nix resolves through masked store paths).
    script = (
        'set -e; p=$(nix --extra-experimental-features "nix-command flakes" ' +
        'build --no-link --print-out-paths ".#{}"); ' +
        'cp -r "$p" "$1"; chmod -R u+w "$1"'
    ).format(ctx.attrs.package)
    cmd = cmd_args(["sh", "-c", script, "sh", out.as_output()])
    # Declared so flake/source changes re-run the build.
    cmd.add(cmd_args(hidden = ctx.attrs.srcs))
    ctx.actions.run(cmd, category = "nix_flake_tool", local_only = True)
    return [DefaultInfo(default_output = out)]

nix_flake_tool = rule(
    impl = _nix_flake_tool_impl,
    attrs = {
        "package": attrs.string(),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)
