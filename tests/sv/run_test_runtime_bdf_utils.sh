#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)

iverilog -g2012 -s test_runtime_bdf_utils \
    -o "$out_dir/test_runtime_bdf_utils.vvp" \
    "$project_dir/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv" \
    "$project_dir/vcs-tb/cosim_runtime_policy_pkg.sv" \
    "$project_dir/tests/sv/test_runtime_bdf_utils.sv"
vvp "$out_dir/test_runtime_bdf_utils.vvp"
