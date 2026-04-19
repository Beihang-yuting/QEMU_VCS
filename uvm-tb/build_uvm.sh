#!/bin/bash
# build_uvm.sh — Compile and run UVM testbench with VCS
#
# Usage:
#   ./build_uvm.sh [test_name]
#   ./build_uvm.sh cosim_cfgrd_test
#   ./build_uvm.sh cosim_bar_rw_test
#   ./build_uvm.sh cosim_random_test
#   ./build_uvm.sh cosim_functional_test

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
UVM_TB_DIR="$SCRIPT_DIR"
VCS_TB_DIR="$PROJECT_DIR/vcs-tb"
BRIDGE_DIR="$PROJECT_DIR/bridge/vcs"
OUT_DIR="$SCRIPT_DIR/sim_out"

# Default test
TEST_NAME="${1:-cosim_cfgrd_test}"

# UVM home (VCS built-in)
UVM_HOME="${VCS_HOME}/etc/uvm-1.2"

echo "=========================================="
echo " CoSim UVM Testbench Build"
echo "=========================================="
echo "Test:       $TEST_NAME"
echo "VCS_HOME:   $VCS_HOME"
echo "UVM_HOME:   $UVM_HOME"
echo "=========================================="

# Create output directory
mkdir -p "$OUT_DIR"

# Compile
echo "[1/2] Compiling with VCS..."
cd "$OUT_DIR"

vcs -full64 -sverilog -debug_access+all \
    -ntb_opts uvm-1.2 \
    +incdir+"$UVM_HOME/src" \
    +incdir+"$UVM_TB_DIR" \
    +incdir+"$BRIDGE_DIR" \
    "$BRIDGE_DIR/bridge_vcs.sv" \
    "$UVM_TB_DIR/cosim_if.sv" \
    "$UVM_TB_DIR/cosim_pkg.sv" \
    "$VCS_TB_DIR/pcie_ep_stub.sv" \
    "$UVM_TB_DIR/tb_uvm_top.sv" \
    -o simv_uvm \
    -l compile.log \
    +define+UVM_NO_DPI \
    -timescale=1ns/1ps \
    2>&1

if [ $? -ne 0 ]; then
    echo "[ERROR] VCS compilation failed. See $OUT_DIR/compile.log"
    exit 1
fi

echo "[1/2] Compilation successful."

# Run
echo "[2/2] Running simulation: +UVM_TESTNAME=$TEST_NAME"
./simv_uvm \
    +UVM_TESTNAME=$TEST_NAME \
    +UVM_VERBOSITY=UVM_MEDIUM \
    -l run_${TEST_NAME}.log \
    +DUMP_VCD \
    2>&1

echo ""
echo "=========================================="
echo " Simulation complete"
echo " Log: $OUT_DIR/run_${TEST_NAME}.log"
echo "=========================================="

# Check result
if grep -q "RESULT: ALL TESTS PASSED" run_${TEST_NAME}.log 2>/dev/null; then
    echo " >>> PASSED <<<"
elif grep -q "UVM_FATAL" run_${TEST_NAME}.log 2>/dev/null; then
    echo " >>> FATAL ERROR <<<"
    exit 1
elif grep -q "RESULT: TESTS FAILED" run_${TEST_NAME}.log 2>/dev/null; then
    echo " >>> FAILED <<<"
    exit 1
else
    echo " >>> CHECK LOG <<<"
fi
