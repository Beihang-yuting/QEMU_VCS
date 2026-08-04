#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

sources=(
    "$project_dir/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv"
    "$project_dir/vcs-tb/cosim_runtime_policy_pkg.sv"
    "$project_dir/tests/sv/test_runtime_bdf_utils.sv"
)

if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
    iverilog -g2012 -s test_runtime_bdf_utils \
        -o "$out_dir/test_runtime_bdf_utils.vvp" "${sources[@]}"
    vvp "$out_dir/test_runtime_bdf_utils.vvp"
elif command -v vcs >/dev/null 2>&1; then
    (
        cd "$out_dir"
        vcs -full64 -sverilog -timescale=1ns/1ps \
            -top test_runtime_bdf_utils -o simv "${sources[@]}"
        ./simv
    )
else
    echo "FAIL: neither Icarus Verilog nor VCS is available" >&2
    exit 1
fi
