//=============================================================================
// Adapter-mode multi-RC testbench (2 RC host links, NO EP, no switch).
//
// BFM plays the host (RC role); the far end of each link is a real EP DUT.
// Each RC is an INDEPENDENT link: its own 4 PG213 AXI-Stream channels
// (RQ/RC/CQ/CC), wired only to that RC's adapter. Same-name wiring to a real
// device (RQ->RQ, RC->RC, CQ->CQ, CC->CC) needs NO descriptor translation,
// because the RC-role pins mirror a real device's own pins (opposite direction,
// matching format).
//
// In a real bring-up the far end of each bus set connects to that DUT's AXIS
// ports. Here (no DUT) the buses are left open: there is no tready source, so
// the active RC MUST NOT drive traffic — this tb exercises build/connect/
// elaborate of env cfg.num_rc=2 with ep_agent_enable=0 and clean idle only.
//=============================================================================
`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_adapter_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;

module tb_adapter_multirc_top;

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

  // RC0 independent host link (4 channels)
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1,`XILINX_KEEP_W) rc0_rq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1,`XILINX_KEEP_W) rc0_rc(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1,`XILINX_KEEP_W) rc0_cq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1,`XILINX_KEEP_W) rc0_cc(.aclk(clk), .aresetn(rst_n));

  // RC1 independent host link (4 channels)
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1,`XILINX_KEEP_W) rc1_rq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1,`XILINX_KEEP_W) rc1_rc(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1,`XILINX_KEEP_W) rc1_cq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1,`XILINX_KEEP_W) rc1_cc(.aclk(clk), .aresetn(rst_n));

  initial begin
    `XILINX_ADAPTER_WIRE_RC(0, rc0_rq, rc0_rc, rc0_cq, rc0_cc)
    `XILINX_ADAPTER_WIRE_RC(1, rc1_rq, rc1_rc, rc1_cq, rc1_cc)
    run_test();
  end

  // simulation timeout guard
  initial begin
    #200us;
    $display("[tb_adapter_multirc_top] simulation timeout guard (200us) reached");
    $finish(2);
  end

endmodule : tb_adapter_multirc_top
