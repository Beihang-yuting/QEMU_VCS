class pcie_tl_err_tag_conflict_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_err_tag_conflict_seq)
    function new(string name = "pcie_tl_err_tag_conflict_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_rd_seq rd1, rd2;
        // Send two reads - second will intentionally use a duplicate tag
        rd1 = pcie_tl_mem_rd_seq::type_id::create("rd1");
        rd1.addr = 64'h0000_0001_0000_0000; rd1.length = 1;
        rd1.first_be = 4'hF; rd1.last_be = 4'h0;
        rd1.start(m_sequencer);
        // Second read should trigger tag conflict if tag mgr injects duplicate
        rd2 = pcie_tl_mem_rd_seq::type_id::create("rd2");
        rd2.addr = 64'h0000_0001_0000_1000; rd2.length = 1;
        rd2.first_be = 4'hF; rd2.last_be = 4'h0;
        rd2.start(m_sequencer);
    endtask
endclass
