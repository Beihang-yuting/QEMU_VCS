// filelist_adapter_local.f — vendored/relative paths for cosim-platform.
// Invoke vcs from the cosim-platform repo root (see scripts/remote_xilinx_adapter.sh):
//   vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
//       -f third_party/xilinx_pcie/sim/filelist_adapter_local.f \
//       +define+DATA_WIDTH=256 +define+STRADDLE_EN=0 -o work/simv_ad -l logs/compile_ad.log
// NO PCIE_COSIM_ENABLE: pure VIP build, CoSim DPI stays gated out.
// Order: axis lib -> host_mem -> pcie_tl_if -> pcie_tl_pkg -> xilinx -> tests -> tb.

// ---- axis_vip (lib only: if + pkg; SVA excluded, matches upstream filelist_lib.f) ----
+incdir+third_party/axis_vip/src
third_party/axis_vip/src/axis_if.sv
third_party/axis_vip/src/axis_pkg.sv

// ---- host_mem (hard dep of pcie_tl_pkg) ----
+incdir+third_party/host_mem/src
third_party/host_mem/src/host_mem_pkg.sv
third_party/host_mem/src/host_mem_manager.sv

// ---- pcie_tl_vip (protocol layer, delegated) ----
+incdir+pcie_tl_vip/src
pcie_tl_vip/src/pcie_tl_if.sv
pcie_tl_vip/src/pcie_tl_pkg.sv

// ---- xilinx adapter ----
+incdir+third_party/xilinx_pcie/src
+incdir+third_party/xilinx_pcie/tb
third_party/xilinx_pcie/src/xilinx_pcie_params.svh
third_party/xilinx_pcie/src/adapter/xilinx_pcie_adapter_pkg.sv
third_party/xilinx_pcie/src/interface/xilinx_pcie_if.sv
third_party/xilinx_pcie/src/interface/xilinx_pcie_cfg_if.sv

// ---- adapter tests ----
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_base_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_smoke_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_cfg_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_enum_dma_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_rdwr_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_backpressure_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_err_poisoned_test.sv
third_party/xilinx_pcie/tests/xilinx_pcie_adapter_no_rc_test.sv

// ---- testbench top ----
third_party/xilinx_pcie/tb/tb_adapter_top.sv
