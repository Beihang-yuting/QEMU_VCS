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

    function new(string name = "pcie_tl_base_driver", uvm_component parent = null);
        super.new(name, parent);
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
