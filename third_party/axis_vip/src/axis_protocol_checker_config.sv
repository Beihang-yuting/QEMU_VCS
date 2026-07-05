class axis_protocol_checker_config extends uvm_object;

    `uvm_object_utils(axis_protocol_checker_config)

    bit enable_all = 1;

    bit enable_tvalid_stability    = 1;
    bit enable_tdata_stability     = 1;
    bit enable_tlast_integrity     = 1;
    bit enable_tid_consistency     = 1;
    bit enable_tdest_consistency   = 1;
    bit enable_tkeep_tstrb_relation = 1;
    bit enable_reset_signal_check  = 1;
    bit enable_x_z_check           = 1;
    bit enable_handshake_timeout   = 1;

    axis_severity_e sev_tvalid_stability    = AXIS_SEV_ERROR;
    axis_severity_e sev_tdata_stability     = AXIS_SEV_ERROR;
    axis_severity_e sev_tlast_integrity     = AXIS_SEV_ERROR;
    axis_severity_e sev_tid_consistency     = AXIS_SEV_ERROR;
    axis_severity_e sev_tdest_consistency   = AXIS_SEV_ERROR;
    axis_severity_e sev_tkeep_tstrb_relation = AXIS_SEV_ERROR;
    axis_severity_e sev_reset_signal_check  = AXIS_SEV_ERROR;
    axis_severity_e sev_x_z_check           = AXIS_SEV_ERROR;
    axis_severity_e sev_handshake_timeout   = AXIS_SEV_WARNING;

    int unsigned handshake_timeout_cycles = 1000;

    function new(string name = "axis_protocol_checker_config");
        super.new(name);
    endfunction

    function void disable_all();
        enable_all = 0;
    endfunction

    function void set_enable_all();
        enable_all = 1;
        enable_tvalid_stability     = 1;
        enable_tdata_stability      = 1;
        enable_tlast_integrity      = 1;
        enable_tid_consistency      = 1;
        enable_tdest_consistency    = 1;
        enable_tkeep_tstrb_relation = 1;
        enable_reset_signal_check   = 1;
        enable_x_z_check            = 1;
        enable_handshake_timeout    = 1;
    endfunction

endclass
