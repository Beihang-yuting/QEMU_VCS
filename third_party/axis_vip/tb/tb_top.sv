`timescale 1ns/1ps

`include "axis_params.svh"

module tb_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import axis_pkg::*;

    logic aclk;
    logic aresetn;

    initial aclk = 0;
    always #5 aclk = ~aclk;

    initial begin
        aresetn = 1'b0;
        repeat (10) @(posedge aclk);
        aresetn = 1'b1;
    end

    axis_if #(32,4,4,1,0,1,1) master_if (.aclk(aclk), .aresetn(aresetn));
    axis_if #(32,4,4,1,0,1,1) slave_if  (.aclk(aclk), .aresetn(aresetn));

    axis_dummy_dut #(
        .TDATA_WIDTH (32),
        .TID_WIDTH   (4),
        .TDEST_WIDTH (4),
        .TUSER_WIDTH (1)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_tvalid(master_if.tvalid),
        .s_tready(master_if.tready),
        .s_tdata(master_if.tdata),
        .s_tstrb(master_if.tstrb),
        .s_tkeep(master_if.tkeep),
        .s_tlast(master_if.tlast),
        .s_tid(master_if.tid),
        .s_tdest(master_if.tdest),
        .s_tuser(master_if.tuser),
        .m_tvalid(slave_if.tvalid),
        .m_tready(slave_if.tready),
        .m_tdata(slave_if.tdata),
        .m_tstrb(slave_if.tstrb),
        .m_tkeep(slave_if.tkeep),
        .m_tlast(slave_if.tlast),
        .m_tid(slave_if.tid),
        .m_tdest(slave_if.tdest),
        .m_tuser(slave_if.tuser)
    );

    // Protocol checker SVA bindings
    axis_protocol_checker_sva master_proto_chk (
        .aif(master_if)
    );

    initial begin
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.master_agent*", "vif", master_if);
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.slave_agent*",  "vif", slave_if);
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.rst_handler",   "vif", master_if);
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.proto_checker", "vif", master_if);
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.bw_checker",    "vif", master_if);
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.phase_ctrl",    "vif", master_if);
        uvm_config_db#(axis_vif_default_t)::set(null, "uvm_test_top.env.cov",           "vif", master_if);
    end

    initial begin
        run_test();
    end

    initial begin
        #1000000;
        `uvm_fatal("TIMEOUT", "Simulation timed out")
    end

endmodule
