import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// err_poisoned scenario over the Xilinx adapter (OBSERVATION ONLY)
//
// Runs pcie_tl_err_poisoned_seq on env.rc_agent.sequencer: a poisoned (EP=1)
// Mem Wr TLP is injected RC -> AXIS -> EP. The Xilinx adapter performs NO
// protocol judgment; the error is expected to surface (if at all) via the
// upstream pcie_tl_base_monitor checks that run on receive()'d TLPs at the EP
// monitor.
//
// This test is DIAGNOSTIC: it does NOT assert a pass verdict. It exists to
// document how an injected protocol error propagates through the adapter stack.
// The poisoned write is posted, so the e2e checker tracks no outstanding
// completion. Inspect the run log for the EP monitor's reaction.
//=============================================================================
class xilinx_pcie_adapter_err_poisoned_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_err_poisoned_test)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  task run_phase(uvm_phase phase);
    pcie_tl_err_poisoned_seq seq;
    phase.raise_objection(this);

    seq = pcie_tl_err_poisoned_seq::type_id::create("err_poisoned_seq");
    seq.start(env.rc_agent.sequencer);

    #5000ns;  // let the poisoned TLP reach the EP monitor
    phase.drop_objection(this);
  endtask
endclass
