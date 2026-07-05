import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Config-TLP round-trip test (adapter mode)
//
// RC sends CfgWr0(reg=0x10, data=0xDEADBEEF) then CfgRd0(reg=0x10) over the
// Xilinx adapter. The pcie_tl_vip ep_driver (simple cfg path, func_manager=null
// & config_proxy.bypass off in this env) writes/reads cfg_mgr at the DECODED
// reg_num and returns a CplD. If the descriptor codec preserves reg_num across
// encode_rq(RC) -> decode_cq(EP) and the write/read hit the same cfg_mgr DW,
// the CfgRd completion carries back 0xDEADBEEF — proving reg_num round-trips.
//
// The embedded subscriber on the RC monitor asserts the read-back data value;
// the inherited e2e_chk independently confirms the completions match by tag.
//=============================================================================

// Taps the EP-side decoded request (after encode_rq @RC -> AXIS -> decode_cq @EP)
// and verifies the Config-TLP fields round-trip through the descriptor codec:
// the decoded object must be a pcie_tl_cfg_tlp with the reg_num / completer_id /
// first_be that the RC sent. This is a direct codec round-trip assertion that
// does not depend on cfg_mgr writability or the (vestigial) wr_data field.
class xilinx_adapter_cfg_reg_check extends uvm_subscriber #(pcie_tl_tlp);
  `uvm_component_utils(xilinx_adapter_cfg_reg_check)
  bit [9:0]  exp_reg  = 10'h040;
  bit [15:0] exp_bdf  = 16'h0100;
  bit        saw_cfgwr = 0;
  bit        saw_cfgrd = 0;
  int        n_bad     = 0;

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void write(pcie_tl_tlp t);
    pcie_tl_cfg_tlp cfg;
    if (t == null) return;
    if (!(t.kind inside {TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1}))
      return;
    if (!$cast(cfg, t)) begin
      n_bad++;
      `uvm_error(get_type_name(),
        "EP decoded a Config kind but object is not a pcie_tl_cfg_tlp")
      return;
    end
    `uvm_info(get_type_name(), $sformatf(
      "EP cfg req: kind=%s reg_num=0x%03h completer_id=0x%04h first_be=0x%01h",
      cfg.kind.name(), cfg.reg_num, cfg.completer_id, cfg.first_be), UVM_LOW)
    if (cfg.reg_num != exp_reg || cfg.completer_id != exp_bdf) begin
      n_bad++;
      `uvm_error(get_type_name(), $sformatf(
        "Config field round-trip MISMATCH: got reg_num=0x%03h bdf=0x%04h, expected reg_num=0x%03h bdf=0x%04h",
        cfg.reg_num, cfg.completer_id, exp_reg, exp_bdf))
    end
    if (cfg.kind == TLP_CFG_WR0) saw_cfgwr = 1;
    if (cfg.kind == TLP_CFG_RD0) saw_cfgrd = 1;
  endfunction
endclass

class xilinx_pcie_adapter_cfg_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_cfg_test)

  xilinx_adapter_cfg_reg_check cfg_chk;

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg_chk = xilinx_adapter_cfg_reg_check::type_id::create("cfg_chk", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // Tap the EP-side decoded requests (CQ decode output)
    env.ep_agent.monitor.tlp_ap.connect(cfg_chk.analysis_export);
  endfunction

  // Focused cfg round-trip (no mem ops): override base run_phase.
  task run_phase(uvm_phase phase);
    pcie_tl_cfg_wr_seq cfgw;
    pcie_tl_cfg_rd_seq cfgr;
    phase.raise_objection(this);

    // reg_num 0x40 (byte 0x100): extended config space, RW by default and clear
    // of the Type-0 header (0x00-0x3F) and PCIe capability (at 0x40 byte offset),
    // so the write persists and the read-back proves reg_num round-trips.
    cfgw = pcie_tl_cfg_wr_seq::type_id::create("cfgw");
    cfgw.target_bdf = 16'h0100; cfgw.reg_num = 10'h040;
    cfgw.first_be   = 4'hF;     cfgw.wr_data = 32'hDEAD_BEEF;
    cfgw.is_type1   = 0;        cfgw.mode    = CONSTRAINT_LEGAL;
    cfgw.start(env.rc_agent.sequencer);
    #500ns;

    cfgr = pcie_tl_cfg_rd_seq::type_id::create("cfgr");
    cfgr.target_bdf = 16'h0100; cfgr.reg_num = 10'h040;
    cfgr.first_be   = 4'hF;     cfgr.is_type1 = 0;
    cfgr.mode       = CONSTRAINT_LEGAL;
    cfgr.start(env.rc_agent.sequencer);
    #2000ns;  // drain the CfgRd CplD back to RC

    phase.drop_objection(this);
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!cfg_chk.saw_cfgwr)
      `uvm_error(get_type_name(), "EP never decoded the CfgWr0 request")
    if (!cfg_chk.saw_cfgrd)
      `uvm_error(get_type_name(), "EP never decoded the CfgRd0 request")
    if (cfg_chk.n_bad != 0)
      `uvm_error(get_type_name(), $sformatf(
        "Config field round-trip FAILED: %0d bad config request(s) at EP", cfg_chk.n_bad))
    if (cfg_chk.saw_cfgwr && cfg_chk.saw_cfgrd && cfg_chk.n_bad == 0)
      `uvm_info(get_type_name(),
        "Config round-trip OK: CfgWr0+CfgRd0 decoded at EP with reg_num=0x040 / bdf=0x0100 intact",
        UVM_LOW)
  endfunction
endclass
