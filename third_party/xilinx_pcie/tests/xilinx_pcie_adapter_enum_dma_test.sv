import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// enum_then_dma over the Xilinx adapter
//
// Runs pcie_tl_enum_then_dma_vseq on env.v_seqr: Phase 1 enumerates BARs via
// Config (CfgWr/CfgRd) TLPs, Phase 2 runs a DMA (Mem) burst — all routed
// through the Xilinx descriptor/tuser codecs and the adapter AXI-Stream path.
// The EP (pcie_tl_vip ep_driver) auto-responds; the inherited e2e checker
// matches each non-posted request to its returning completion by tag.
//
// Exercises the new Config-TLP codec support end-to-end alongside the existing
// memory path. Expected: enum + dma complete, UVM_FATAL=0, no e2e errors.
//=============================================================================
class xilinx_pcie_adapter_enum_dma_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_enum_dma_test)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  task run_phase(uvm_phase phase);
    pcie_tl_enum_then_dma_vseq vseq;
    phase.raise_objection(this);

    vseq = pcie_tl_enum_then_dma_vseq::type_id::create("enum_dma_vseq");
    vseq.target_bdf = 16'h0100;
    vseq.dma_addr   = 64'h0000_0001_0000_0000;
    vseq.dma_size   = 512;
    vseq.start(env.v_seqr);

    #5000ns;  // drain remaining completions
    phase.drop_objection(this);
  endtask
endclass
