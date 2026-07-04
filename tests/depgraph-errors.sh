#!/usr/bin/env bash
# Expected-failure tests for the depgraph (plan) phase: these layers must
# fail BEFORE materialization, with errors naming the offending features.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
expect_fail() {
    local target=$1 pattern=$2
    local out
    if out=$(buck2 build "$target" 2>&1); then
        echo "FAIL: $target unexpectedly built"
        fail=1
        return
    fi
    if ! grep -q "$pattern" <<<"$out"; then
        echo "FAIL: $target error did not match '$pattern'; got:"
        echo "$out" | tail -6
        fail=1
        return
    fi
    echo "ok: $target ($pattern)"
}

expect_fail tests//depgraph-errors:conflict "path conflict on 'data.txt'"
expect_fail tests//depgraph-errors:dangling-symlink "unsatisfiable feature requirements"
expect_fail tests//depgraph-errors:missing-dir "unsatisfiable feature requirements"

if [ "$fail" -eq 0 ]; then
    echo "depgraph error tests passed"
fi
exit "$fail"
