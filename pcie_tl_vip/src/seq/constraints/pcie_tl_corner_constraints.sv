class pcie_tl_corner_constraints extends uvm_object;
    `uvm_object_utils(pcie_tl_corner_constraints)
    function new(string name = "pcie_tl_corner_constraints"); super.new(name); endfunction
    static function void apply(pcie_tl_tlp tlp);
        tlp.constraint_mode_sel = CONSTRAINT_CORNER_CASE;
    endfunction
endclass
