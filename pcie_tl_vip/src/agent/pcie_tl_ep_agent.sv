//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - EP Agent
//-----------------------------------------------------------------------------

class pcie_tl_ep_agent extends pcie_tl_base_agent;
    `uvm_component_utils(pcie_tl_ep_agent)

    //--- Override with EP-specific driver ---
    pcie_tl_ep_driver  ep_driver;

    //--- Function Manager (set by env when sriov_enable=1) ---
    pcie_tl_func_manager  func_manager;

    //--- Config Space Bypass Proxy (默认开启，+BYPASS_CONFIG=0 关闭) ---
    pcie_tl_config_proxy  config_proxy;

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

        // Config proxy（默认创建，通过 +BYPASS_CONFIG=0 关闭）
        config_proxy = pcie_tl_config_proxy::type_id::create("config_proxy", this);

        if (get_is_active() == UVM_ACTIVE) begin
            $cast(ep_driver, driver);
            if (func_manager != null)
                ep_driver.func_manager = func_manager;
            ep_driver.config_proxy = config_proxy;
        end
    endfunction

endclass
