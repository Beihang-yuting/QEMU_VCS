module pcie_tl_tb_top;

    import uvm_pkg::*;
    import pcie_tl_pkg::*;
    import host_mem_pkg::*;
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

    // host_mem_manager instances (concrete $unit-scope class; env holds host_mem_api handles)
    host_mem_manager host_inst;
    host_mem_manager dev_inst[16];

    // Set interface + memory instances in config_db
    initial begin
        uvm_config_db#(virtual pcie_tl_if)::set(null, "*", "vif", tl_if);

        // RC host memory
        host_inst = new("host_mem");
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "host_mem", host_inst);

        // Per-EP device memory (upper bound 16 EPs)
        for (int i = 0; i < 16; i++) begin
            dev_inst[i] = new($sformatf("dev_mem_%0d", i));
            uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env",
                                              $sformatf("dev_mem_%0d", i), dev_inst[i]);
        end
    end

    // Run test
    initial begin
        run_test();
    end

endmodule
