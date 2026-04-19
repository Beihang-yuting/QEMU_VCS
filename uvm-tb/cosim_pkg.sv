// cosim_pkg.sv — Package that includes all UVM components
package cosim_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import cosim_bridge_pkg::*;

    `include "cosim_tlp_transaction.sv"
    `include "cosim_driver.sv"
    `include "cosim_monitor.sv"
    `include "cosim_sequences.sv"
    `include "cosim_scoreboard.sv"
    `include "cosim_agent.sv"
    `include "cosim_env.sv"
    `include "cosim_test.sv"
endpackage
