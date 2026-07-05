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
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_``CH``_TUSER_W,0,1,1))::set(          \
      null, "uvm_test_top.env.rc_adapter*.``ch``_agent*", "vif", BUS);                              \
  uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_``CH``_TUSER_W,0,1,1))::set(          \
      null, "uvm_test_top.env.ep_adapter*.``ch``_agent*", "vif", BUS);
`endif
