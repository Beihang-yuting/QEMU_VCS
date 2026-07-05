// pcie_tl_vip standalone regression filelist — vendored/relative paths.
// Invoke vcs from the cosim-platform repo root:
//   vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
//       -f pcie_tl_vip/sim/filelist_local.f -o pcie_tl_vip/sim/simv -l pcie_tl_vip/sim/compile.log
// NOTE: standalone VIP regression does NOT define PCIE_COSIM_ENABLE — no bridge
// DPI is linked, so the CoSim-only DPI imports stay gated out (no unresolved symbols).
// Compile order: host_mem_pkg -> pcie_tl_if -> pcie_tl_pkg -> tests -> tb_top.

// ---- host_mem (hard dep: pcie_tl_pkg imports host_mem_pkg) ----
+incdir+third_party/host_mem/src
third_party/host_mem/src/host_mem_pkg.sv
third_party/host_mem/src/host_mem_manager.sv

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

// ---- tests incdir ----
+incdir+pcie_tl_vip/tests

// ---- interface (must precede package) ----
pcie_tl_vip/src/pcie_tl_if.sv

// ---- top package (includes all src via relative `include) ----
pcie_tl_vip/src/pcie_tl_pkg.sv

// ---- test files ----
pcie_tl_vip/tests/pcie_tl_base_test.sv
pcie_tl_vip/tests/pcie_tl_smoke_test.sv
pcie_tl_vip/tests/pcie_tl_advanced_test.sv
pcie_tl_vip/tests/pcie_tl_unified_mem_test.sv
pcie_tl_vip/tests/pcie_tl_switch_unified_mem_test.sv
pcie_tl_vip/tests/pcie_tl_multi_root_route_test.sv
pcie_tl_vip/tests/pcie_tl_cross_root_isolation_test.sv
pcie_tl_vip/tests/pcie_tl_uneven_ownership_test.sv
pcie_tl_vip/tests/pcie_tl_per_root_tag_test.sv
pcie_tl_vip/tests/pcie_tl_multi_root_stress_test.sv

// ---- testbench top ----
pcie_tl_vip/tests/pcie_tl_tb_top.sv
