import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Multi-EP, no-RC adapter test (2 independent EP links, no switch).
//
// Exercises the env multi-agent path: cfg.num_ep=2 with rc_agent_enable=0 and
// switch_enable=0 builds env.ep_agents[0..1] + env.ep_adapter_0/1, each a fully
// independent Xilinx interface adapter. Per EP, the auto-response glue is wired
// so a DUT-driven request on that link is answered on the SAME link.
//
// With no RC and no DUT (tb_adapter_multiep_top leaves the buses open) there is
// no traffic source, so this is a build/connect/elaborate + clean-idle probe,
// analogous to xilinx_pcie_adapter_no_rc_test but with two EPs. Reuses
// xilinx_adapter_poc_responder defined in xilinx_pcie_adapter_base_test.sv.
//=============================================================================
class xilinx_pcie_adapter_multiep_norc_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_multiep_norc_test)

  localparam int NUM_EP = 2;

  pcie_tl_env                  env;
  pcie_tl_env_config           cfg;
  xilinx_adapter_poc_responder ep_resp[NUM_EP];   // one auto-response glue per EP

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    pcie_tl_if_adapter::type_id::set_type_override(
        xilinx_pcie_if_adapter::get_type());

    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.if_mode         = SV_IF_MODE;   // disable env TLM loopback
    cfg.rc_agent_enable = 0;            // NO RC
    cfg.ep_agent_enable = 1;
    cfg.num_ep          = NUM_EP;       // 2 independent EP links (non-switch)
    cfg.switch_enable   = 0;
    cfg.ep_auto_response= 1;
    cfg.infinite_credit = 1;
    cfg.scb_enable      = 0;
    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

    env = pcie_tl_env::type_id::create("env", this);
    foreach (ep_resp[i])
      ep_resp[i] = xilinx_adapter_poc_responder::type_id::create(
          $sformatf("ep_resp_%0d", i), this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if (env.ep_agents.size() != NUM_EP)
      `uvm_error("MULTI_EP", $sformatf(
          "expected %0d EP agents, got %0d", NUM_EP, env.ep_agents.size()))

    // Per-EP auto-response: each EP answers requests on its own link.
    foreach (env.ep_agents[i]) begin
      if (env.ep_agents[i] != null) begin
        ep_resp[i].ep_drv = env.ep_agents[i].ep_driver;
        env.ep_agents[i].monitor.tlp_ap.connect(ep_resp[i].analysis_export);
        `uvm_info("MULTI_EP", $sformatf(
            "EP[%0d] wired (adapter=ep_adapter_%0d)", i, i), UVM_LOW)
      end
    end

    if (env.rc_agent == null)
      `uvm_info("MULTI_EP", "env.rc_agent is null as expected (rc_agent_enable=0)", UVM_LOW)
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("MULTI_EP", $sformatf(
        "%0d independent EP links up; idling (no traffic source without RC/DUT)",
        NUM_EP), UVM_LOW)
    #500ns;
    phase.drop_objection(this);
  endtask
endclass
