# The single way dirlir wraps action commands in dirlir-shim, and the home
# of the isolation knob.
#
# [dirlir] isolation = off | audit | enforce   (default: enforce)
#
# Read at LOAD time (read_root_config; a `-c dirlir.isolation=...` change
# reloads, re-analyzes, and produces new cmd_args) and placed in the command
# line — so each mode gets DISTINCT action digests and modes never share
# cache entries (ADR-6). The per-invocation escape hatch is
# `buck2 build -c dirlir.isolation=off <target>`; there is deliberately no
# runtime env override for actions.
#
# `[dirlir] salt` rides along the same way (offline-test invalidation: bump
# it to re-run every shim-wrapped action while native downloads stay cached).

_ISOLATION = read_root_config("dirlir", "isolation", "enforce")
_SALT = read_root_config("dirlir", "salt", "")

_FAIL_HINT = (
    "rerun with -c dirlir.isolation=off to bypass or " +
    "-c dirlir.isolation=audit to compare"
)

def shim_run(shim, store_dirs, argv, isolation = None):
    """cmd_args running `argv` through dirlir-shim with `store_dirs` provisioned.

    shim: the dirlir-tools dir artifact (bin/dirlir-shim inside).
    store_dirs: values usable as --store arguments (each a dir whose entries
        are store paths, e.g. cmd_args(layer.dir, format = "{}/nix/store")).
    isolation: optional override of the [dirlir] knob.
    """
    mode = isolation if isolation != None else _ISOLATION
    if mode not in ("off", "audit", "enforce"):
        fail("dirlir.isolation must be off|audit|enforce, got: " + mode)
    if mode == "audit":
        # Audit needs strace from the buildtools layer; arrives in M6.
        fail("dirlir.isolation=audit is not wired yet (lands with the buildtools layer)")

    cmd = cmd_args(cmd_args(shim, format = "{}/bin/dirlir-shim"))
    for s in store_dirs:
        cmd.add("--store", s)
    if mode == "enforce":
        cmd.add("--enclose", "--fail-hint", _FAIL_HINT)
    if _SALT:
        cmd.add("--salt", _SALT)
    cmd.add("--")
    cmd.add(argv)
    return cmd
