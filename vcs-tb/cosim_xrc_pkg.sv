/* cosim-platform/vcs-tb/cosim_xrc_pkg.sv
 *
 * Package for the 2-RC cosim-over-Xilinx-AXIS flow. Kept separate from
 * vcs-tb/cosim_pkg.sv (the single-RC stub flow) so the in-flight single-RC
 * work is untouched.
 *
 * Compile AFTER: axis_pkg, pcie_tl_pkg, xilinx_pcie_adapter_pkg, cosim_bridge_pkg.
 */
package cosim_xrc_pkg;
    import uvm_pkg::*;
    import pcie_tl_pkg::*;
    import xilinx_pcie_adapter_pkg::*;
    import cosim_bridge_pkg::*;
    `include "uvm_macros.svh"

    `include "cosim_env_config.sv"    // cosim_env_config extends pcie_tl_env_config
    `include "cosim_xrc_driver.sv"    // cosim_xrc_driver  extends pcie_tl_rc_driver
    `include "cosim_xrc_test.sv"      // cosim_xrc_test    extends uvm_test

    // -----------------------------------------------------------------------
    // 集成开关 —— 现有环境里一行接入 cosim,只做加法,不碰原始功能。
    //   在你 test 的 build_phase 里(env 建之前)调一次:
    //       cosim_xrc_pkg::cosim_maybe_enable();
    //   运行时:
    //       +COSIM        → RC driver 换成 cosim_xrc_driver(收发包来自 QEMU)
    //       (无 +COSIM)   → 你原来的 driver/sequencer 驱动(原始功能,零改动)
    //   driver 自读 +REMOTE_HOST/+PORT_BASE 连 QEMU,instance_id=rc_index。
    //   若你 env 还在用基类 pcie_tl_if_adapter(未接 xilinx),调 cosim_maybe_enable(1)。
    // -----------------------------------------------------------------------
    function automatic void cosim_maybe_enable(bit override_adapter = 0);
        if (!$test$plusargs("COSIM")) return;   // 无 +COSIM:原样,不做任何 override
        if (override_adapter)
            pcie_tl_if_adapter::type_id::set_type_override(xilinx_pcie_if_adapter::get_type());
        pcie_tl_rc_driver::type_id::set_type_override(cosim_xrc_driver::get_type());
    endfunction
endpackage
