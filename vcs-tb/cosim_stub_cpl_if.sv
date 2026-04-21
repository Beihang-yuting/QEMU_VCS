/* cosim-platform/vcs-tb/cosim_stub_cpl_if.sv
 * Simple interface carrying stub completion signals so that cosim_rc_driver
 * can monitor them directly (bypassing the unidirectional pcie_tl_if).
 */

`timescale 1ns/1ps

interface cosim_stub_cpl_if(input logic clk, input logic rst_n);
    logic        cpl_valid;
    logic [7:0]  cpl_tag;
    logic [31:0] cpl_rdata;
    logic        cpl_status;  // 0 = SC, 1 = UR

    modport monitor (
        input clk, rst_n,
        input cpl_valid, cpl_tag, cpl_rdata, cpl_status
    );
endinterface
