class pcie_tl_io_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_io_wr_seq)
    rand bit [31:0] addr;
    rand bit [3:0]  first_be;
    rand tlp_constraint_mode_e mode;
    constraint c_default { mode == CONSTRAINT_LEGAL; }
    function new(string name = "pcie_tl_io_wr_seq"); super.new(name); endfunction
    task body();
        pcie_tl_io_tlp tlp;
        `uvm_do_with(tlp, { tlp.kind == TLP_IO_WR; tlp.addr == local::addr;
            tlp.first_be == local::first_be; tlp.constraint_mode_sel == local::mode; })
    endtask
endclass
