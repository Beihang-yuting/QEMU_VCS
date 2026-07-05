import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// rc_ep_rdwr scenario over the Xilinx adapter
//
// Runs pcie_tl_rc_ep_rdwr_vseq on env.v_seqr twice: first a posted Mem Wr, then
// a non-posted Mem Rd at the same 64-bit address. Both flow through the Xilinx
// descriptor/tuser codecs and the AXI-Stream path; the EP (pcie_tl_vip
// ep_driver) auto-responds to the read with a CplD. The inherited e2e checker
// matches the read request to its returning completion by tag.
//
// Memory TLPs only -> fully covered by the descriptor codec. Expected:
// UVM_FATAL=0, 1 matched / 0 outstanding / 0 mismatch.
//=============================================================================
class xilinx_pcie_adapter_rdwr_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_rdwr_test)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  task run_phase(uvm_phase phase);
    pcie_tl_rc_ep_rdwr_vseq wr_vseq;
    pcie_tl_rc_ep_rdwr_vseq rd_vseq;
    phase.raise_objection(this);

    wr_vseq = pcie_tl_rc_ep_rdwr_vseq::type_id::create("wr_vseq");
    wr_vseq.addr = 64'h0000_0001_0000_0000; wr_vseq.length = 8; wr_vseq.is_read = 0;
    wr_vseq.start(env.v_seqr);
    #500ns;

    rd_vseq = pcie_tl_rc_ep_rdwr_vseq::type_id::create("rd_vseq");
    rd_vseq.addr = 64'h0000_0001_0000_0000; rd_vseq.length = 8; rd_vseq.is_read = 1;
    rd_vseq.start(env.v_seqr);

    #5000ns;  // drain the CplD back to RC
    phase.drop_objection(this);
  endtask
endclass
