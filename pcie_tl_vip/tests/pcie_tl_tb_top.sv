module pcie_tl_tb_top;

    import uvm_pkg::*;
    import pcie_tl_pkg::*;
    `include "uvm_macros.svh"

    // Clock and reset
    logic clk = 0;
    logic rst_n = 0;

    always #5ns clk = ~clk;  // 100MHz

    initial begin
        rst_n = 0;
        #100ns;
        rst_n = 1;
    end

    // Interface
    pcie_tl_if tl_if(.clk(clk), .rst_n(rst_n));

    // Set interface in config_db
    initial begin
        uvm_config_db#(virtual pcie_tl_if)::set(null, "*", "vif", tl_if);
    end

    // Run test
    initial begin
        run_test();
    end

endmodule
