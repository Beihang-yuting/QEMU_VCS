class pcie_tl_err_unexpected_cpl_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_err_unexpected_cpl_seq)
    function new(string name = "pcie_tl_err_unexpected_cpl_seq"); super.new(name); endfunction
    task body();
        pcie_tl_cpl_tlp tlp;
        `uvm_do_with(tlp, { tlp.kind == TLP_CPLD; tlp.tag == 10'h3FF;
            tlp.cpl_status == CPL_STATUS_SC; tlp.constraint_mode_sel == CONSTRAINT_LEGAL; })
    endtask
endclass
