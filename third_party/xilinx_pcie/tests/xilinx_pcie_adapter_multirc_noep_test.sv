import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Multi-RC, no-EP adapter test (2 independent RC host links, no switch).
//
// BFM plays the host (RC role); the far end of each link is a real EP DUT.
// Exercises the env multi-agent path: cfg.num_rc=2 with ep_agent_enable=0 and
// switch_enable=0 builds env.rc_agents[0..1] + env.rc_adapter_0/1, each a fully
// independent Xilinx interface adapter whose RC-role pins mirror a real device's
// own pins (same-name wiring, no descriptor translation).
//
// With no EP and no DUT (tb_adapter_multirc_top leaves the buses open) there is
// no tready source, so the active RC must not drive — this is a build/connect/
// elaborate + clean-idle probe, analogous to xilinx_pcie_adapter_no_rc_test but
// with two RC host links. Real traffic runs once each link's DUT (or a loopback)
// provides tready; drive it on env.rc_agents[i].sequencer.
//=============================================================================
class xilinx_pcie_adapter_multirc_noep_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_multirc_noep_test)

  localparam int NUM_RC = 2;

  pcie_tl_env        env;
  pcie_tl_env_config cfg;

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    pcie_tl_if_adapter::type_id::set_type_override(
        xilinx_pcie_if_adapter::get_type());

    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.if_mode         = SV_IF_MODE;   // disable env TLM loopback
    cfg.rc_agent_enable = 1;
    cfg.ep_agent_enable = 0;            // NO EP
    cfg.num_rc          = NUM_RC;       // 2 independent RC host links (non-switch)
    cfg.num_ep          = 0;
    cfg.switch_enable   = 0;
    cfg.infinite_credit = 1;
    cfg.scb_enable      = 0;
    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

    env = pcie_tl_env::type_id::create("env", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if (env.rc_agents.size() != NUM_RC)
      `uvm_error("MULTI_RC", $sformatf(
          "expected %0d RC agents, got %0d", NUM_RC, env.rc_agents.size()))

    foreach (env.rc_agents[i]) begin
      if (env.rc_agents[i] != null)
        `uvm_info("MULTI_RC", $sformatf(
            "RC[%0d] host link up (adapter=rc_adapter_%0d)", i, i), UVM_LOW)
    end

    if (env.ep_agent == null)
      `uvm_info("MULTI_RC", "env.ep_agent is null as expected (ep_agent_enable=0)", UVM_LOW)
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("MULTI_RC", $sformatf(
        "%0d independent RC host links up; idling (no DUT tready source)",
        NUM_RC), UVM_LOW)
    #500ns;
    phase.drop_objection(this);
  endtask
endclass
