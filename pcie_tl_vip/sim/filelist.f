// pcie_tl_vip filelist — remote paths for VCS compilation
// Compile order: host_mem_pkg → pcie_tl_if → pcie_tl_pkg → test files → tb_top

// ---- host_mem incdir + files ----
+incdir+/home/ryan/shm_work/host_mem/src
/home/ryan/shm_work/host_mem/src/host_mem_pkg.sv
/home/ryan/shm_work/host_mem/src/host_mem_manager.sv

// ---- pcie_tl_vip source incdirs ----
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/types
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/shared
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/agent
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/env
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/adapter
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/base
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/constraints
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/scenario
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/virtual
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/switch

// ---- tests incdir (for test files compiled as separate units) ----
+incdir+/home/ryan/pcie_work/pcie_tl_vip/tests

// ---- pcie_tl interface (must precede package) ----
/home/ryan/pcie_work/pcie_tl_vip/src/pcie_tl_if.sv

// ---- pcie_tl top package (includes all src via relative `include) ----
/home/ryan/pcie_work/pcie_tl_vip/src/pcie_tl_pkg.sv

// ---- test files (separate compile units — each has top-level import) ----
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_base_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_smoke_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_advanced_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_unified_mem_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_switch_unified_mem_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_multi_root_route_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_cross_root_isolation_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_uneven_ownership_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_per_root_tag_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_multi_root_stress_test.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_multipair_heavy_test.sv

// ---- testbench top module ----
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_tb_top.sv
