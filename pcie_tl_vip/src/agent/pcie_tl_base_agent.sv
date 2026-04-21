//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Base Agent
//-----------------------------------------------------------------------------

class pcie_tl_base_agent extends uvm_agent;
    `uvm_component_utils(pcie_tl_base_agent)

    //--- Sub-components ---
    pcie_tl_base_driver              driver;
    pcie_tl_base_monitor             monitor;
    uvm_sequencer #(pcie_tl_tlp)     sequencer;

    //--- Shared component references (set by env) ---
    pcie_tl_fc_manager         fc_mgr;
    pcie_tl_tag_manager        tag_mgr;
    pcie_tl_ordering_engine    ord_eng;
    pcie_tl_cfg_space_manager  cfg_mgr;
    pcie_tl_bw_shaper          bw_shaper;
    pcie_tl_codec              codec;

    //--- Adapter ---
    pcie_tl_if_adapter         adapter;

    function new(string name = "pcie_tl_base_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        monitor = pcie_tl_base_monitor::type_id::create("monitor", this);

        if (get_is_active() == UVM_ACTIVE) begin
            driver    = pcie_tl_base_driver::type_id::create("driver", this);
            sequencer = uvm_sequencer#(pcie_tl_tlp)::type_id::create("sequencer", this);
        end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Connect driver to sequencer
        if (get_is_active() == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
        end

        // Inject shared components
        inject_shared_components();
    endfunction

    //=========================================================================
    // Inject shared component references into driver and monitor
    //=========================================================================
    virtual function void inject_shared_components();
        monitor.codec   = codec;
        monitor.fc_mgr  = fc_mgr;
        monitor.tag_mgr = tag_mgr;
        monitor.ord_eng = ord_eng;
        monitor.adapter = adapter;

        if (get_is_active() == UVM_ACTIVE) begin
            driver.fc_mgr    = fc_mgr;
            driver.tag_mgr   = tag_mgr;
            driver.ord_eng   = ord_eng;
            driver.cfg_mgr   = cfg_mgr;
            driver.bw_shaper = bw_shaper;
            driver.codec     = codec;
            driver.adapter   = adapter;
        end
    endfunction

endclass
