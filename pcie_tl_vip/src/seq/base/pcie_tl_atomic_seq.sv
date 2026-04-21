class pcie_tl_atomic_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_atomic_seq)
    rand bit [63:0]       addr;
    rand bit              is_64bit;
    rand tlp_kind_e       op_kind;
    rand atomic_op_size_e op_size;
    rand tlp_constraint_mode_e mode;
    constraint c_default { mode == CONSTRAINT_LEGAL; op_kind inside {TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS}; }
    function new(string name = "pcie_tl_atomic_seq"); super.new(name); endfunction
    task body();
        pcie_tl_atomic_tlp tlp;
        `uvm_do_with(tlp, { tlp.kind == local::op_kind; tlp.addr == local::addr;
            tlp.is_64bit == local::is_64bit; tlp.op_size == local::op_size;
            tlp.constraint_mode_sel == local::mode; })
    endtask
endclass
