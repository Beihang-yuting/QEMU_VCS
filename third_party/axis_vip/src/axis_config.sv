class axis_config extends uvm_object;

    `uvm_object_utils(axis_config)

    // Protocol parameters (static)
    int unsigned TDATA_WIDTH = 32;
    int unsigned TID_WIDTH   = 4;
    int unsigned TDEST_WIDTH = 4;
    int unsigned TUSER_WIDTH = 1;
    bit          HAS_TSTRB   = 1;
    bit          HAS_TKEEP   = 1;
    bit          HAS_TLAST   = 1;

    // Agent mode
    axis_agent_mode_e   agent_mode = AXIS_MASTER;
    uvm_active_passive_enum is_active = UVM_ACTIVE;

    // Master valid generation strategy
    axis_valid_gen_mode_e   valid_gen_mode  = VALID_ZERO_IDLE;
    int unsigned            idle_cycles     = 0;
    int unsigned            idle_min        = 0;
    int unsigned            idle_max        = 5;
    int unsigned            valid_weight    = 80;
    int unsigned            burst_len       = 8;
    int unsigned            pause_len       = 4;
    axis_valid_profile_entry_t valid_profile[$];

    // Slave ready generation strategy
    axis_ready_gen_mode_e   ready_gen_mode       = READY_ALWAYS;
    int unsigned            ready_delay          = 0;
    int unsigned            ready_delay_min      = 0;
    int unsigned            ready_delay_max      = 5;
    int unsigned            ready_advance_cycles = 1;
    int unsigned            ready_weight         = 60;
    int unsigned            ready_high           = 4;
    int unsigned            ready_low            = 2;
    axis_ready_profile_entry_t ready_profile[$];

    // Bandwidth configuration
    bit          bw_check_enable   = 0;
    int unsigned bw_window_cycles  = 1000;
    real         bw_min_threshold  = 0.0;
    real         bw_max_threshold  = -1.0;
    axis_bw_profile_entry_t bw_profile[$];

    // Reset configuration
    axis_reset_polarity_e   reset_polarity  = AXIS_RESET_ACTIVE_LOW;
    axis_reset_sync_mode_e  reset_sync_mode = AXIS_RESET_SYNC;
    bit                     hot_reset_enable = 0;

    // Packet boundary configuration (for HAS_TLAST=0)
    axis_pkt_boundary_mode_e pkt_boundary_mode       = PKT_BOUNDARY_TLAST;
    int unsigned             pkt_boundary_timeout_cycles = 100;
    int unsigned             pkt_boundary_fixed_length   = 64;

    // Slave driver mode
    axis_slave_drive_mode_e  slave_drive_mode = SLAVE_AUTO;

    // Protocol checker config
    axis_protocol_checker_config checker_cfg;

    // Runtime reconfiguration event
    uvm_event config_changed;

    function new(string name = "axis_config");
        super.new(name);
        config_changed = new("config_changed");
        checker_cfg = axis_protocol_checker_config::type_id::create("checker_cfg");
    endfunction

    function int unsigned get_byte_lanes();
        return TDATA_WIDTH / 8;
    endfunction

    function void notify_config_changed();
        config_changed.trigger();
    endfunction

endclass
