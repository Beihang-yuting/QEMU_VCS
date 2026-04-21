//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Scoreboard
//-----------------------------------------------------------------------------

class pcie_tl_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(pcie_tl_scoreboard)

    //--- Analysis imports ---
    `uvm_analysis_imp_decl(_rc)
    `uvm_analysis_imp_decl(_ep)

    uvm_analysis_imp_rc #(pcie_tl_tlp, pcie_tl_scoreboard) rc_imp;
    uvm_analysis_imp_ep #(pcie_tl_tlp, pcie_tl_scoreboard) ep_imp;

    //--- Pending requests: tag -> request ---
    pcie_tl_tlp pending_requests[bit [9:0]];

    //--- Multi-completion tracking ---
    typedef struct {
        pcie_tl_tlp    orig_req;
        int            total_bytes;
        int            received_bytes;
        bit [63:0]     expected_addr;
        int            cpl_count;
    } cpl_tracker_t;

    cpl_tracker_t cpl_trackers[bit [9:0]];

    //--- Check enables ---
    bit ordering_check_enable   = 1;
    bit completion_check_enable = 1;
    bit data_integrity_enable   = 1;

    //--- Statistics ---
    int total_requests     = 0;
    int total_completions  = 0;
    int matched            = 0;
    int mismatched         = 0;
    int unexpected         = 0;
    int timed_out          = 0;

    //--- Data integrity: store write data for read comparison ---
    bit [7:0] written_data[bit [63:0]];  // addr -> data

    //--- Ordering history ---
    pcie_tl_tlp rc_sent_history[$];
    pcie_tl_tlp ep_sent_history[$];

    function new(string name = "pcie_tl_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        rc_imp = new("rc_imp", this);
        ep_imp = new("ep_imp", this);
    endfunction

    //=========================================================================
    // RC side: TLPs sent by RC (requests) or received by RC (completions from EP)
    //=========================================================================
    function void write_rc(pcie_tl_tlp tlp);
        case (tlp.get_category())
            TLP_CAT_NON_POSTED: begin
                // RC sent a request
                total_requests++;
                pending_requests[tlp.tag] = tlp;
            end
            TLP_CAT_POSTED: begin
                // RC sent a posted request (Memory Write)
                total_requests++;
                if (data_integrity_enable) begin
                    store_write_data(tlp);
                end
            end
            TLP_CAT_COMPLETION: begin
                // Should not happen on RC side normally
            end
        endcase

        if (ordering_check_enable)
            check_ordering(tlp, rc_sent_history);

        rc_sent_history.push_back(tlp);
        if (rc_sent_history.size() > 64)
            void'(rc_sent_history.pop_front());
    endfunction

    //=========================================================================
    // EP side: TLPs sent by EP (completions) or received by EP
    //=========================================================================
    function void write_ep(pcie_tl_tlp tlp);
        case (tlp.get_category())
            TLP_CAT_COMPLETION: begin
                total_completions++;
                if (completion_check_enable)
                    check_completion(tlp);
            end
            TLP_CAT_POSTED, TLP_CAT_NON_POSTED: begin
                // EP sent a request (DMA, MSI, etc.)
                total_requests++;
            end
        endcase

        if (ordering_check_enable)
            check_ordering(tlp, ep_sent_history);

        ep_sent_history.push_back(tlp);
        if (ep_sent_history.size() > 64)
            void'(ep_sent_history.pop_front());
    endfunction

    //=========================================================================
    // Check 1: Request-Completion matching (multi-completion tracking)
    //=========================================================================
    protected function void check_completion(pcie_tl_tlp tlp);
        pcie_tl_cpl_tlp cpl;
        cpl_tracker_t tracker;

        if (!$cast(cpl, tlp)) return;

        // First completion for this tag: create tracker from pending_requests
        if (!cpl_trackers.exists(cpl.tag)) begin
            if (pending_requests.exists(cpl.tag)) begin
                pcie_tl_tlp req = pending_requests[cpl.tag];
                pcie_tl_mem_tlp mem_req;
                tracker.orig_req       = req;
                tracker.total_bytes    = (req.length == 0) ? 4096 : req.length * 4;
                tracker.received_bytes = 0;
                tracker.cpl_count      = 0;
                if ($cast(mem_req, req))
                    tracker.expected_addr = mem_req.addr;
                else
                    tracker.expected_addr = 0;
                cpl_trackers[cpl.tag] = tracker;
            end else begin
                `uvm_warning("SCB", $sformatf(
                    "Unexpected Completion: tag=0x%03h req_id=0x%04h",
                    cpl.tag, cpl.requester_id))
                unexpected++;
                return;
            end
        end

        tracker = cpl_trackers[cpl.tag];

        // Verify requester_id match
        if (tracker.orig_req.requester_id != cpl.requester_id) begin
            `uvm_error("SCB", $sformatf(
                "Completion requester_id mismatch: tag=0x%03h expected=0x%04h got=0x%04h",
                cpl.tag, tracker.orig_req.requester_id, cpl.requester_id))
            mismatched++;
        end

        // Verify lower_addr
        if (cpl.lower_addr != tracker.expected_addr[6:0]) begin
            `uvm_warning("SCB", $sformatf(
                "Completion lower_addr mismatch: tag=0x%03h expected=0x%02h got=0x%02h",
                cpl.tag, tracker.expected_addr[6:0], cpl.lower_addr))
        end

        // Verify byte_count matches remaining
        if (cpl.byte_count != (tracker.total_bytes - tracker.received_bytes)) begin
            `uvm_warning("SCB", $sformatf(
                "Completion byte_count mismatch: tag=0x%03h expected=%0d got=%0d",
                cpl.tag, tracker.total_bytes - tracker.received_bytes, cpl.byte_count))
        end

        // Data integrity check for read completions
        if (data_integrity_enable && cpl.kind == TLP_CPLD)
            check_data_integrity(tracker.orig_req, cpl, tracker.received_bytes);

        // Accumulate received bytes
        tracker.received_bytes += cpl.payload.size();
        tracker.expected_addr  += cpl.payload.size();
        tracker.cpl_count++;
        cpl_trackers[cpl.tag] = tracker;

        // Check if all bytes received
        if (tracker.received_bytes >= tracker.total_bytes) begin
            matched++;
            cpl_trackers.delete(cpl.tag);
            pending_requests.delete(cpl.tag);
        end
    endfunction

    //=========================================================================
    // Check 2: Data integrity (with byte offset for split completions)
    //=========================================================================
    protected function void check_data_integrity(pcie_tl_tlp req, pcie_tl_cpl_tlp cpl, int byte_offset = 0);
        pcie_tl_mem_tlp mem_req;
        if (!$cast(mem_req, req)) return;

        foreach (cpl.payload[i]) begin
            bit [63:0] addr = mem_req.addr + byte_offset + i;
            if (written_data.exists(addr)) begin
                if (written_data[addr] != cpl.payload[i]) begin
                    `uvm_error("SCB", $sformatf(
                        "Data mismatch at addr=0x%016h: expected=0x%02h got=0x%02h",
                        addr, written_data[addr], cpl.payload[i]))
                    mismatched++;
                    return;
                end
            end
        end
    endfunction

    //=========================================================================
    // Check 3: Ordering compliance
    //=========================================================================
    protected function void check_ordering(pcie_tl_tlp tlp, ref pcie_tl_tlp history[$]);
        tlp_category_e new_cat;
        tlp_category_e prev_cat;
        // Simplified ordering check
        if (history.size() == 0) return;

        new_cat  = tlp.get_category();
        prev_cat = history[$].get_category();

        // Key violation: Non-Posted passing a Posted without RO
        if (new_cat == TLP_CAT_NON_POSTED && prev_cat == TLP_CAT_POSTED) begin
            if (!tlp.attr[0]) begin  // RO not set
                // This could be a violation if they share the same path
                `uvm_info("SCB", "Ordering: Non-Posted after Posted (check RO)", UVM_HIGH)
            end
        end
    endfunction

    //=========================================================================
    // Store write data for later comparison
    //=========================================================================
    protected function void store_write_data(pcie_tl_tlp tlp);
        pcie_tl_mem_tlp mem;
        if (tlp.kind != TLP_MEM_WR) return;
        if (!$cast(mem, tlp)) return;

        foreach (tlp.payload[i]) begin
            written_data[mem.addr + i] = tlp.payload[i];
        end
    endfunction

    //=========================================================================
    // Check 5: Error response verification
    //=========================================================================
    function void check_error_response(pcie_tl_tlp err_tlp, pcie_tl_cpl_tlp response);
        if (err_tlp.inject_poisoned || err_tlp.inject_ecrc_err) begin
            // Expect error response
            if (response.cpl_status == CPL_STATUS_SC) begin
                `uvm_warning("SCB", $sformatf(
                    "Expected error response for injected error, got SC: tag=0x%03h",
                    err_tlp.tag))
            end
        end
    endfunction

    //=========================================================================
    // Report
    //=========================================================================
    function void report_phase(uvm_phase phase);
        `uvm_info("SCB", $sformatf("\n========== Scoreboard Report ==========\n  Requests:     %0d\n  Completions:  %0d\n  Matched:      %0d\n  Mismatched:   %0d\n  Unexpected:   %0d\n  Timed Out:    %0d\n========================================",
            total_requests, total_completions, matched, mismatched, unexpected, timed_out
        ), UVM_LOW)

        // Check for incomplete multi-completion trackers
        if (cpl_trackers.size() > 0) begin
            bit [9:0] tag;
            if (cpl_trackers.first(tag)) begin
                do begin
                    `uvm_warning("SCB", $sformatf(
                        "Incomplete completion: tag=0x%03h received=%0d/%0d bytes (%0d splits)",
                        tag, cpl_trackers[tag].received_bytes,
                        cpl_trackers[tag].total_bytes, cpl_trackers[tag].cpl_count))
                    timed_out++;
                end while (cpl_trackers.next(tag));
            end
        end

        if (mismatched > 0 || unexpected > 0)
            `uvm_error("SCB", $sformatf("FAIL: %0d mismatches, %0d unexpected completions",
                                         mismatched, unexpected))
    endfunction

endclass
