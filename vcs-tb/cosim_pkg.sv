/* cosim-platform/vcs-tb/cosim_pkg.sv
 * Package wrapper for cosim-specific UVM classes.
 * These classes extend pcie_tl_pkg types, so they must be compiled
 * within a package that imports pcie_tl_pkg.
 */

package cosim_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import pcie_tl_pkg::*;
    /* Import only DPI-C functions from cosim_bridge_pkg to avoid
     * enum name collision (TLP_CPL, TLP_MSG, etc. exist in both
     * pcie_tl_pkg and cosim_bridge_pkg). */
    import cosim_bridge_pkg::bridge_vcs_init;
    import cosim_bridge_pkg::bridge_vcs_poll_tlp;
    import cosim_bridge_pkg::bridge_vcs_send_completion;
    import cosim_bridge_pkg::bridge_vcs_cleanup;
    import cosim_bridge_pkg::bridge_vcs_dma_request;
    import cosim_bridge_pkg::bridge_vcs_dma_read_sync;
    import cosim_bridge_pkg::bridge_vcs_dma_write_sync;
    import cosim_bridge_pkg::bridge_vcs_raise_msi;
    import cosim_bridge_pkg::bridge_vcs_wait_clock_step;
    import cosim_bridge_pkg::bridge_vcs_clock_ack;
    /* Fully-scalar DPI wrappers for VCS Q-2020 package-scope compatibility */
    import cosim_bridge_pkg::bridge_vcs_poll_tlp_scalar;
    import cosim_bridge_pkg::bridge_vcs_get_poll_type;
    import cosim_bridge_pkg::bridge_vcs_get_poll_addr;
    import cosim_bridge_pkg::bridge_vcs_get_poll_len;
    import cosim_bridge_pkg::bridge_vcs_get_poll_tag;
    import cosim_bridge_pkg::bridge_vcs_get_poll_data;
    import cosim_bridge_pkg::bridge_vcs_set_cpl_data;
    import cosim_bridge_pkg::bridge_vcs_send_cpl_scalar;
`ifdef COSIM_VIP_MODE
    import cosim_bridge_pkg::bridge_vcs_poll_tlp_ext;
`endif

    `include "cosim_env_config.sv"
    `include "cosim_rc_driver.sv"
    `include "cosim_test.sv"
    `include "cosim_perf_monitor.sv"

endpackage
