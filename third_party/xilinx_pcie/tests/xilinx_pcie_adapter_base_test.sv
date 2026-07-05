import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Adapter-mode PoC responder
//
// In SV_IF_MODE the upstream pcie_tl_env's TLM loopback (which normally drives
// EP auto-response and RC completion handling) is disabled. We re-create those
// two hooks by subscribing to the agents' monitor.tlp_ap:
//   - EP instance: incoming requests -> ep_driver.handle_request (sends CplD
//     back over AXIS via adapter.send).
//   - RC instance: incoming completions -> rc_driver.handle_completion (clears
//     the outstanding tag so start_cpl_timeout does not fire UVM_ERROR).
//=============================================================================
class xilinx_adapter_poc_responder extends uvm_subscriber #(pcie_tl_tlp);
  `uvm_component_utils(xilinx_adapter_poc_responder)

  pcie_tl_ep_driver ep_drv;   // set on the EP instance
  pcie_tl_rc_driver rc_drv;   // set on the RC instance
  pcie_tl_tlp       req_q[$]; // EP request backlog (handle_request is a task)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void write(pcie_tl_tlp t);
    if (t == null) return;
    if (t.get_category() == TLP_CAT_COMPLETION) begin
      if (rc_drv != null) begin
        pcie_tl_cpl_tlp c;
        if ($cast(c, t)) void'(rc_drv.handle_completion(c));
      end
    end else begin
      if (ep_drv != null) req_q.push_back(t);
    end
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      pcie_tl_tlp t;
      wait (req_q.size() > 0);
      t = req_q.pop_front();
      ep_drv.handle_request(t);
    end
  endtask
endclass

//=============================================================================
// Adapter-mode PoC base test (1RC + 1EP, enum_then_dma over the Xilinx adapter)
//=============================================================================
class xilinx_pcie_adapter_base_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_base_test)

  pcie_tl_env                  env;
  pcie_tl_env_config           cfg;
  xilinx_adapter_poc_responder ep_resp;     // EP auto-response glue (-> ep_driver)
  xilinx_pcie_e2e_checker      e2e_chk;     // end-to-end req/cpl match checker

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Install the Xilinx interface adapter in place of the upstream base adapter
    pcie_tl_if_adapter::type_id::set_type_override(
        xilinx_pcie_if_adapter::get_type());

    // Env config: SV interface mode (TLM loopback off), 1RC+1EP, no switch
    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.if_mode         = SV_IF_MODE;   // disable env TLM loopback
    cfg.rc_agent_enable = 1;
    cfg.ep_agent_enable = 1;
    cfg.switch_enable   = 0;
    cfg.ep_auto_response= 1;
    cfg.infinite_credit = 1;            // no FC replenish path in SV_IF mode
    // Scoreboard's completion match relies on register_pending(), which only
    // runs in the env's TLM loopback (off in SV_IF mode). Disable it for the
    // PoC; completion delivery is verified by rc_driver.handle_completion.
    cfg.scb_enable      = 0;
    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

    env     = pcie_tl_env::type_id::create("env", this);
    ep_resp = xilinx_adapter_poc_responder::type_id::create("ep_resp", this);
    e2e_chk = xilinx_pcie_e2e_checker::type_id::create("e2e_chk", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // EP auto-response: requests arriving at EP -> ep_driver.handle_request
    ep_resp.ep_drv = env.ep_agent.ep_driver;
    env.ep_agent.monitor.tlp_ap.connect(ep_resp.analysis_export);
    // End-to-end checker: requests tapped on the completer (EP) side, completions
    // tapped on the requester (RC) side, matched by tag. Replaces the old
    // rc_resp/rc_driver.handle_completion ad-hoc completion-match path.
    env.ep_agent.monitor.tlp_ap.connect(e2e_chk.req_imp);
    env.rc_agent.monitor.tlp_ap.connect(e2e_chk.cpl_imp);
  endfunction

  task run_phase(uvm_phase phase);
    pcie_tl_mem_wr_seq wr;
    pcie_tl_mem_rd_seq rd;
    phase.raise_objection(this);

    // PoC GATE: RC request -> AXIS -> EP auto-responds -> completion back to RC.
    // Uses memory TLPs (fully supported by the Xilinx descriptor codec). The
    // Mem Rd exercises the completion-return path (EP -> CplD -> RC).
    wr = pcie_tl_mem_wr_seq::type_id::create("wr");
    wr.addr = 64'h0000_0001_0000_0000; wr.length = 4;
    wr.first_be = 4'hF; wr.last_be = 4'hF; wr.is_64bit = 1;
    wr.start(env.rc_agent.sequencer);
    #200ns;

    rd = pcie_tl_mem_rd_seq::type_id::create("rd");
    rd.addr = 64'h0000_0001_0000_0000; rd.length = 4;
    rd.first_be = 4'hF; rd.last_be = 4'hF; rd.is_64bit = 1;
    rd.start(env.rc_agent.sequencer);
    #2000ns;  // drain the CplD back to RC

    phase.drop_objection(this);
  endtask
endclass
