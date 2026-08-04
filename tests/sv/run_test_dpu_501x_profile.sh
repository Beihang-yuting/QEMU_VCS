#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

sources=(
    "$project_dir/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv"
    "$project_dir/tests/sv/test_dpu_501x_profile.sv"
)

if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
    iverilog -g2012 -s test_dpu_501x_profile \
        -o "$out_dir/test_dpu_501x_profile.vvp" "${sources[@]}"
    vvp "$out_dir/test_dpu_501x_profile.vvp"
elif command -v vcs >/dev/null 2>&1; then
    (
        cd "$out_dir"
        vcs -full64 -sverilog -timescale=1ns/1ps \
            -top test_dpu_501x_profile -o simv "${sources[@]}"
        ./simv
    )
else
    echo "FAIL: neither Icarus Verilog nor VCS is available" >&2
    exit 1
fi
