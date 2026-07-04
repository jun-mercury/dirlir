#!/usr/bin/env bash
# M6 enclosure verification: mask semantics, failure-UX trailer TEXT,
# digest separation, audit-mode smoke.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
say() { echo "== $*"; }

say "leak probe compiles clean under enforce (host /etc masked)"
if ! buck2 build tests//enclosure:leak-probe >/dev/null 2>&1; then
    echo "FAIL: leak-probe did not build under enforce"
    fail=1
fi

say "leak probe FAILS under isolation=off with the probe's own error"
out=$(buck2 build -c dirlir.isolation=off tests//enclosure:leak-probe 2>&1)
if [ $? -eq 0 ] || ! grep -q "host-etc-visible" <<<"$out"; then
    echo "FAIL: expected host-etc-visible failure under off"
    fail=1
fi

say "bad include under enforce carries the trailer text"
out=$(buck2 build tests//enclosure:bad-include 2>&1)
if grep -q "dirlir-shim\[enclose\]: command failed inside minimal root" <<<"$out" &&
   grep -q -- "-c dirlir.isolation=off to bypass" <<<"$out"; then
    :
else
    echo "FAIL: trailer text missing under enforce"
    fail=1
fi

say "bad include under off has NO trailer"
out=$(buck2 build -c dirlir.isolation=off tests//enclosure:bad-include 2>&1)
if grep -q "dirlir-shim\[enclose\]" <<<"$out"; then
    echo "FAIL: trailer printed without enclosure"
    fail=1
fi

say "digest separation: enforce -> off re-EXECUTES (never cache-shares)"
buck2 build root//examples/hello_c:main >/dev/null 2>&1
buck2 build -c dirlir.isolation=off root//examples/hello_c:main >/dev/null 2>&1
ran=$(buck2 log what-ran 2>/dev/null | grep -c "c_compile\|cxx_link")
if [ "$ran" -lt 1 ]; then
    echo "FAIL: off-mode build did not re-execute wrapped actions"
    fail=1
fi

say "audit mode builds and routes through audit.py"
if ! buck2 build -c dirlir.isolation=audit root//examples/hello_c:main >/dev/null 2>&1; then
    echo "FAIL: audit-mode build failed"
    fail=1
elif ! buck2 log what-ran 2>/dev/null | grep -m1 c_compile | grep -q "audit.py"; then
    echo "FAIL: audit-mode compile did not run through audit.py"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "ENCLOSURE TESTS PASSED"
fi
exit "$fail"
