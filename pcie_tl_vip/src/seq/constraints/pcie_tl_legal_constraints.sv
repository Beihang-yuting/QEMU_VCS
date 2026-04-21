class pcie_tl_legal_constraints extends uvm_object;
    `uvm_object_utils(pcie_tl_legal_constraints)
    function new(string name = "pcie_tl_legal_constraints"); super.new(name); endfunction
    // Utility: apply legal constraints to a TLP
    static function void apply(pcie_tl_tlp tlp);
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
    endfunction
endclass
