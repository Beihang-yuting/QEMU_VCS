`ifndef XILINX_PCIE_ADAPTER_PKG_SV
`define XILINX_PCIE_ADAPTER_PKG_SV
package xilinx_pcie_adapter_pkg;
  import uvm_pkg::*;
  import axis_pkg::*;
  import pcie_tl_pkg::*;
  `include "uvm_macros.svh"
  `include "xilinx_pcie_params.svh"

  // ---- TB quiescence flag ----
  // Cleared(=1) by the adapter's extract_phase once the UVM run_phase has
  // ended; the adapter-mode testbench gates its free-running clock generator on
  // this so no clocked axis driver/monitor threads advance (and flood the log)
  // after simulation work is done. The tb timeout guard is only a backstop.
  bit g_xilinx_adapter_quiesce = 0;

  // ---- Per-channel parameterized axis_agent typedefs (PG213 widths) ----
  typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) axis_agent_rq_t;
  typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) axis_agent_rc_t;
  typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) axis_agent_cq_t;
  typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) axis_agent_cc_t;

  // Xilinx types (enums, tuser-width helper functions) — no env_config dependency
  `include "xilinx_pcie_types.sv"

  // Codecs (descriptor / tuser / straddle) — no env_config dependency
  `include "codec/xilinx_desc_codec.sv"
  `include "codec/xilinx_tuser_codec.sv"
  `include "codec/xilinx_straddle_engine.sv"

  // Channel router (role+category -> AXIS channel)
  `include "agent/xilinx_pcie_channel_router.sv"

  // The interface adapter (wraps 4 axis_agents, absorbs encode/decode)
  `include "adapter/xilinx_pcie_if_adapter.sv"

  // End-to-end TLP checker (req/cpl match) — lives in src/check/ so it survives
  // the Task 6 deletion of src/env/. Resolves via the +incdir+.../src already in
  // filelist_adapter.f (same as the codec/ and adapter/ includes above).
  `include "check/xilinx_pcie_e2e_checker.sv"
endpackage
`endif
