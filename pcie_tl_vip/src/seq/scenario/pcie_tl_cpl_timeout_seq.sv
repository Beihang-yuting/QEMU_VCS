class pcie_tl_cpl_timeout_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_cpl_timeout_seq)
    rand bit [63:0] addr;
    function new(string name = "pcie_tl_cpl_timeout_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("timeout_rd");
        rd.addr = addr; rd.length = 1; rd.first_be = 4'hF; rd.last_be = 4'h0;
        rd.start(m_sequencer);
        // EP should NOT respond - timeout will be triggered by RC driver
    endtask
endclass
