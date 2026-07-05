import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// backpressure scenario over the Xilinx adapter
//
// Runs pcie_tl_backpressure_vseq on env.v_seqr: a burst of posted Mem Wr TLPs
// streamed back-to-back through the Xilinx RQ/CQ AXI-Stream path. With
// infinite_credit=1 (SV_IF mode has no FC replenish loop) this exercises the
// adapter's sustained streaming / EP receive path under load.
//
// Posted writes only -> no completions due, so the e2e checker tracks 0
// outstanding non-posted requests (n_req=0, 0 outstanding/0 mismatch).
// Expected: UVM_FATAL=0, log stays small (quiescence fix holds).
//=============================================================================
class xilinx_pcie_adapter_backpressure_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_backpressure_test)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  task run_phase(uvm_phase phase);
    pcie_tl_backpressure_vseq vseq;
    phase.raise_objection(this);

    vseq = pcie_tl_backpressure_vseq::type_id::create("bp_vseq");
    vseq.burst_count = 16;
    vseq.start(env.v_seqr);

    #5000ns;  // drain
    phase.drop_objection(this);
  endtask
endclass
