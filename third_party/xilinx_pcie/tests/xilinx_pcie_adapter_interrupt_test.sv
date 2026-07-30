import uvm_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Adapter-mode interrupt test (PG213 cfg_interrupt sideband).
//
// Instantiates the ported xilinx_pcie_interrupt_agent (ACTIVE, EP role) on the
// tb's cfg_bus. The agent's driver both sends the EP-side requests and models
// the local PCIe-IP sent/fail responses, so each handshake completes end-to-end.
// The bound xilinx_pcie_cfg_sva checker validates PG213 timing (handshake window,
// single-cycle sent/msix pulses, msi_int stability, msix data-valid).
//
// Exercises all three modes: MSI (enabled), Legacy INTx, MSI-X (pulse timing).
// Expect UVM_ERROR=0 and no SVA failure. (MSI-X emits a benign "not enabled"
// warning since the IP model enables the configured mode = MSI.)
//=============================================================================
class xilinx_pcie_adapter_interrupt_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_interrupt_test)

  xilinx_pcie_interrupt_agent int_agent;

  function new(string n, uvm_component p); super.new(n, p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "int_agent", "is_active", UVM_ACTIVE);
    int_agent = xilinx_pcie_interrupt_agent::type_id::create("int_agent", this);
    int_agent.role             = XILINX_PCIE_EP;
    int_agent.interrupt_enable = 1'b1;
    int_agent.interrupt_mode   = XILINX_INT_MSI;   // IP model enables MSI
    int_agent.msi_vector_count = 4;                // mmenable -> 4 vectors
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("INT_TEST", "=== adapter interrupt test (PG213) START ===", UVM_LOW)

    // Let the IP model finish its ~10-cycle enable init
    #200ns;

    // --- MSI: two vectors within mmenable range ---
    `uvm_info("INT_TEST", "--- MSI ---", UVM_LOW)
    int_agent.driver.send_msi_interrupt(0);
    int_agent.driver.send_msi_interrupt(2);

    // --- Legacy INTx (INTA) ---
    `uvm_info("INT_TEST", "--- Legacy INTx ---", UVM_LOW)
    int_agent.driver.send_legacy_interrupt(0);

    // --- MSI-X pulse (validates single-cycle pulse + data-known SVA) ---
    `uvm_info("INT_TEST", "--- MSI-X ---", UVM_LOW)
    int_agent.driver.send_msix_interrupt(64'h0000_0000_FEE0_0000, 32'h0000_0001);

    #500ns;
    `uvm_info("INT_TEST", "=== adapter interrupt test END ===", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
