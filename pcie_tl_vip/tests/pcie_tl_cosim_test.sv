// pcie_tl_cosim_test — cosim entry test.
// With +COSIM: cosim_maybe_enable() factory-overrides pcie_tl_rc_driver with
// cosim_xrc_driver, which polls QEMU over the bridge and drives TLPs into the
// VIP; the EP config_proxy answers config-space (SR-IOV cap, VF enable) so the
// guest can enumerate PF/VF. Without +COSIM this is a plain base test (no-op).
class pcie_tl_cosim_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_cosim_test)

    function new(string name = "pcie_tl_cosim_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        cfg.if_mode = TLM_MODE;            // cosim_xrc_driver feeds TLPs from QEMU
                                           // via TLM; no physical vif in standalone tb
        configure_tags(1, 0, 1024);        // extended 10-bit tags
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cosim_xrc_pkg::cosim_maybe_enable();  // +COSIM → override RC driver
    endfunction
endclass
