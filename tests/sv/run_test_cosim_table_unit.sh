#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

if ! command -v vcs >/dev/null 2>&1; then
    echo "FAIL: VCS is required for cosim table SystemVerilog unit tests" >&2
    exit 1
fi

compile_log="$out_dir/compile.log"
simulation_log="$out_dir/simulation.log"

(
    cd "$out_dir"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        "+incdir+$project_dir/vcs-tb" \
        -top test_cosim_table_unit -o simv \
        "$project_dir/vcs-tb/cosim_table_pkg.sv" \
        "$project_dir/tests/sv/test_cosim_table_unit.sv" \
        2>&1 | tee "$compile_log"
    ./simv 2>&1 | tee "$simulation_log"
)

if ! grep -q '^COSIM_TABLE_UNIT: ALL PASS$' "$simulation_log"; then
    echo "FAIL: cosim table unit test did not report ALL PASS" >&2
    exit 1
fi

if grep -Eiq '(^|[^[:alpha:]])(error|fatal)([^[:alpha:]]|$)' "$simulation_log"; then
    echo "FAIL: cosim table unit simulation reported an error" >&2
    exit 1
fi

echo "COSIM_TABLE_UNIT: ALL PASS"
