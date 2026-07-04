"""Audit-mode wrapper: strace the command and summarize SUCCESSFUL file
opens outside the allowed roots.

Deliberately an over-approximation (ADR-5): a path that opens fine on the
host may ENOENT benignly under enforce; failed opens are filtered as noise,
a small ignore-list covers known tolerated probes, and the enforce run is
the ground truth. No kernel machinery beyond strace.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

IGNORE = (
    "/etc/ld.so.cache",  # succeeds on host, benign ENOENT under enforce
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strace", required=True)
    ap.add_argument("--allow", action="append", default=[],
                    help="extra allowed root (dirlir-run whole-build audits)")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]

    cwd = os.getcwd()
    allowed = tuple([cwd, "/nix/store", "/proc", "/dev", "/tmp"] + args.allow)
    # Exact ancestor dirs of the exec root are fine: tools stat them during
    # path canonicalization, and enforce provides them as empty chain dirs.
    ancestors = set()
    p = cwd
    while p != "/":
        p = os.path.dirname(p)
        ancestors.add(p)
    fd, trace = tempfile.mkstemp(prefix="dirlir-audit-", suffix=".trace")
    os.close(fd)
    rc = subprocess.run(
        [args.strace, "-f", "-e", "trace=%file", "-o", trace, "--"] + cmd
    ).returncode

    hits = {}
    pat = re.compile(r'"(/[^"]*)"')
    with open(trace, errors="replace") as f:
        for line in f:
            if " = -1 " in line:
                continue  # failed opens behave identically under enforce
            m = pat.search(line)
            if not m:
                continue
            p = m.group(1)
            if p.startswith(allowed) or p in IGNORE or p.rstrip("/") in ancestors:
                continue
            hits[p] = hits.get(p, 0) + 1

    if hits:
        top = ", ".join(
            f"{p} ×{n}"
            for p, n in sorted(hits.items(), key=lambda kv: -kv[1])[:3])
        print(
            f"dirlir-audit: {sum(hits.values())} successful opens outside "
            f"allowed roots (top: {top}) — over-approximation; enforce run "
            f"is ground truth — see {trace}",
            file=sys.stderr)
    else:
        print(
            f"dirlir-audit: no successful opens outside allowed roots — "
            f"see {trace}",
            file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
