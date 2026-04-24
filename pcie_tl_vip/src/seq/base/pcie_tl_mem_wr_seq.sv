class pcie_tl_mem_wr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_mem_wr_seq)
    rand bit [63:0] addr;
    rand bit [9:0]  length;
    rand bit [3:0]  first_be, last_be;
    rand bit        is_64bit;
    rand tlp_constraint_mode_e mode;
    pcie_tl_prefix  prefixes[$];
    bit             has_prefix;
    constraint c_default { mode == CONSTRAINT_LEGAL; length inside {[1:128]}; first_be != 0; }
    function new(string name = "pcie_tl_mem_wr_seq"); super.new(name); endfunction
    task body();
        pcie_tl_mem_tlp tlp;
        // Auto-derive is_64bit from address if not explicitly set
        if (addr[63:32] != 0) is_64bit = 1;
        `uvm_do_with(tlp, { tlp.kind == TLP_MEM_WR; tlp.addr == local::addr;
            tlp.length == local::length; tlp.first_be == local::first_be;
            tlp.last_be == local::last_be; tlp.is_64bit == local::is_64bit;
            tlp.constraint_mode_sel == local::mode; })
        if (has_prefix) begin
            tlp.prefixes = prefixes;
            tlp.has_prefix = 1;
        end
    endtask
endclass
