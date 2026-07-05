//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - RC Driver
//-----------------------------------------------------------------------------

class pcie_tl_rc_driver extends pcie_tl_base_driver;
    `uvm_component_utils(pcie_tl_rc_driver)

    //--- Completion timeout ---
    int  cpl_timeout_ns = 50000;  // 50us default

    //--- Outstanding requests awaiting completion ---
    pcie_tl_tlp pending_cpl[bit [9:0]];  // tag -> request

    //--- Multi-completion tracking: tag -> remaining bytes ---
    typedef struct {
        int  total_bytes;
        int  received_bytes;
    } cpl_byte_tracker_t;
    cpl_byte_tracker_t cpl_byte_trackers[bit [9:0]];

    //--- BAR allocation state ---
    bit [63:0] next_bar_addr = 64'h0000_0001_0000_0000;  // start at 4GB

    //--- Interrupt handling ---
    int  msi_received_count = 0;
    int  intx_asserted[4];  // INTA-INTD

    //--- Unified memory backend (injected by env when cfg.use_unified_mem=1) ---
    host_mem_api  mem;                     // null -> no memory model (default OFF)
    bit           use_unified_mem = 0;     // mirror of cfg.use_unified_mem; default 0
    bit           auto_response_enable = 1;

    //--- Completion splitting config (injected by env) ---
    int mps_bytes = 256;
    int rcb_bytes = 64;

    function new(string name = "pcie_tl_rc_driver", uvm_component parent = null);
        super.new(name, parent);
        foreach (intx_asserted[i]) intx_asserted[i] = 0;
    endfunction

    //=========================================================================
    // Unified-memory helpers (only called when mem != null)
    //=========================================================================
    protected function void um_write(bit [63:0] a, bit [7:0] data[], bit [3:0] fbe, bit [3:0] lbe);
        int total_dw = (data.size() + 3) / 4;
        int idx = 0;
        for (int dw = 0; dw < total_dw; dw++) begin
            bit [3:0] be = (dw == 0) ? fbe :
                           (dw == total_dw - 1 && total_dw > 1) ? lbe : 4'hF;
            for (int b = 0; b < 4; b++) begin
                if (idx < data.size()) begin
                    if (be[b]) begin
                        byte one[];
                        one = new[1];
                        one[0] = byte'(data[idx]);
                        mem.write_mem(a + idx, one);
                    end
                    idx++;
                end
            end
        end
    endfunction

    protected function void um_read(bit [63:0] a, int len, output bit [7:0] data[]);
        byte rd[];
        mem.read_mem(a, len, rd);
        data = new[len];
        foreach (rd[i]) data[i] = rd[i];
    endfunction

    //=========================================================================
    // Handle incoming request (called when RC receives a non-posted TLP from EP)
    // Gate: returns immediately when use_unified_mem=0 (OFF path unchanged)
    //=========================================================================
    virtual task handle_request(pcie_tl_tlp req);
        if (!use_unified_mem || mem == null || !auto_response_enable) return;
        case (req.kind)
            TLP_MEM_WR: begin
                pcie_tl_mem_tlp w;
                if ($cast(w, req)) um_write(w.addr, w.payload, w.first_be, w.last_be);
            end
            TLP_MEM_RD, TLP_MEM_RD_LK: begin
                pcie_tl_mem_tlp r;
                if ($cast(r, req)) begin
                    tlp_kind_e k = (req.kind == TLP_MEM_RD_LK) ? TLP_CPLD_LK : TLP_CPLD;
                    send_mem_completion(r, k);
                end
            end
            TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS: begin
                pcie_tl_atomic_tlp a;
                if ($cast(a, req)) send_atomic_completion(a);
            end
            default: ;
        endcase
    endtask

    //=========================================================================
    // Send memory read completion(s), splitting per MPS/RCB rules
    // Mirrors ep_driver's handle_mem_read logic exactly
    //=========================================================================
    protected task send_mem_completion(pcie_tl_mem_tlp r, tlp_kind_e k);
        int total_byte_count;
        int remaining;
        bit [63:0] cur_addr;
        int cpl_idx;

        total_byte_count = (r.length == 0) ? 4096 : r.length * 4;
        remaining = total_byte_count;
        cur_addr  = r.addr;
        cpl_idx   = 0;

        while (remaining > 0) begin
            pcie_tl_cpl_tlp cpl;
            int chunk;
            int bytes_to_rcb;
            int len_dw;
            bit [7:0] um_data[];

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

            cpl = pcie_tl_cpl_tlp::type_id::create("rc_cpl");
            cpl.kind         = k;
            cpl.fmt          = FMT_3DW_WITH_DATA;
            cpl.type_f       = (k == TLP_CPLD_LK) ? TLP_TYPE_CPL_LK : TLP_TYPE_CPL;
            cpl.tc           = r.tc;
            cpl.td           = 0;
            cpl.ep_bit       = 0;
            cpl.attr         = r.attr;
            cpl.length       = (len_dw == 1024) ? 0 : len_dw[9:0];
            cpl.requester_id = r.requester_id;
            cpl.tag          = r.tag;
            cpl.completer_id = 16'h0000;  // RC BDF
            cpl.cpl_status   = CPL_STATUS_SC;
            cpl.bcm          = 0;
            cpl.byte_count   = remaining[11:0];
            cpl.lower_addr   = cur_addr[6:0];
            cpl.payload      = new[chunk];

            um_read(cur_addr, chunk, um_data);
            for (int i = 0; i < chunk; i++) cpl.payload[i] = um_data[i];

            send_tlp(cpl);

            cur_addr  += chunk;
            remaining -= chunk;
            cpl_idx++;
        end
    endtask

    //=========================================================================
    // Send atomic operation completion (FetchAdd / Swap / CAS)
    // Returns old value, computes new value, writes back
    //=========================================================================
    protected task send_atomic_completion(pcie_tl_atomic_tlp a);
        int sz;
        bit [7:0] old_data[];
        bit [7:0] new_data[];
        pcie_tl_cpl_tlp cpl;
        int len_dw;

        sz = a.is_64bit ? 8 : 4;

        // Read current (old) value from host memory
        um_read(a.addr, sz, old_data);

        // Compute new value based on op type; operand(s) from payload (little-endian)
        new_data = new[sz];
        case (a.kind)
            TLP_ATOMIC_FETCHADD: begin
                bit [63:0] old_val = 0;
                bit [63:0] operand = 0;
                bit [63:0] new_val;
                bit [63:0] tmp;
                for (int i = 0; i < sz && i < old_data.size(); i++) begin
                    tmp = {56'h0, old_data[i]};
                    old_val |= (tmp << (i * 8));
                end
                for (int i = 0; i < sz && i < a.payload.size(); i++) begin
                    tmp = {56'h0, a.payload[i]};
                    operand |= (tmp << (i * 8));
                end
                new_val = old_val + operand;
                for (int i = 0; i < sz; i++)
                    new_data[i] = new_val[i*8 +: 8];
            end
            TLP_ATOMIC_SWAP: begin
                for (int i = 0; i < sz; i++)
                    new_data[i] = (i < a.payload.size()) ? a.payload[i] : 8'h00;
            end
            TLP_ATOMIC_CAS: begin
                // CAS payload = compare || swap (each sz bytes)
                // new = (old == compare) ? swap : old
                bit match = 1;
                for (int i = 0; i < sz; i++) begin
                    bit [7:0] cmp_byte = (i < a.payload.size()) ? a.payload[i] : 8'h00;
                    if (old_data[i] != cmp_byte) match = 0;
                end
                if (match) begin
                    for (int i = 0; i < sz; i++)
                        new_data[i] = (sz + i < a.payload.size()) ? a.payload[sz + i] : 8'h00;
                end else begin
                    for (int i = 0; i < sz; i++) new_data[i] = old_data[i];
                end
            end
            default: begin
                for (int i = 0; i < sz; i++) new_data[i] = old_data[i];
            end
        endcase

        // Write new value back to host memory
        begin
            bit [3:0] fbe = 4'hF;
            bit [3:0] lbe = (sz == 4) ? 4'h0 : 4'hF;
            um_write(a.addr, new_data, fbe, lbe);
        end

        // Build CplD returning OLD value
        len_dw = (sz + 3) / 4;
        cpl = pcie_tl_cpl_tlp::type_id::create("rc_atomic_cpl");
        cpl.kind         = TLP_CPLD;
        cpl.fmt          = FMT_3DW_WITH_DATA;
        cpl.type_f       = TLP_TYPE_CPL;
        cpl.tc           = a.tc;
        cpl.td           = 0;
        cpl.ep_bit       = 0;
        cpl.attr         = a.attr;
        cpl.length       = len_dw[9:0];
        cpl.requester_id = a.requester_id;
        cpl.tag          = a.tag;
        cpl.completer_id = 16'h0000;  // RC BDF
        cpl.cpl_status   = CPL_STATUS_SC;
        cpl.bcm          = 0;
        cpl.byte_count   = sz[11:0];
        cpl.lower_addr   = a.addr[6:0];
        cpl.payload      = new[sz];
        for (int i = 0; i < sz; i++) cpl.payload[i] = old_data[i];

        send_tlp(cpl);
    endtask

    //=========================================================================
    // Override send_tlp to add completion tracking
    //=========================================================================
    virtual task send_tlp(pcie_tl_tlp tlp);
        // Call base send pipeline
        super.send_tlp(tlp);

        // Start completion timeout for Non-Posted
        if (tlp.requires_completion()) begin
            pending_cpl[tlp.tag] = tlp;
            fork
                start_cpl_timeout(tlp.tag, tlp);
            join_none
        end
    endtask

    //=========================================================================
    // Handle incoming completion
    //=========================================================================
    virtual function bit handle_completion(pcie_tl_cpl_tlp cpl);
        pcie_tl_tlp req;

        // Match with outstanding (look up without consuming)
        req = tag_mgr.match_completion(cpl);

        if (req == null) begin
            `uvm_warning("RC_DRV", $sformatf("Unexpected Completion: tag=0x%03h req_id=0x%04h",
                                              cpl.tag, cpl.requester_id))
            return 0;
        end

        // Initialize byte tracker on first CplD for this tag
        if (!cpl_byte_trackers.exists(cpl.tag)) begin
            cpl_byte_tracker_t t;
            t.total_bytes    = (req.length == 0) ? 4096 : req.length * 4;
            t.received_bytes = 0;
            cpl_byte_trackers[cpl.tag] = t;
        end

        // Accumulate received bytes from this completion's payload
        cpl_byte_trackers[cpl.tag].received_bytes += cpl.payload.size();

        `uvm_info("RC_DRV", $sformatf("Completion matched: tag=0x%03h status=%s bytes=%0d/%0d",
                                       cpl.tag, cpl.cpl_status.name(),
                                       cpl_byte_trackers[cpl.tag].received_bytes,
                                       cpl_byte_trackers[cpl.tag].total_bytes), UVM_MEDIUM)

        // Only free tag and remove pending when ALL bytes received
        if (cpl_byte_trackers[cpl.tag].received_bytes >=
            cpl_byte_trackers[cpl.tag].total_bytes) begin
            cpl_byte_trackers.delete(cpl.tag);
            if (pending_cpl.exists(cpl.tag))
                pending_cpl.delete(cpl.tag);
            tag_mgr.free_tag(cpl.tag, cpl.requester_id[2:0]);
        end

        return 1;
    endfunction

    //=========================================================================
    // Completion timeout monitor
    //=========================================================================
    protected task start_cpl_timeout(bit [9:0] tag, pcie_tl_tlp req);
        #(cpl_timeout_ns * 1ns);
        if (pending_cpl.exists(tag)) begin
            `uvm_error("RC_DRV", $sformatf("Completion Timeout: tag=0x%03h after %0dns req=%s",
                                            tag, cpl_timeout_ns, req.convert2string()))
            pending_cpl.delete(tag);
            if (cpl_byte_trackers.exists(tag))
                cpl_byte_trackers.delete(tag);
            tag_mgr.free_tag(tag, req.requester_id[2:0]);
        end
    endtask

    //=========================================================================
    // BAR address allocation
    //=========================================================================
    function bit [63:0] allocate_bar_address(int size);
        bit [63:0] addr;
        // Align to size boundary
        bit [63:0] mask = size - 1;
        next_bar_addr = (next_bar_addr + mask) & ~mask;
        addr = next_bar_addr;
        next_bar_addr += size;
        return addr;
    endfunction

    //=========================================================================
    // Handle incoming interrupt messages
    //=========================================================================
    function void handle_interrupt(pcie_tl_msg_tlp msg);
        case (msg.msg_code)
            MSG_ASSERT_INTA:   intx_asserted[0]++;
            MSG_ASSERT_INTB:   intx_asserted[1]++;
            MSG_ASSERT_INTC:   intx_asserted[2]++;
            MSG_ASSERT_INTD:   intx_asserted[3]++;
            MSG_DEASSERT_INTA: intx_asserted[0]--;
            MSG_DEASSERT_INTB: intx_asserted[1]--;
            MSG_DEASSERT_INTC: intx_asserted[2]--;
            MSG_DEASSERT_INTD: intx_asserted[3]--;
            default: begin
                // MSI is a Memory Write to MSI address
                msi_received_count++;
                `uvm_info("RC_DRV", $sformatf("MSI received: count=%0d", msi_received_count), UVM_MEDIUM)
            end
        endcase
    endfunction

    //=========================================================================
    // Get pending completion count
    //=========================================================================
    function int get_pending_count();
        return pending_cpl.num();
    endfunction

endclass
