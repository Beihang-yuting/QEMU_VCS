class pcie_tl_ltr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_ltr_seq)
    rand tlp_constraint_mode_e mode;
    constraint c_default { mode == CONSTRAINT_LEGAL; }
    function new(string name = "pcie_tl_ltr_seq"); super.new(name); endfunction
    task body();
        pcie_tl_ltr_tlp tlp;
        `uvm_do_with(tlp, { tlp.kind == TLP_LTR; tlp.constraint_mode_sel == local::mode; })
    endtask
endclass
