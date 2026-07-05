import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Variant A robustness probe: no-RC, single EP (switch disabled).
//
// rc_agent_enable=0 -> env.rc_agents[] stays empty (env connect_phase guards
// the no-RC case). The EP adapter + ep_agent are built and auto-response is
// wired, but in SV_IF_MODE there is NO traffic source without an RC, so this
// test must simply build/connect/elaborate cleanly and idle to a clean $finish.
// It does NOT start any sequence. The deliverable is the observed behavior.
//=============================================================================
class xilinx_pcie_adapter_no_rc_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_no_rc_test)

  pcie_tl_env                  env;
  pcie_tl_env_config           cfg;
  xilinx_adapter_poc_responder ep_resp;   // EP auto-response glue (-> ep_driver)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    pcie_tl_if_adapter::type_id::set_type_override(
        xilinx_pcie_if_adapter::get_type());

    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.if_mode         = SV_IF_MODE;   // disable env TLM loopback
    cfg.rc_agent_enable = 0;            // NO RC
    cfg.ep_agent_enable = 1;
    cfg.switch_enable   = 0;
    cfg.ep_auto_response= 1;
    cfg.infinite_credit = 1;
    cfg.scb_enable      = 0;
    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

    env     = pcie_tl_env::type_id::create("env", this);
    ep_resp = xilinx_adapter_poc_responder::type_id::create("ep_resp", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // EP side must still wire cleanly with no RC present.
    if (env.ep_agent != null) begin
      ep_resp.ep_drv = env.ep_agent.ep_driver;
      env.ep_agent.monitor.tlp_ap.connect(ep_resp.analysis_export);
    end
    if (env.rc_agent == null)
      `uvm_info("NO_RC", "env.rc_agent is null as expected (rc_agent_enable=0)", UVM_LOW)
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("NO_RC", "no-RC env up; idling (no traffic source without RC)", UVM_LOW)
    #500ns;   // brief idle, then drain
    phase.drop_objection(this);
  endtask
endclass
