//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - EP Driver
//-----------------------------------------------------------------------------

class pcie_tl_ep_driver extends pcie_tl_base_driver;
    `uvm_component_utils(pcie_tl_ep_driver)

    //--- Auto-response ---
    bit  auto_response_enable = 1;
    int  response_delay_min   = 0;
    int  response_delay_max   = 10;

    //--- Completion splitting config ---
    int mps_bytes = 256;
    int rcb_bytes = 64;

    //--- Internal memory model ---
    bit [7:0] mem_space[bit [63:0]];   // sparse memory

    //--- Internal IO space ---
    bit [7:0] io_space[bit [31:0]];

    function new(string name = "pcie_tl_ep_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //=========================================================================
    // Handle incoming request (called when EP receives a TLP)
    //=========================================================================
    virtual task handle_request(pcie_tl_tlp req);
        int delay;

        if (!auto_response_enable) return;

        // Random response delay
        delay = $urandom_range(response_delay_max, response_delay_min);
        if (delay > 0) #(delay * 1ns);

        case (req.kind)
            TLP_CFG_RD0, TLP_CFG_RD1:  handle_cfg_read(req);
            TLP_CFG_WR0, TLP_CFG_WR1:  handle_cfg_write(req);
            TLP_MEM_RD, TLP_MEM_RD_LK: handle_mem_read(req);
            TLP_MEM_WR:                 handle_mem_write(req);
            TLP_IO_RD:                  handle_io_read(req);
            TLP_IO_WR:                  handle_io_write(req);
            default: begin
                `uvm_info("EP_DRV", $sformatf("Unhandled TLP type: %s", req.kind.name()), UVM_MEDIUM)
            end
        endcase
    endtask

    //=========================================================================
    // Config Read handler
    //=========================================================================
    protected task handle_cfg_read(pcie_tl_tlp req);
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_cpl_tlp cpl;
        bit [31:0] data;

        $cast(cfg_req, req);
        data = cfg_mgr.read(cfg_req.get_cfg_addr());

        cpl = generate_completion(req, CPL_STATUS_SC);
        cpl.kind    = TLP_CPLD;
        cpl.fmt     = FMT_3DW_WITH_DATA;
        cpl.length  = 1;
        cpl.payload = new[4];
        cpl.payload[0] = data[7:0];
        cpl.payload[1] = data[15:8];
        cpl.payload[2] = data[23:16];
        cpl.payload[3] = data[31:24];

        send_tlp(cpl);
    endtask

    //=========================================================================
    // Config Write handler
    //=========================================================================
    protected task handle_cfg_write(pcie_tl_tlp req);
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_cpl_tlp cpl;
        bit [31:0] data;

        $cast(cfg_req, req);

        if (req.payload.size() >= 4)
            data = {req.payload[3], req.payload[2], req.payload[1], req.payload[0]};

        cfg_mgr.write(cfg_req.get_cfg_addr(), data, cfg_req.first_be);

        cpl = generate_completion(req, CPL_STATUS_SC);
        send_tlp(cpl);
    endtask

    //=========================================================================
    // Memory Read handler (with completion splitting per MPS/RCB)
    //=========================================================================
    protected task handle_mem_read(pcie_tl_tlp req);
        pcie_tl_mem_tlp mem_req;
        int total_byte_count;
        int remaining;
        bit [63:0] cur_addr;
        int cpl_idx;

        $cast(mem_req, req);
        total_byte_count = (req.length == 0) ? 4096 : req.length * 4;
        remaining = total_byte_count;
        cur_addr  = mem_req.addr;
        cpl_idx   = 0;

        while (remaining > 0) begin
            pcie_tl_cpl_tlp cpl;
            int chunk;
            int bytes_to_rcb;
            int len_dw;

            // First split: align to RCB boundary, then clamp to MPS
            // Subsequent splits: MPS-sized or remainder
            if (cpl_idx == 0) begin
                bytes_to_rcb = rcb_bytes - (cur_addr % rcb_bytes);
                if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
                chunk = (bytes_to_rcb < mps_bytes) ? bytes_to_rcb : mps_bytes;
            end else begin
                chunk = mps_bytes;
            end
            if (chunk > remaining) chunk = remaining;

            len_dw = (chunk + 3) / 4;

            cpl = generate_completion(req, CPL_STATUS_SC);
            cpl.kind       = TLP_CPLD;
            cpl.fmt        = FMT_3DW_WITH_DATA;
            cpl.length     = (len_dw == 1024) ? 0 : len_dw[9:0];
            cpl.byte_count = remaining[11:0];
            cpl.lower_addr = cur_addr[6:0];
            cpl.payload    = new[chunk];

            // Read from internal memory
            for (int i = 0; i < chunk; i++) begin
                bit [63:0] a = cur_addr + i;
                cpl.payload[i] = mem_space.exists(a) ? mem_space[a] : 8'h00;
            end

            send_tlp(cpl);

            cur_addr  += chunk;
            remaining -= chunk;
            cpl_idx++;
        end
    endtask

    //=========================================================================
    // Memory Write handler
    //=========================================================================
    protected task handle_mem_write(pcie_tl_tlp req);
        pcie_tl_mem_tlp mem_req;
        $cast(mem_req, req);

        // Write to internal memory
        foreach (req.payload[i]) begin
            mem_space[mem_req.addr + i] = req.payload[i];
        end

        `uvm_info("EP_DRV", $sformatf("Memory Write: addr=0x%016h size=%0d",
                                       mem_req.addr, req.payload.size()), UVM_HIGH)
    endtask

    //=========================================================================
    // IO Read handler
    //=========================================================================
    protected task handle_io_read(pcie_tl_tlp req);
        pcie_tl_io_tlp io_req;
        pcie_tl_cpl_tlp cpl;

        $cast(io_req, req);

        cpl = generate_completion(req, CPL_STATUS_SC);
        cpl.kind    = TLP_CPLD;
        cpl.fmt     = FMT_3DW_WITH_DATA;
        cpl.length  = 1;
        cpl.payload = new[4];

        for (int i = 0; i < 4; i++) begin
            bit [31:0] addr = io_req.addr + i;
            cpl.payload[i] = io_space.exists(addr) ? io_space[addr] : 8'h00;
        end

        send_tlp(cpl);
    endtask

    //=========================================================================
    // IO Write handler
    //=========================================================================
    protected task handle_io_write(pcie_tl_tlp req);
        pcie_tl_io_tlp io_req;
        pcie_tl_cpl_tlp cpl;

        $cast(io_req, req);

        for (int i = 0; i < req.payload.size() && i < 4; i++) begin
            io_space[io_req.addr + i] = req.payload[i];
        end

        cpl = generate_completion(req, CPL_STATUS_SC);
        send_tlp(cpl);
    endtask

    //=========================================================================
    // Generate completion from request
    //=========================================================================
    function pcie_tl_cpl_tlp generate_completion(pcie_tl_tlp req, cpl_status_e status);
        pcie_tl_cpl_tlp cpl = pcie_tl_cpl_tlp::type_id::create("cpl");
        cpl.kind         = TLP_CPL;
        cpl.fmt          = FMT_3DW_NO_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.tc           = req.tc;
        cpl.td           = 0;
        cpl.ep_bit       = 0;
        cpl.attr         = req.attr;
        cpl.length       = 0;
        cpl.requester_id = req.requester_id;
        cpl.tag          = req.tag;
        cpl.completer_id = 16'h0100;  // default EP BDF
        cpl.cpl_status   = status;
        cpl.bcm          = 0;
        cpl.byte_count   = 0;
        cpl.lower_addr   = 0;
        return cpl;
    endfunction

    //=========================================================================
    // DMA initiation (Bus Master mode)
    //=========================================================================
    task initiate_dma(bit [63:0] addr, int size, bit is_read);
        pcie_tl_mem_tlp tlp = pcie_tl_mem_tlp::type_id::create("dma_tlp");
        tlp.kind      = is_read ? TLP_MEM_RD : TLP_MEM_WR;
        tlp.addr      = addr;
        tlp.is_64bit  = (addr[63:32] != 0);
        tlp.length    = (size + 3) / 4;
        tlp.first_be  = 4'hF;
        tlp.last_be   = (tlp.length > 1) ? 4'hF : 4'h0;

        if (!is_read) begin
            tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
            tlp.payload = new[size];
            foreach (tlp.payload[i])
                tlp.payload[i] = mem_space.exists(addr + i) ? mem_space[addr + i] : 8'h00;
        end else begin
            tlp.fmt = tlp.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
        end

        send_tlp(tlp);
    endtask

    //=========================================================================
    // MSI/MSI-X initiation
    //=========================================================================
    task send_msi(bit [63:0] msi_addr, bit [31:0] msi_data);
        pcie_tl_mem_tlp tlp = pcie_tl_mem_tlp::type_id::create("msi_tlp");
        tlp.kind     = TLP_MEM_WR;
        tlp.addr     = msi_addr;
        tlp.is_64bit = (msi_addr[63:32] != 0);
        tlp.fmt      = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        tlp.length   = 1;
        tlp.first_be = 4'hF;
        tlp.last_be  = 4'h0;
        tlp.payload  = new[4];
        tlp.payload[0] = msi_data[7:0];
        tlp.payload[1] = msi_data[15:8];
        tlp.payload[2] = msi_data[23:16];
        tlp.payload[3] = msi_data[31:24];

        send_tlp(tlp);
    endtask

endclass
