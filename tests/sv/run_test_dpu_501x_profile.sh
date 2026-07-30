#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

iverilog -g2012 -s test_dpu_501x_profile \
    -o "$out_dir/test_dpu_501x_profile.vvp" \
    "$project_dir/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv" \
    "$project_dir/tests/sv/test_dpu_501x_profile.sv"
vvp "$out_dir/test_dpu_501x_profile.vvp"
