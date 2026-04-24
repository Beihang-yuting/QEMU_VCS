//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Top-level Package
//-----------------------------------------------------------------------------

package pcie_tl_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    //--- Types ---
    `include "types/pcie_tl_types.sv"
    `include "types/pcie_tl_prefix.sv"
    `include "types/pcie_tl_tlp.sv"

    //--- Shared Components ---
    `include "shared/pcie_tl_codec.sv"
    `include "shared/pcie_tl_fc_manager.sv"
    `include "shared/pcie_tl_bw_shaper.sv"
    `include "shared/pcie_tl_tag_manager.sv"
    `include "shared/pcie_tl_ordering_engine.sv"
    `include "shared/pcie_tl_cfg_space_manager.sv"
    `include "shared/pcie_tl_link_delay_model.sv"
    `include "shared/pcie_tl_sriov_cap.sv"
    `include "shared/pcie_tl_func_manager.sv"

    //--- Adapter ---
    `include "adapter/pcie_tl_if_adapter.sv"

    //--- Switch ---
    `include "switch/pcie_tl_switch_config.sv"
    `include "switch/pcie_tl_switch_port.sv"
    `include "switch/pcie_tl_switch_fabric.sv"
    `include "switch/pcie_tl_switch.sv"

    //--- Agent ---
    `include "agent/pcie_tl_base_driver.sv"
    `include "agent/pcie_tl_base_monitor.sv"
    `include "agent/pcie_tl_base_agent.sv"
    `include "agent/pcie_tl_rc_driver.sv"
    `include "agent/pcie_tl_rc_agent.sv"
    `include "agent/pcie_tl_ep_driver.sv"
    `include "agent/pcie_tl_ep_agent.sv"

    //--- Env ---
    `include "env/pcie_tl_env_config.sv"
    `include "env/pcie_tl_virtual_sequencer.sv"
    `include "env/pcie_tl_scoreboard.sv"
    `include "env/pcie_tl_coverage_collector.sv"
    `include "env/pcie_tl_env.sv"

    //--- Sequences: Base ---
    `include "seq/base/pcie_tl_mem_rd_seq.sv"
    `include "seq/base/pcie_tl_mem_wr_seq.sv"
    `include "seq/base/pcie_tl_io_rd_seq.sv"
    `include "seq/base/pcie_tl_io_wr_seq.sv"
    `include "seq/base/pcie_tl_cfg_rd_seq.sv"
    `include "seq/base/pcie_tl_cfg_wr_seq.sv"
    `include "seq/base/pcie_tl_cpl_seq.sv"
    `include "seq/base/pcie_tl_msg_seq.sv"
    `include "seq/base/pcie_tl_atomic_seq.sv"
    `include "seq/base/pcie_tl_vendor_msg_seq.sv"
    `include "seq/base/pcie_tl_ltr_seq.sv"

    //--- Sequences: Constraints ---
    `include "seq/constraints/pcie_tl_legal_constraints.sv"
    `include "seq/constraints/pcie_tl_illegal_constraints.sv"
    `include "seq/constraints/pcie_tl_corner_constraints.sv"

    //--- Sequences: Scenario ---
    `include "seq/scenario/pcie_tl_bar_enum_seq.sv"
    `include "seq/scenario/pcie_tl_dma_rdwr_seq.sv"
    `include "seq/scenario/pcie_tl_msi_seq.sv"
    `include "seq/scenario/pcie_tl_cpl_timeout_seq.sv"
    `include "seq/scenario/pcie_tl_err_malformed_seq.sv"
    `include "seq/scenario/pcie_tl_err_poisoned_seq.sv"
    `include "seq/scenario/pcie_tl_err_unexpected_cpl_seq.sv"
    `include "seq/scenario/pcie_tl_err_tag_conflict_seq.sv"

    //--- Sequences: Virtual ---
    `include "seq/virtual/pcie_tl_base_vseq.sv"
    `include "seq/virtual/pcie_tl_rc_ep_rdwr_vseq.sv"
    `include "seq/virtual/pcie_tl_enum_then_dma_vseq.sv"
    `include "seq/virtual/pcie_tl_backpressure_vseq.sv"

endpackage : pcie_tl_pkg
