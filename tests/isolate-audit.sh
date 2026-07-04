#!/usr/bin/env bash
# M6 access audit: strace a real gcc compile and assert it touches nothing
# outside the allowed roots — under audit (host view, over-approximation)
# and as ground truth under enforce.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

out_of() { buck2 build "$1" --show-full-output 2>/dev/null | awk '{print $2}'; }
TOOLS=$(out_of root//nix:dirlir-tools)
CXX=$(out_of root//layers:cxx-toolchain)
BUILDTOOLS=$(out_of root//layers:buildtools)
PYTOOLS=$(out_of root//dirlir:tools)
GCC_BIN=$(python3 - <<'EOF'
import re
m = re.search(r'"gcc": \{\s*"storePath": "([^"]*)"', open("nix/lock.bzl").read())
print(m.group(1) + "/bin/gcc")
EOF
)
PY3=$(python3 - <<'EOF'
import re
m = re.search(r'"python3": \{\s*"storePath": "([^"]*)"', open("nix/lock.bzl").read())
print(m.group(1) + "/bin/python3")
EOF
)
STRACE=$(python3 - <<'EOF'
import re
m = re.search(r'"strace": \{\s*"storePath": "([^"]*)"', open("nix/lock.bzl").read())
print(m.group(1) + "/bin/strace")
EOF
)

WORK=$(mktemp -d -p .)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("audited\n"); return 0; }
EOF

echo "== audit (host view): compile must touch nothing outside allowed roots"
summary=$("$TOOLS/bin/dirlir-shim" \
    --store "$CXX/nix/store" --store "$BUILDTOOLS/nix/store" -- \
    "$PY3" "$PYTOOLS/tools/audit.py" --strace "$STRACE" -- \
    "$GCC_BIN" -o "$WORK/t" "$WORK/t.c" 2>&1 >/dev/null | tail -1)
echo "$summary"
grep -q "no successful opens outside allowed roots" <<<"$summary" || {
    echo "AUDIT TEST FAILED: unexpected accesses"
    exit 1
}

echo "== enforce (ground truth): same compile, enclosed"
"$TOOLS/bin/dirlir-shim" --enclose \
    --store "$CXX/nix/store" -- \
    "$GCC_BIN" -o "$WORK/t2" "$WORK/t.c"
"$WORK/t2" >/dev/null 2>&1 || true  # runtime needs the mounted store; compile success is the assertion

echo "AUDIT TESTS PASSED"
