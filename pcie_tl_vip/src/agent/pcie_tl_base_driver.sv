//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Base Driver
//-----------------------------------------------------------------------------

class pcie_tl_base_driver extends uvm_driver #(pcie_tl_tlp);
    `uvm_component_utils(pcie_tl_base_driver)

    //--- Shared component references (injected by agent) ---
    pcie_tl_fc_manager         fc_mgr;
    pcie_tl_tag_manager        tag_mgr;
    pcie_tl_ordering_engine    ord_eng;
    pcie_tl_cfg_space_manager  cfg_mgr;
    pcie_tl_bw_shaper          bw_shaper;
    pcie_tl_codec              codec;

    //--- Adapter reference ---
    pcie_tl_if_adapter         adapter;

    //--- Read-back capture (private outstanding map, independent of the shared
    //--- tag_mgr which env may free early). Maps tag -> requesting TLP handle
    //--- so returning Completions can be written back onto the seq's object. ---
    protected pcie_tl_tlp      rb_outstanding[bit [9:0]];
    protected int              rb_recv[bit [9:0]];   // bytes received per tag
    protected int              rb_total[bit [9:0]];  // expected bytes per tag

    function new(string name = "pcie_tl_base_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Called synchronously after a non-posted request receives its VIP tag and
    // before any ordering/flow-control wait or adapter send. Derived bridges
    // can publish an external-to-VIP tag mapping without racing a fast DUT
    // Completion. The base implementation intentionally does nothing.
    virtual function void on_tag_assigned(pcie_tl_tlp tlp);
    endfunction

    //=========================================================================
    // Main run phase
    //=========================================================================
    task run_phase(uvm_phase phase);
        pcie_tl_tlp tlp;
        forever begin
            seq_item_port.get_next_item(tlp);
            send_tlp(tlp);
            seq_item_port.item_done();
        end
    endtask

    //=========================================================================
    // Core send pipeline (virtual - overridden by RC/EP)
    //=========================================================================
    virtual task send_tlp(pcie_tl_tlp tlp);
        bit [7:0] bytes[];

        // 1. Tag allocation (Non-Posted only)
        if (tlp.requires_completion()) begin
            bit [9:0] t = tag_mgr.alloc_tag(tlp.requester_id[2:0]);
            tlp.tag = t;
            tag_mgr.register_outstanding(t, tlp);
            // Register for read-back capture (private map, keyed by tag).
            tlp.rb_done = 0;
            tlp.rb_data = {};
            tlp.rb_status = CPL_STATUS_SC;
            rb_outstanding[t] = tlp;
            // Global registry for SV_IF/adapter mode, where the monitor (not the
            // env/driver completion path) folds the returning CplD.
            pcie_rb_registry::register(tlp);
            on_tag_assigned(tlp);
        end

        // 2. Ordering engine enqueue + wait
        if (ord_eng != null && !tlp.violate_ordering) begin
            ord_eng.enqueue(tlp);
        end

        // 3. Wait for send permission (FC + BW)
        wait_for_send_permission(tlp);

        // 4. Encode
        codec.encode(tlp, bytes);

        // 5. Send via adapter
        adapter.send(tlp);

        // 6. Consume FC credit
        if (fc_mgr != null)
            fc_mgr.consume_credit(tlp);

        // 7. Consume BW tokens
        if (bw_shaper != null)
            bw_shaper.on_sent(bytes.size());

        `uvm_info(get_name(), $sformatf("Sent TLP: %s", tlp.convert2string()), UVM_HIGH)
    endtask

    //=========================================================================
    // Read-back capture: fold one returning Completion into its request object.
    // Called by RC/EP driver completion handlers. Accumulates CplD payload onto
    // the original request TLP (the same handle the sequence holds), and sets
    // rb_done once all requested bytes have arrived or an error status is seen.
    //=========================================================================
    function void rb_note_completion(pcie_tl_cpl_tlp cpl);
        pcie_tl_tlp req;
        bit last;
        if (!rb_outstanding.exists(cpl.tag)) return;   // not a request we track
        req = rb_outstanding[cpl.tag];
        if (!rb_total.exists(cpl.tag)) begin
            rb_total[cpl.tag] = (req.length == 0) ? 4096 : req.length * 4;
            rb_recv[cpl.tag]  = 0;
        end
        foreach (cpl.payload[i]) req.rb_data.push_back(cpl.payload[i]);
        rb_recv[cpl.tag] += cpl.payload.size();
        if (cpl.cpl_status != CPL_STATUS_SC) req.rb_status = cpl.cpl_status;
        // Error status terminates immediately (no data will follow).
        last = (rb_recv[cpl.tag] >= rb_total[cpl.tag]) ||
               (cpl.cpl_status != CPL_STATUS_SC);
        if (last) begin
            req.rb_done = 1;
            rb_outstanding.delete(cpl.tag);
            rb_recv.delete(cpl.tag);
            rb_total.delete(cpl.tag);
        end
    endfunction

    //=========================================================================
    // Wait for FC credit and BW shaper permission
    //=========================================================================
    virtual task wait_for_send_permission(pcie_tl_tlp tlp);
        // Wait for FC credit
        if (fc_mgr != null) begin
            while (!fc_mgr.check_credit(tlp)) begin
                `uvm_info(get_name(), "Waiting for FC credit...", UVM_DEBUG)
                #1ns;
            end
        end

        // Wait for BW shaper tokens
        if (bw_shaper != null) begin
            int bytes_needed = tlp.get_data_credits() * 4 + (tlp.is_4dw() ? 16 : 12);
            while (!bw_shaper.can_send(bytes_needed)) begin
                `uvm_info(get_name(), "Waiting for BW shaper tokens...", UVM_DEBUG)
                #1ns;
            end
        end
    endtask

endclass
