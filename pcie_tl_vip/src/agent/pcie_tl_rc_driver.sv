//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - RC Driver
//-----------------------------------------------------------------------------

class pcie_tl_rc_driver extends pcie_tl_base_driver;
    `uvm_component_utils(pcie_tl_rc_driver)

    //--- Completion timeout ---
    int  cpl_timeout_ns = 50000;  // 50us default

    //--- Outstanding requests awaiting completion ---
    pcie_tl_tlp pending_cpl[bit [9:0]];  // tag -> request

    //--- BAR allocation state ---
    bit [63:0] next_bar_addr = 64'h0000_0001_0000_0000;  // start at 4GB

    //--- Interrupt handling ---
    int  msi_received_count = 0;
    int  intx_asserted[4];  // INTA-INTD

    function new(string name = "pcie_tl_rc_driver", uvm_component parent = null);
        super.new(name, parent);
        foreach (intx_asserted[i]) intx_asserted[i] = 0;
    endfunction

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

        // Match with outstanding
        req = tag_mgr.match_completion(cpl);

        if (req == null) begin
            `uvm_warning("RC_DRV", $sformatf("Unexpected Completion: tag=0x%03h req_id=0x%04h",
                                              cpl.tag, cpl.requester_id))
            return 0;
        end

        // Remove from pending
        if (pending_cpl.exists(cpl.tag))
            pending_cpl.delete(cpl.tag);

        // Free tag
        tag_mgr.free_tag(cpl.tag, cpl.requester_id[2:0]);

        `uvm_info("RC_DRV", $sformatf("Completion matched: tag=0x%03h status=%s",
                                       cpl.tag, cpl.cpl_status.name()), UVM_MEDIUM)
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
