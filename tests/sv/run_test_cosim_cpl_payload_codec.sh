#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

sources=(
    "$project_dir/vcs-tb/cosim_xrc_utils_pkg.sv"
    "$project_dir/tests/sv/test_cosim_cpl_payload_codec.sv"
)

if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
    iverilog -g2012 -s test_cosim_cpl_payload_codec \
        -o "$out_dir/test_cosim_cpl_payload_codec.vvp" "${sources[@]}"
    vvp "$out_dir/test_cosim_cpl_payload_codec.vvp"
elif command -v vcs >/dev/null 2>&1; then
    (
        cd "$out_dir"
        vcs -full64 -sverilog -timescale=1ns/1ps \
            -top test_cosim_cpl_payload_codec -o simv "${sources[@]}"
        ./simv
    )
else
    echo "FAIL: neither Icarus Verilog nor VCS is available" >&2
    exit 1
fi
