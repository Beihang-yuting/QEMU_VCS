class pcie_tl_rc_ep_rdwr_vseq extends pcie_tl_base_vseq;
    `uvm_object_utils(pcie_tl_rc_ep_rdwr_vseq)
    rand bit [63:0] addr;
    rand bit [9:0]  length;
    rand bit        is_read;
    constraint c_default { length inside {[1:32]}; }
    function new(string name = "pcie_tl_rc_ep_rdwr_vseq"); super.new(name); endfunction
    task body();
        bit addr_is_64 = (addr[63:32] != 0);
        if (is_read) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd");
            rd.addr = addr; rd.length = length; rd.is_64bit = addr_is_64;
            rd.first_be = 4'hF; rd.last_be = (length > 1) ? 4'hF : 4'h0;
            rd.start(rc_seqr);
        end else begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
            wr.addr = addr; wr.length = length; wr.is_64bit = addr_is_64;
            wr.first_be = 4'hF; wr.last_be = (length > 1) ? 4'hF : 4'h0;
            wr.start(rc_seqr);
        end
    endtask
endclass
