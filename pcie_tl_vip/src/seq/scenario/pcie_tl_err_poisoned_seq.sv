class pcie_tl_err_poisoned_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_err_poisoned_seq)
    function new(string name = "pcie_tl_err_poisoned_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_tlp tlp;
        `uvm_do_with(tlp, { tlp.kind == TLP_MEM_WR; tlp.inject_poisoned == 1;
            tlp.constraint_mode_sel == CONSTRAINT_ILLEGAL; })
    endtask
endclass
