class pcie_tl_enum_then_dma_vseq extends pcie_tl_base_vseq;
    `uvm_object_utils(pcie_tl_enum_then_dma_vseq)
    rand bit [15:0] target_bdf;
    rand bit [63:0] dma_addr;
    rand int        dma_size;
    constraint c_default { dma_size inside {[256:2048]}; }
    function new(string name = "pcie_tl_enum_then_dma_vseq"); super.new(name); endfunction
    task body();
        pcie_tl_bar_enum_seq enum_seq;
        pcie_tl_dma_rdwr_seq dma_seq;
        // Phase 1: Enumerate
        enum_seq = pcie_tl_bar_enum_seq::type_id::create("enum_seq");
        enum_seq.target_bdf = target_bdf;
        enum_seq.start(rc_seqr);
        // Phase 2: DMA
        dma_seq = pcie_tl_dma_rdwr_seq::type_id::create("dma_seq");
        dma_seq.addr = dma_addr; dma_seq.xfer_size = dma_size;
        dma_seq.is_read = 0;
        dma_seq.start(rc_seqr);
    endtask
endclass
