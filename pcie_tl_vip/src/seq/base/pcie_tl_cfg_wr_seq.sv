class pcie_tl_cfg_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_cfg_wr_seq)
    rand bit [15:0] target_bdf;
    rand bit [9:0]  reg_num;
    rand bit [3:0]  first_be;
    rand bit [31:0] wr_data;
    rand bit        is_type1;
    rand tlp_constraint_mode_e mode;
    constraint c_default { mode == CONSTRAINT_LEGAL; first_be == 4'hF; }
    function new(string name = "pcie_tl_cfg_wr_seq"); super.new(name); endfunction
    task body();
        pcie_tl_cfg_tlp tlp;
        tlp_kind_e k = is_type1 ? TLP_CFG_WR1 : TLP_CFG_WR0;
        `uvm_do_with(tlp, { tlp.kind == k; tlp.completer_id == local::target_bdf;
            tlp.reg_num == local::reg_num; tlp.first_be == local::first_be;
            tlp.constraint_mode_sel == local::mode; })
    endtask
endclass
