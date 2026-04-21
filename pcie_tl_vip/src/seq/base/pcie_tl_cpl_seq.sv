class pcie_tl_cpl_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_cpl_seq)
    rand bit [15:0]   completer_id;
    rand bit [15:0]   requester_id;
    rand bit [9:0]    tag;
    rand cpl_status_e status;
    rand bit          has_data;
    rand tlp_constraint_mode_e mode;
    constraint c_default { mode == CONSTRAINT_LEGAL; status == CPL_STATUS_SC; }
    function new(string name = "pcie_tl_cpl_seq"); super.new(name); endfunction
    task body();
        pcie_tl_cpl_tlp tlp;
        tlp_kind_e k = has_data ? TLP_CPLD : TLP_CPL;
        `uvm_do_with(tlp, { tlp.kind == k; tlp.completer_id == local::completer_id;
            tlp.requester_id == local::requester_id; tlp.tag == local::tag;
            tlp.cpl_status == local::status; tlp.constraint_mode_sel == local::mode; })
    endtask
endclass
