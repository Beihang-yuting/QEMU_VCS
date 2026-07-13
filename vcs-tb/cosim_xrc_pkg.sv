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
endpackage
