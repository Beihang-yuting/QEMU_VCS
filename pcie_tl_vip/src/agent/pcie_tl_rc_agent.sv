//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - RC Agent
//-----------------------------------------------------------------------------

class pcie_tl_rc_agent extends pcie_tl_base_agent;
    `uvm_component_utils(pcie_tl_rc_agent)

    //--- Override with RC-specific driver ---
    pcie_tl_rc_driver  rc_driver;

    function new(string name = "pcie_tl_rc_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        // Use instance override (not global type override) to avoid conflicts
        if (get_is_active() == UVM_ACTIVE) begin
            pcie_tl_base_driver::type_id::set_inst_override(
                pcie_tl_rc_driver::get_type(), "driver", this);
        end

        super.build_phase(phase);

        // Get RC driver reference
        if (get_is_active() == UVM_ACTIVE)
            $cast(rc_driver, driver);
    endfunction

endclass
