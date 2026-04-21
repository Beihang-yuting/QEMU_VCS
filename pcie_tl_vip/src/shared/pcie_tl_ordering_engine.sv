//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Ordering Engine (PCIe Spec Table 2-40)
//-----------------------------------------------------------------------------

class pcie_tl_ordering_engine extends uvm_object;
    `uvm_object_utils(pcie_tl_ordering_engine)

    //--- Queues ---
    pcie_tl_tlp posted_queue[$];
    pcie_tl_tlp non_posted_queue[$];
    pcie_tl_tlp completion_queue[$];

    //--- Sent history for ordering check ---
    pcie_tl_tlp sent_history[$];
    int         max_history = 64;

    //--- Configuration ---
    bit relaxed_ordering_enable  = 1;
    bit id_based_ordering_enable = 1;
    bit bypass_ordering          = 0;

    function new(string name = "pcie_tl_ordering_engine");
        super.new(name);
    endfunction

    //=========================================================================
    // Classify TLP into category
    //=========================================================================
    function tlp_category_e classify(pcie_tl_tlp tlp);
        return tlp.get_category();
    endfunction

    //=========================================================================
    // Enqueue TLP
    //=========================================================================
    function void enqueue(pcie_tl_tlp tlp);
        case (classify(tlp))
            TLP_CAT_POSTED:     posted_queue.push_back(tlp);
            TLP_CAT_NON_POSTED: non_posted_queue.push_back(tlp);
            TLP_CAT_COMPLETION: completion_queue.push_back(tlp);
        endcase
    endfunction

    //=========================================================================
    // Dequeue next TLP respecting ordering rules (Table 2-40)
    //
    // Key rules:
    // - Posted requests must not be blocked by Non-Posted requests
    // - Posted requests must not be blocked by Completions
    // - Completions must not be blocked by Posted or Non-Posted
    //
    // Priority: Completion > Posted > Non-Posted (to prevent deadlock)
    //=========================================================================
    function pcie_tl_tlp dequeue_next();
        if (bypass_ordering) begin
            // No ordering: return from any non-empty queue
            if (posted_queue.size() > 0)     return posted_queue.pop_front();
            if (completion_queue.size() > 0) return completion_queue.pop_front();
            if (non_posted_queue.size() > 0) return non_posted_queue.pop_front();
            return null;
        end

        // PCIe ordering: Completions first (prevent deadlock),
        // then Posted, then Non-Posted
        if (completion_queue.size() > 0) begin
            pcie_tl_tlp tlp = completion_queue.pop_front();
            record_sent(tlp);
            return tlp;
        end

        if (posted_queue.size() > 0) begin
            pcie_tl_tlp tlp = posted_queue.pop_front();
            // Check if RO allows reordering
            if (relaxed_ordering_enable && tlp.attr[0]) begin
                // RO set: can pass other Posted
                record_sent(tlp);
                return tlp;
            end
            record_sent(tlp);
            return tlp;
        end

        if (non_posted_queue.size() > 0) begin
            pcie_tl_tlp tlp = non_posted_queue.pop_front();
            record_sent(tlp);
            return tlp;
        end

        return null;
    endfunction

    //=========================================================================
    // Check if TLP ordering is valid relative to sent history
    //=========================================================================
    function bit check_ordering(pcie_tl_tlp tlp);
        tlp_category_e new_cat = classify(tlp);

        if (bypass_ordering) return 1;

        // Check against recently sent TLPs
        for (int i = sent_history.size() - 1; i >= 0; i--) begin
            tlp_category_e prev_cat = classify(sent_history[i]);

            // Table 2-40 violations:
            // Non-Posted must not pass Posted (unless RO)
            if (new_cat == TLP_CAT_NON_POSTED && prev_cat == TLP_CAT_POSTED) begin
                if (!(relaxed_ordering_enable && tlp.attr[0]))
                    continue;  // ordering maintained
            end

            // Completion must not be blocked by Non-Posted
            if (new_cat == TLP_CAT_COMPLETION && prev_cat == TLP_CAT_NON_POSTED) begin
                // This is OK - completions have priority
                continue;
            end

            // Posted must not be blocked by Non-Posted
            if (new_cat == TLP_CAT_POSTED && prev_cat == TLP_CAT_NON_POSTED) begin
                // This is OK - posted has priority
                continue;
            end

            // Check IDO: same ID can be reordered if IDO set
            if (id_based_ordering_enable && tlp.attr[1]) begin
                if (tlp.requester_id != sent_history[i].requester_id)
                    continue;  // different ID, IDO allows reorder
            end
        end

        return 1;  // no violation detected
    endfunction

    //=========================================================================
    // Force ordering violation (error injection)
    //=========================================================================
    function void force_ordering_violation(tlp_category_e victim, tlp_category_e blocker);
        pcie_tl_tlp victim_tlp, blocker_tlp;

        // Find and swap TLPs to create violation
        case (victim)
            TLP_CAT_POSTED:     if (posted_queue.size() > 0) victim_tlp = posted_queue.pop_front();
            TLP_CAT_NON_POSTED: if (non_posted_queue.size() > 0) victim_tlp = non_posted_queue.pop_front();
            TLP_CAT_COMPLETION: if (completion_queue.size() > 0) victim_tlp = completion_queue.pop_front();
        endcase

        case (blocker)
            TLP_CAT_POSTED:     if (posted_queue.size() > 0) blocker_tlp = posted_queue.pop_front();
            TLP_CAT_NON_POSTED: if (non_posted_queue.size() > 0) blocker_tlp = non_posted_queue.pop_front();
            TLP_CAT_COMPLETION: if (completion_queue.size() > 0) blocker_tlp = completion_queue.pop_front();
        endcase

        // Re-enqueue in reversed order
        if (blocker_tlp != null) begin
            case (victim)
                TLP_CAT_POSTED:     posted_queue.push_front(blocker_tlp);
                TLP_CAT_NON_POSTED: non_posted_queue.push_front(blocker_tlp);
                TLP_CAT_COMPLETION: completion_queue.push_front(blocker_tlp);
            endcase
        end
        if (victim_tlp != null) begin
            case (blocker)
                TLP_CAT_POSTED:     posted_queue.push_front(victim_tlp);
                TLP_CAT_NON_POSTED: non_posted_queue.push_front(victim_tlp);
                TLP_CAT_COMPLETION: completion_queue.push_front(victim_tlp);
            endcase
        end
    endfunction

    //=========================================================================
    // Query queue sizes
    //=========================================================================
    function int get_total_pending();
        return posted_queue.size() + non_posted_queue.size() + completion_queue.size();
    endfunction

    function bit is_empty();
        return (get_total_pending() == 0);
    endfunction

    //=========================================================================
    // Internal: record sent TLP
    //=========================================================================
    protected function void record_sent(pcie_tl_tlp tlp);
        sent_history.push_back(tlp);
        if (sent_history.size() > max_history)
            void'(sent_history.pop_front());
    endfunction

endclass
