// pcie_tl_vip COSIM filelist — VIP + xilinx AXIS adapter + cosim_xrc bridge (VCS side).
// Invoke from repo root, linking the VCS bridge DPI (static whole-archive):
//   vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps +define+PCIE_COSIM_ENABLE \
//       -CFLAGS "-I bridge/common -I bridge/vcs" \
//       -LDFLAGS "-Wl,--whole-archive build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \
//       -f pcie_tl_vip/sim/filelist_cosim.f -o pcie_tl_vip/sim/simv_cosim
// Run:  ./simv_cosim +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +REMOTE_HOST=<QEMU> +PORT_BASE=9100
// Order: host_mem -> axis_vip -> pcie_tl -> xilinx adapter -> bridge_vcs -> cosim_xrc_pkg -> tests -> tb_top.

+define+PCIE_COSIM_ENABLE

// ---- host_mem (pcie_tl_pkg imports host_mem_pkg) ----
+incdir+third_party/host_mem/src
third_party/host_mem/src/host_mem_pkg.sv
third_party/host_mem/src/host_mem_manager.sv

// ---- axis_vip (xilinx adapter dep) ----
+incdir+third_party/axis_vip/src
third_party/axis_vip/src/axis_if.sv
third_party/axis_vip/src/axis_pkg.sv

// ---- pcie_tl_vip source incdirs ----
+incdir+pcie_tl_vip/src
+incdir+pcie_tl_vip/src/types
+incdir+pcie_tl_vip/src/shared
+incdir+pcie_tl_vip/src/agent
+incdir+pcie_tl_vip/src/env
+incdir+pcie_tl_vip/src/adapter
+incdir+pcie_tl_vip/src/seq/base
+incdir+pcie_tl_vip/src/seq/constraints
+incdir+pcie_tl_vip/src/seq/scenario
+incdir+pcie_tl_vip/src/seq/virtual
+incdir+pcie_tl_vip/src/switch

// ---- xilinx adapter + bridge + cosim_xrc incdirs ----
+incdir+third_party/xilinx_pcie/src
+incdir+third_party/xilinx_pcie/tb
+incdir+bridge/vcs
+incdir+vcs-tb
+incdir+pcie_tl_vip/tests

// ---- interface (must precede package) ----
pcie_tl_vip/src/pcie_tl_if.sv

// ---- top package ----
pcie_tl_vip/src/pcie_tl_pkg.sv

// ---- xilinx AXIS adapter (cosim_xrc_pkg dep) ----
third_party/xilinx_pcie/src/xilinx_pcie_params.svh
third_party/xilinx_pcie/src/adapter/xilinx_pcie_adapter_pkg.sv
third_party/xilinx_pcie/src/interface/xilinx_pcie_if.sv
third_party/xilinx_pcie/src/interface/xilinx_pcie_cfg_if.sv

// ---- cosim bridge DPI package + xrc adapter package ----
bridge/vcs/bridge_vcs.sv
vcs-tb/cosim_xrc_pkg.sv

// ---- test files ----
pcie_tl_vip/tests/pcie_tl_base_test.sv
pcie_tl_vip/tests/pcie_tl_cosim_test.sv

// ---- testbench top ----
pcie_tl_vip/tests/pcie_tl_tb_top.sv
