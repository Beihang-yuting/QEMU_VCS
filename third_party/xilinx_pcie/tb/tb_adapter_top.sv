//=============================================================================
// Adapter-mode PoC testbench (1 RC + 1 EP, no DUT).
//
// 4 shared AXI-Stream buses (one per PG213 channel) carry TLPs between the RC
// and EP Xilinx adapters. Each bus is registered to BOTH adapters' matching
// <ch>_agent; the adapter's make_axis_config selects MASTER vs SLAVE per side.
//=============================================================================
`include "uvm_macros.svh"
`include "xilinx_pcie_params.svh"
`include "xilinx_adapter_connect.svh"
import uvm_pkg::*;
import axis_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;

module tb_adapter_top;

  // Clock / reset (250 MHz, active-low reset)
  // The clock is gated on the adapter quiescence flag so it halts as soon as the
  // UVM run_phase ends (extract_phase sets it), preventing post-verdict clocked
  // axis driver/monitor threads from flooding the log.
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

  // 4 shared channel buses (TUSER width per PG213 channel)
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rq_bus(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc_bus(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) cq_bus(.aclk(clk), .aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) cc_bus(.aclk(clk), .aresetn(rst_n));

  initial begin
    `XILINX_ADAPTER_WIRE(rq, RQ, rq_bus)
    `XILINX_ADAPTER_WIRE(rc, RC, rc_bus)
    `XILINX_ADAPTER_WIRE(cq, CQ, cq_bus)
    `XILINX_ADAPTER_WIRE(cc, CC, cc_bus)
    run_test();
  end

  // simulation timeout guard (bounds the run; the PoC flow completes ~2.3us)
  initial begin
    #200us;
    $display("[tb_adapter_top] simulation timeout guard (200us) reached");
    $finish(2);
  end

endmodule : tb_adapter_top
