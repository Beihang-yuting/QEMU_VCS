//=============================================================================
// tb_cosim_multirc_top.sv
//
// 2-RC cosim testbench top. BFM plays two independent PCIe hosts (RC role);
// the far end of each link is a real xilinx-pcie EP DUT. Each RC exposes its
// own 4 PG213 AXI-Stream channels (RQ/RC/CQ/CC), same-name-wired to that DUT.
//
// Wire the far ends (rcN_rq/rc/cq/cc) to your DUT's AXIS ports:
//   RC-role adapter drives  CQ (host->DUT req) and RC (host->DUT cpl for DMA)
//   RC-role adapter samples  CC (DUT->host cpl) and RQ (DUT->host DMA req)
//
// Each RC connects to one QEMU on REMOTE_HOST (default 10.11.10.53) over TCP;
// see cosim_xrc_test plusargs (+REMOTE_HOST +PORT_BASE +PORT_STRIDE +NUM_RC).
//=============================================================================
`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_adapter_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
import cosim_bridge_pkg::*;
import cosim_xrc_pkg::*;

module tb_cosim_multirc_top;

  // 250 MHz, active-low reset, gated on the adapter quiescence flag.
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
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rc0_rq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc0_rc(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) rc0_cq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) rc0_cc(.aclk(clk), .aresetn(rst_n));

  // RC1 independent host link (4 channels)
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rc1_rq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc1_rc(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) rc1_cq(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) rc1_cc(.aclk(clk), .aresetn(rst_n));

  initial begin
    `XILINX_ADAPTER_WIRE_RC(0, rc0_rq, rc0_rc, rc0_cq, rc0_cc)
    `XILINX_ADAPTER_WIRE_RC(1, rc1_rq, rc1_rc, rc1_cq, rc1_cc)
    run_test("cosim_xrc_test");
  end

  // Simulation timeout guard (cosim over TCP is slow — generous)
  initial begin
    #50ms;
    $display("[tb_cosim_multirc_top] simulation timeout guard (50ms) reached");
    $finish(2);
  end

endmodule : tb_cosim_multirc_top
