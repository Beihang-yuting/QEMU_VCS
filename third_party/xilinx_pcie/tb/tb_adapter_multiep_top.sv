//=============================================================================
// Adapter-mode multi-EP testbench (2 EP, NO RC, no switch).
//
// Each EP is an INDEPENDENT link: its own 4 PG213 AXI-Stream channels
// (RQ/RC/CQ/CC), wired only to that EP's adapter — never shared with another
// agent. In a real bring-up the far end of each bus set connects to the DUT's
// per-link hard-IP AXIS ports. Here (no DUT) the buses are left open: the EP
// slave channels (CQ/RC) simply idle, exercising build/connect/elaborate of
// env cfg.num_ep=2 with rc_agent_enable=0.
//=============================================================================
`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_adapter_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;

module tb_adapter_multiep_top;

  // Clock / reset (250 MHz, active-low), gated on the adapter quiescence flag.
  logic clk;
  logic rst_n;
  initial clk = 1'b0;
  always #2ns if (!xilinx_pcie_adapter_pkg::g_xilinx_adapter_quiesce) clk = ~clk;
  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    @(posedge clk);
    rst_n = 1'b1;
  end

  // EP0 independent link (4 channels)
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1,`XILINX_KEEP_W) ep0_rq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1,`XILINX_KEEP_W) ep0_rc(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1,`XILINX_KEEP_W) ep0_cq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1,`XILINX_KEEP_W) ep0_cc(.aclk(clk), .aresetn(rst_n));

  // EP1 independent link (4 channels)
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1,`XILINX_KEEP_W) ep1_rq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1,`XILINX_KEEP_W) ep1_rc(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1,`XILINX_KEEP_W) ep1_cq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1,`XILINX_KEEP_W) ep1_cc(.aclk(clk), .aresetn(rst_n));

  initial begin
    `XILINX_ADAPTER_WIRE_EP(0, ep0_rq, ep0_rc, ep0_cq, ep0_cc)
    `XILINX_ADAPTER_WIRE_EP(1, ep1_rq, ep1_rc, ep1_cq, ep1_cc)
    run_test();
  end

  // simulation timeout guard
  initial begin
    #200us;
    $display("[tb_adapter_multiep_top] simulation timeout guard (200us) reached");
    $finish(2);
  end

endmodule : tb_adapter_multiep_top
