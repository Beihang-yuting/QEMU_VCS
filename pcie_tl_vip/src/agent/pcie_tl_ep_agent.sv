//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - EP Agent
//-----------------------------------------------------------------------------

class pcie_tl_ep_agent extends pcie_tl_base_agent;
    `uvm_component_utils(pcie_tl_ep_agent)

    //--- Override with EP-specific driver ---
    pcie_tl_ep_driver  ep_driver;

    //--- Function Manager (set by env when sriov_enable=1) ---
    pcie_tl_func_manager  func_manager;

    function new(string name = "pcie_tl_ep_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        // Use instance override (not global type override) to avoid conflicts
        if (get_is_active() == UVM_ACTIVE) begin
            pcie_tl_base_driver::type_id::set_inst_override(
                pcie_tl_ep_driver::get_type(), "driver", this);
        end

        super.build_phase(phase);

        if (get_is_active() == UVM_ACTIVE) begin
            $cast(ep_driver, driver);
            if (func_manager != null)
                ep_driver.func_manager = func_manager;
        end
    endfunction

endclass
