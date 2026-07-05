class axis_protocol_checker #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_component;

    `uvm_component_param_utils(axis_protocol_checker#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    vif_t vif;
    axis_config cfg;
    axis_protocol_checker_config checker_cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
        checker_cfg = cfg.checker_cfg;
    endfunction

    // Push enable flags to interface wires so the SVA module can read them
    function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        apply_config();
    endfunction

    // Watch for runtime config changes and update enables
    task run_phase(uvm_phase phase);
        forever begin
            cfg.config_changed.wait_trigger();
            apply_config();
            `uvm_info(get_type_name(), "Protocol checker config updated", UVM_MEDIUM)
        end
    endtask

    protected function void apply_config();
        vif.chk_en_tvalid_stability     = checker_cfg.enable_all & checker_cfg.enable_tvalid_stability;
        vif.chk_en_tdata_stability      = checker_cfg.enable_all & checker_cfg.enable_tdata_stability;
        vif.chk_en_tlast_integrity      = checker_cfg.enable_all & checker_cfg.enable_tlast_integrity;
        vif.chk_en_tid_consistency      = checker_cfg.enable_all & checker_cfg.enable_tid_consistency;
        vif.chk_en_tdest_consistency    = checker_cfg.enable_all & checker_cfg.enable_tdest_consistency;
        vif.chk_en_tkeep_tstrb_relation = checker_cfg.enable_all & checker_cfg.enable_tkeep_tstrb_relation;
        vif.chk_en_reset_signal_check   = checker_cfg.enable_all & checker_cfg.enable_reset_signal_check;
        vif.chk_en_x_z_check            = checker_cfg.enable_all & checker_cfg.enable_x_z_check;
        vif.chk_en_handshake_timeout    = checker_cfg.enable_all & checker_cfg.enable_handshake_timeout;
        vif.chk_handshake_timeout_cycles = checker_cfg.handshake_timeout_cycles;
    endfunction

endclass
