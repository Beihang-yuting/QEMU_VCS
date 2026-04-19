// tb_uvm_top.sv — UVM testbench top module
// Standalone mode: uses pcie_ep_stub as DUT, UVM sequences drive TLPs

`timescale 1ns/1ps

module tb_uvm_top;
    import uvm_pkg::*;
    import cosim_pkg::*;

    // Clock and reset
    logic clk;
    logic rst_n;

    // Clock generation: 10ns period (100MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    // Reset sequence
    initial begin
        rst_n = 0;
        #50;
        rst_n = 1;
    end

    // Interface instance
    cosim_if cif(.clk(clk), .rst_n(rst_n));

    // DUT: PCIe EP stub
    pcie_ep_stub dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .tlp_valid    (cif.tlp_valid),
        .tlp_type     (cif.tlp_type),
        .tlp_addr     (cif.tlp_addr),
        .tlp_wdata    (cif.tlp_wdata),
        .tlp_len      (cif.tlp_len),
        .tlp_tag      (cif.tlp_tag),
        .cpl_valid    (cif.cpl_valid),
        .cpl_tag      (cif.cpl_tag),
        .cpl_rdata    (cif.cpl_rdata),
        .cpl_status   (cif.cpl_status),
        .notify_valid (cif.notify_valid),
        .notify_queue (cif.notify_queue),
        .isr_set      (cif.isr_set)
    );

    // Initialize interface outputs to avoid X
    initial begin
        cif.tlp_valid = 0;
        cif.tlp_type  = 0;
        cif.tlp_addr  = 0;
        cif.tlp_wdata = 0;
        cif.tlp_len   = 0;
        cif.tlp_tag   = 0;
        cif.isr_set   = 0;
    end

    // Register virtual interface in config_db and run UVM
    initial begin
        uvm_config_db#(virtual cosim_if)::set(null, "uvm_test_top.env.agt*", "vif", cif);
        run_test();
    end

    // Timeout watchdog
    initial begin
        #1_000_000;
        `uvm_fatal("TB", "Simulation timeout after 1ms")
    end

    // VCD dump (optional, controlled by +DUMP_VCD)
    initial begin
        if ($test$plusargs("DUMP_VCD")) begin
            $dumpfile("cosim_uvm.vcd");
            $dumpvars(0, tb_uvm_top);
        end
    end
endmodule
