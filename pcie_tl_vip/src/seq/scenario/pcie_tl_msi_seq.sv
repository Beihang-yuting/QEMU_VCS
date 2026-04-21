class pcie_tl_msi_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_msi_seq)
    rand bit [63:0] msi_addr;
    rand bit [31:0] msi_data;
    rand int        vector_num;
    rand bit        is_msix;
    function new(string name = "pcie_tl_msi_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("msi_wr");
        wr.addr = msi_addr;
        wr.length = 1;
        wr.first_be = 4'hF;
        wr.last_be = 4'h0;
        wr.is_64bit = (msi_addr[63:32] != 0);
        wr.start(m_sequencer);
    endtask
endclass
