// Include search path for `include "axis_params.svh" (self-contained for -f consumers)
+incdir+/home/ubuntu/ryan/axis_work/axis_vip/src

// Interface (compiled separately, not in package)
../src/axis_if.sv

// SVA protocol checker (module, not in package)
../src/axis_protocol_checker_sva.sv

// Package (includes all class files)
../src/axis_pkg.sv

// Tests (included after package)
../tests/axis_base_test.sv
../tests/axis_sanity_test.sv
../tests/axis_backpressure_test.sv
../tests/axis_bandwidth_test.sv
../tests/axis_reset_test.sv
../tests/axis_phase_jump_test.sv
../tests/axis_full_regression_test.sv
../tests/axis_misalign_test.sv

// DUT
../tb/axis_dummy_dut.sv

// Testbench top
../tb/tb_top.sv
