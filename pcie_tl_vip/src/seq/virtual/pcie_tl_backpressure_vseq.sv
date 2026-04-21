class pcie_tl_backpressure_vseq extends pcie_tl_base_vseq;
    `uvm_object_utils(pcie_tl_backpressure_vseq)
    rand int burst_count;
    constraint c_default { burst_count inside {[8:64]}; }
    function new(string name = "pcie_tl_backpressure_vseq"); super.new(name); endfunction
    task body();
        // Burst write to exhaust FC credits
        for (int i = 0; i < burst_count; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr_%0d",i));
            wr.addr = 64'h0000_0001_0000_0000 + (i * 256);
            wr.length = 64; wr.first_be = 4'hF; wr.last_be = 4'hF;
            wr.start(rc_seqr);
        end
    endtask
endclass
