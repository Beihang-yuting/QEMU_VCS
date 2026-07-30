import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Adapter-mode read-back demo for pcie_tl_rw_seq.
//
// Over the Xilinx AXI-Stream adapter (SV_IF_MODE): RC writes a known pattern to
// an EP address, then RC issues a pcie_tl_rw_seq READ. The read waits for the
// CplD (returned by ep_driver over the CC->RC AXIS path, delivered to
// rc_driver.handle_completion by the base test's poc_responder) and exposes the
// actual bytes in rd.rdata. We assert rd.rdata == the written pattern.
//=============================================================================
class xilinx_pcie_adapter_rw_readback_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_rw_readback_test)

  function new(string n, uvm_component p); super.new(n, p); endfunction

  task run_phase(uvm_phase phase);
    pcie_tl_rw_seq wr, rd;
    bit [63:0] a = 64'h0000_0001_0000_0000;
    int sz = 16;
    byte golden[];
    bit ok = 1'b1;
    phase.raise_objection(this);

    golden = new[sz];
    foreach (golden[i]) golden[i] = byte'((8'hA0 + i) & 8'hFF);

    // WRITE known pattern (posted, fire-and-forget)
    wr = pcie_tl_rw_seq::type_id::create("wr");
    wr.op = PCIE_RW_WRITE; wr.addr = a; wr.byte_len = sz;
    wr.wdata = new[sz];
    foreach (wr.wdata[i]) wr.wdata[i] = golden[i];
    wr.start(env.rc_agent.sequencer);
    #500ns;

    // READ back over AXIS: waits for CplD, fills rd.rdata
    rd = pcie_tl_rw_seq::type_id::create("rd");
    rd.op = PCIE_RW_READ; rd.addr = a; rd.byte_len = sz;
    rd.start(env.rc_agent.sequencer);

    `uvm_info("ARB", $sformatf("READ status=%s rdata.size=%0d", rd.status.name(), rd.rdata.size()), UVM_LOW)
    if (rd.status != PCIE_RW_OK)
      `uvm_error("ARB", $sformatf("READ status not OK: %s", rd.status.name()))
    else if (rd.rdata.size() < sz)
      `uvm_error("ARB", $sformatf("rdata.size=%0d < %0d", rd.rdata.size(), sz))
    else begin
      for (int i = 0; i < sz; i++)
        if (rd.rdata[i] !== golden[i]) begin
          `uvm_error("ARB", $sformatf("byte[%0d] exp=0x%02h got=0x%02h", i, golden[i], rd.rdata[i]))
          ok = 1'b0; break;
        end
      if (ok) `uvm_info("ARB", $sformatf("adapter read-back MATCH (%0d bytes) via AXIS", sz), UVM_LOW)
    end

    #2000ns;
    phase.drop_objection(this);
  endtask
endclass
