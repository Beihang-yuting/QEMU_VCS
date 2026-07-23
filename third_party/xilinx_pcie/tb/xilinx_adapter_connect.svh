`ifndef XILINX_ADAPTER_CONNECT_SVH
`define XILINX_ADAPTER_CONNECT_SVH
//=============================================================================
// Adapter-mode bus wiring macro.
//
// Each PG213 channel is ONE shared axis_if bus carrying TLPs between the RC and
// EP adapters (one side MASTER, the other SLAVE — set by the adapter's
// make_axis_config). The same vif is registered to BOTH adapters' <ch>_agent.
//
// Usage (in tb initial, after the 4 buses are declared):
//   `XILINX_ADAPTER_WIRE(rq, RQ, rq_bus)
//   `XILINX_ADAPTER_WIRE(rc, RC, rc_bus)
//   `XILINX_ADAPTER_WIRE(cq, CQ, cq_bus)
//   `XILINX_ADAPTER_WIRE(cc, CC, cc_bus)
//=============================================================================
`define XILINX_ADAPTER_WIRE(ch, CH, BUS)                                                            \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_``CH``_TUSER_W,0,1,1,`XILINX_KEEP_W))::set(          \
      null, "uvm_test_top.env.rc_adapter*.``ch``_agent*", "vif", BUS);                              \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_``CH``_TUSER_W,0,1,1,`XILINX_KEEP_W))::set(          \
      null, "uvm_test_top.env.ep_adapter*.``ch``_agent*", "vif", BUS);

//=============================================================================
// Per-adapter indexed bus wiring (multi-agent, non-switch). Wires ONE indexed
// adapter's 4 channels to a dedicated bus set — each agent has its own
// independent link, unshared with any other agent. Use when env cfg.num_rc>1 or
// cfg.num_ep>1 (adapters named rc_adapter_<i> / ep_adapter_<i>).
//
// ROLE is the adapter-name prefix as a string literal ("rc" / "ep"):
//   `XILINX_ADAPTER_WIRE_RC(0, dut0_rq, dut0_rc, dut0_cq, dut0_cc)  // BFM host  -> real EP DUT
//   `XILINX_ADAPTER_WIRE_EP(0, ep0_rq,  ep0_rc,  ep0_cq,  ep0_cc)   // BFM EP    -> real RC/host
//
// Same-name wiring: the far end (real DUT) connects RQ->RQ, RC->RC, CQ->CQ,
// CC->CC. The BFM's per-role make_axis_config sets master/slave so directions
// oppose. No descriptor translation is needed when the BFM faces a real device
// as RC role, because the RC-role pins mirror a real device's own 4 pins.
// (No-DUT sim: the far end is left open; slave channels simply idle, and an
// active RC must not drive — there is no tready source.)
//=============================================================================
`define XILINX_ADAPTER_WIRE_IDX(ROLE, IDX, RQBUS, RCBUS, CQBUS, CCBUS)                              \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1,`XILINX_KEEP_W))::set(              \
      null, $sformatf("uvm_test_top.env.%s_adapter_%0d.rq_agent*", ROLE, IDX), "vif", RQBUS);       \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1,`XILINX_KEEP_W))::set(              \
      null, $sformatf("uvm_test_top.env.%s_adapter_%0d.rc_agent*", ROLE, IDX), "vif", RCBUS);       \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1,`XILINX_KEEP_W))::set(              \
      null, $sformatf("uvm_test_top.env.%s_adapter_%0d.cq_agent*", ROLE, IDX), "vif", CQBUS);       \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1,`XILINX_KEEP_W))::set(              \
      null, $sformatf("uvm_test_top.env.%s_adapter_%0d.cc_agent*", ROLE, IDX), "vif", CCBUS);

`define XILINX_ADAPTER_WIRE_EP(IDX, RQBUS, RCBUS, CQBUS, CCBUS)                                     \
  `XILINX_ADAPTER_WIRE_IDX("ep", IDX, RQBUS, RCBUS, CQBUS, CCBUS)

`define XILINX_ADAPTER_WIRE_RC(IDX, RQBUS, RCBUS, CQBUS, CCBUS)                                     \
  `XILINX_ADAPTER_WIRE_IDX("rc", IDX, RQBUS, RCBUS, CQBUS, CCBUS)
`endif
