class pcie_tl_dma_rdwr_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_dma_rdwr_seq)
    rand bit [63:0] addr;
    rand int        xfer_size;
    rand int        max_payload;
    rand bit        is_read;
    constraint c_default { xfer_size inside {[64:4096]}; max_payload inside {128, 256, 512}; }
    function new(string name = "pcie_tl_dma_rdwr_seq"); super.new(name); endfunction
    task body();
        int remaining = xfer_size;
        bit [63:0] cur_addr = addr;
        while (remaining > 0) begin
            int chunk = (remaining > max_payload) ? max_payload : remaining;
            int bytes_to_4kb = 4096 - cur_addr[11:0];
            if (bytes_to_4kb == 0) bytes_to_4kb = 4096;
            if (chunk > bytes_to_4kb) chunk = bytes_to_4kb;
            if (is_read) begin
                pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd");
                rd.addr = cur_addr; rd.length = (chunk + 3) / 4;
                rd.first_be = 4'hF; rd.last_be = (rd.length > 1) ? 4'hF : 4'h0;
                rd.is_64bit = (cur_addr[63:32] != 0);
                rd.start(m_sequencer);
            end else begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
                wr.addr = cur_addr; wr.length = (chunk + 3) / 4;
                wr.first_be = 4'hF; wr.last_be = (wr.length > 1) ? 4'hF : 4'h0;
                wr.is_64bit = (cur_addr[63:32] != 0);
                wr.start(m_sequencer);
            end
            cur_addr += chunk;
            remaining -= chunk;
        end
    endtask
endclass
