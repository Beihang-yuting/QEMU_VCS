class pcie_tl_err_malformed_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_err_malformed_seq)
    function new(string name = "pcie_tl_err_malformed_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_tlp tlp;
        `uvm_do_with(tlp, { tlp.kind == TLP_MEM_WR; tlp.constraint_mode_sel == CONSTRAINT_ILLEGAL;
            tlp.field_bitmask != 0; })
    endtask
endclass
