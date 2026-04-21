//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Base Monitor
//-----------------------------------------------------------------------------

class pcie_tl_base_monitor extends uvm_monitor;
    `uvm_component_utils(pcie_tl_base_monitor)

    //--- Analysis ports ---
    uvm_analysis_port #(pcie_tl_tlp) tlp_ap;
    uvm_analysis_port #(pcie_tl_tlp) err_ap;

    //--- Shared component references ---
    pcie_tl_codec              codec;
    pcie_tl_fc_manager         fc_mgr;
    pcie_tl_tag_manager        tag_mgr;
    pcie_tl_ordering_engine    ord_eng;

    //--- Adapter reference ---
    pcie_tl_if_adapter         adapter;

    //--- Protocol check switches ---
    bit ordering_check_enable   = 1;
    bit fc_check_enable         = 1;
    bit tag_check_enable        = 1;
    bit tlp_format_check_enable = 1;
    bit boundary_4kb_check_enable = 1;
    bit byte_enable_check_enable  = 1;

    //--- Coverage callbacks ---
    pcie_tl_coverage_callback  cov_callbacks[$];

    function new(string name = "pcie_tl_base_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        tlp_ap = new("tlp_ap", this);
        err_ap = new("err_ap", this);
    endfunction

    //=========================================================================
    // Main monitoring loop
    //=========================================================================
    task run_phase(uvm_phase phase);
        forever begin
            monitor_tlp();
        end
    endtask

    //=========================================================================
    // Monitor a single TLP
    //=========================================================================
    virtual task monitor_tlp();
        pcie_tl_tlp tlp;
        bit has_error = 0;

        // Receive from adapter
        adapter.receive(tlp);

        if (tlp == null) begin
            #1ns;
            return;
        end

        // Protocol checks
        if (tlp_format_check_enable)
            has_error |= !check_tlp_format(tlp);
        if (fc_check_enable && fc_mgr != null)
            has_error |= !check_fc_compliance(tlp);
        if (tag_check_enable && tag_mgr != null)
            has_error |= !check_tag_validity(tlp);
        if (ordering_check_enable && ord_eng != null)
            has_error |= !check_ordering_compliance(tlp);
        if (boundary_4kb_check_enable)
            has_error |= !check_4kb_boundary(tlp);
        if (byte_enable_check_enable)
            has_error |= !check_byte_enables(tlp);

        // Broadcast
        tlp_ap.write(tlp);
        if (has_error)
            err_ap.write(tlp);

        // Coverage callbacks
        foreach (cov_callbacks[i])
            cov_callbacks[i].sample(tlp);

        `uvm_info(get_name(), $sformatf("Monitored TLP: %s%s",
                  tlp.convert2string(), has_error ? " [ERROR]" : ""), UVM_HIGH)
    endtask

    //=========================================================================
    // Protocol checkers
    //=========================================================================
    virtual function bit check_tlp_format(pcie_tl_tlp tlp);
        // Check fmt and type consistency
        if (tlp.has_data() && tlp.payload.size() == 0) begin
            `uvm_warning(get_name(), $sformatf("TLP fmt indicates data but payload is empty: %s", tlp.convert2string()))
            return 0;
        end
        if (!tlp.has_data() && tlp.payload.size() > 0) begin
            `uvm_warning(get_name(), $sformatf("TLP fmt indicates no data but payload present: %s", tlp.convert2string()))
            return 0;
        end
        return 1;
    endfunction

    virtual function bit check_fc_compliance(pcie_tl_tlp tlp);
        // Verify FC credit was available
        return fc_mgr.check_credit(tlp);
    endfunction

    virtual function bit check_tag_validity(pcie_tl_tlp tlp);
        // For Non-Posted: check tag is not duplicate (skip self-registered tags)
        if (tlp.requires_completion()) begin
            if (tag_mgr.is_duplicate(tlp.tag)) begin
                // If the outstanding TLP is the same object, it's not a real duplicate
                if (tag_mgr.outstanding_txn[tlp.tag] != tlp) begin
                    `uvm_warning(get_name(), $sformatf("Duplicate tag detected: 0x%03h", tlp.tag))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    virtual function bit check_ordering_compliance(pcie_tl_tlp tlp);
        return ord_eng.check_ordering(tlp);
    endfunction

    //=========================================================================
    // 4KB boundary check: TLP must not cross a 4KB address boundary
    //=========================================================================
    virtual function bit check_4kb_boundary(pcie_tl_tlp tlp);
        pcie_tl_mem_tlp mem;
        int byte_len;
        bit [63:0] start_addr, end_addr;

        if (!$cast(mem, tlp)) return 1;  // not a mem TLP, skip

        byte_len = (tlp.length == 0) ? 4096 : tlp.length * 4;
        start_addr = mem.addr;
        end_addr   = start_addr + byte_len - 1;

        if (start_addr[63:12] != end_addr[63:12]) begin
            `uvm_warning(get_name(), $sformatf(
                "4KB boundary crossing: addr=0x%016h len=%0d bytes, start_page=0x%h end_page=0x%h",
                start_addr, byte_len, start_addr[63:12], end_addr[63:12]))
            return 0;
        end
        return 1;
    endfunction

    //=========================================================================
    // Byte enable check: validate first_be/last_be per PCIe rules
    //=========================================================================
    virtual function bit check_byte_enables(pcie_tl_tlp tlp);
        pcie_tl_mem_tlp mem;

        if (!$cast(mem, tlp)) return 1;  // not a mem TLP, skip

        if (tlp.length == 1) begin
            if (mem.last_be != 0) begin
                `uvm_warning(get_name(), $sformatf(
                    "Byte enable error: length=1 but last_be=0x%01h (expected 0)",
                    mem.last_be))
                return 0;
            end
            if (mem.first_be == 0) begin
                `uvm_warning(get_name(), "Byte enable error: length=1 but first_be=0")
                return 0;
            end
        end
        if (tlp.length >= 2) begin
            if (mem.first_be == 0) begin
                `uvm_warning(get_name(), "Byte enable error: length>=2 but first_be=0")
                return 0;
            end
            if (mem.last_be == 0) begin
                `uvm_warning(get_name(), $sformatf(
                    "Byte enable error: length=%0d but last_be=0", tlp.length))
                return 0;
            end
        end
        return 1;
    endfunction

    //=========================================================================
    // Coverage callback registration
    //=========================================================================
    function void register_coverage_callback(pcie_tl_coverage_callback cb);
        cov_callbacks.push_back(cb);
    endfunction

endclass
