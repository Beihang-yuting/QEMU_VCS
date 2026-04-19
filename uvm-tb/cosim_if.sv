// cosim_if.sv — TLP-level interface between UVM driver and DUT
`timescale 1ns/1ps

interface cosim_if (input logic clk, input logic rst_n);

    // Host -> EP (request)
    logic        tlp_valid;
    logic [2:0]  tlp_type;
    logic [63:0] tlp_addr;
    logic [31:0] tlp_wdata;
    logic [15:0] tlp_len;
    logic [7:0]  tlp_tag;

    // EP -> Host (completion)
    logic        cpl_valid;
    logic [7:0]  cpl_tag;
    logic [31:0] cpl_rdata;
    logic        cpl_status;

    // EP -> Host (auxiliary)
    logic        notify_valid;
    logic [15:0] notify_queue;
    logic        isr_set;

    // Driver clocking block
    clocking drv_cb @(posedge clk);
        default input #1 output #1;
        output tlp_valid, tlp_type, tlp_addr, tlp_wdata, tlp_len, tlp_tag;
        input  cpl_valid, cpl_tag, cpl_rdata, cpl_status;
        input  notify_valid, notify_queue;
        output isr_set;
    endclocking

    // Monitor clocking block
    clocking mon_cb @(posedge clk);
        default input #1;
        input tlp_valid, tlp_type, tlp_addr, tlp_wdata, tlp_len, tlp_tag;
        input cpl_valid, cpl_tag, cpl_rdata, cpl_status;
        input notify_valid, notify_queue;
        input isr_set;
    endclocking

    modport driver  (clocking drv_cb, input clk, rst_n);
    modport monitor (clocking mon_cb, input clk, rst_n);

endinterface
