class pcie_tl_msg_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_msg_seq)
    rand msg_code_e msg_code;
    rand bit        has_data;
    rand tlp_constraint_mode_e mode;
    constraint c_default { mode == CONSTRAINT_LEGAL; }
    function new(string name = "pcie_tl_msg_seq"); super.new(name); endfunction
    task body();
        pcie_tl_msg_tlp tlp;
        tlp_kind_e k = has_data ? TLP_MSGD : TLP_MSG;
        `uvm_do_with(tlp, { tlp.kind == k; tlp.msg_code == local::msg_code;
            tlp.constraint_mode_sel == local::mode; })
    endtask
endclass
