class axis_bandwidth_controller extends uvm_component;

    `uvm_component_utils(axis_bandwidth_controller)

    axis_config cfg;

    protected int unsigned cycle_count;
    protected int unsigned burst_beat_count;
    protected bit          in_pause;
    protected int unsigned pause_count;
    protected int unsigned toggle_count;
    protected bit          toggle_state;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        reset_state();
    endfunction

    function void reset_state();
        cycle_count      = 0;
        burst_beat_count = 0;
        in_pause         = 0;
        pause_count      = 0;
        toggle_count     = 0;
        toggle_state     = 1;
    endfunction

    // Master side: idle cycles after handshake
    function int unsigned get_valid_idle_cycles();
        case (cfg.valid_gen_mode)
            VALID_ZERO_IDLE:   return 0;
            VALID_FIXED_IDLE:  return cfg.idle_cycles;
            VALID_RANDOM_IDLE: return $urandom_range(cfg.idle_min, cfg.idle_max);
            VALID_WEIGHTED:    return 0;
            VALID_BURST_PAUSE: return 0;
            VALID_PROFILE:     return get_profile_valid_idle_cycles();
            default:           return 0;
        endcase
    endfunction

    // For WEIGHTED/BURST_PAUSE: should valid be driven this cycle?
    function bit should_assert_valid();
        cycle_count++;
        case (cfg.valid_gen_mode)
            VALID_WEIGHTED: begin
                return ($urandom_range(0, 99) < cfg.valid_weight);
            end
            VALID_BURST_PAUSE: begin
                if (!in_pause) begin
                    burst_beat_count++;
                    if (burst_beat_count >= cfg.burst_len) begin
                        in_pause = 1;
                        burst_beat_count = 0;
                        pause_count = 0;
                    end
                    return 1;
                end else begin
                    pause_count++;
                    if (pause_count >= cfg.pause_len) begin
                        in_pause = 0;
                        pause_count = 0;
                    end
                    return 0;
                end
            end
            VALID_PROFILE: return get_profile_should_assert_valid();
            default: return 1;
        endcase
    endfunction

    // Slave side: should TREADY be asserted?
    function bit should_assert_ready(bit tvalid_seen);
        cycle_count++;
        case (cfg.ready_gen_mode)
            READY_ALWAYS:       return 1;
            READY_BEFORE_VALID: return 1;
            READY_WITH_VALID:   return tvalid_seen;
            READY_AFTER_VALID:  return 0;
            READY_WEIGHTED:     return ($urandom_range(0, 99) < cfg.ready_weight);
            READY_TOGGLE: begin
                toggle_count++;
                if (toggle_state && toggle_count >= cfg.ready_high) begin
                    toggle_state = 0;
                    toggle_count = 0;
                end else if (!toggle_state && toggle_count >= cfg.ready_low) begin
                    toggle_state = 1;
                    toggle_count = 0;
                end
                return toggle_state;
            end
            READY_PROFILE: return get_profile_should_assert_ready(tvalid_seen);
            default: return 1;
        endcase
    endfunction

    function int unsigned get_ready_delay();
        if (cfg.ready_delay_min == cfg.ready_delay_max)
            return cfg.ready_delay;
        return $urandom_range(cfg.ready_delay_min, cfg.ready_delay_max);
    endfunction

    // Profile helpers
    protected function axis_valid_profile_entry_t get_current_valid_profile();
        foreach (cfg.valid_profile[i]) begin
            if (cycle_count >= cfg.valid_profile[i].start_cycle &&
                cycle_count <= cfg.valid_profile[i].end_cycle)
                return cfg.valid_profile[i];
        end
        return '{start_cycle: 0, end_cycle: '1, mode: VALID_ZERO_IDLE,
                 idle_cycles: 0, idle_min: 0, idle_max: 0,
                 valid_weight: 100, burst_len: 8, pause_len: 4};
    endfunction

    protected function int unsigned get_profile_valid_idle_cycles();
        axis_valid_profile_entry_t entry = get_current_valid_profile();
        case (entry.mode)
            VALID_ZERO_IDLE:   return 0;
            VALID_FIXED_IDLE:  return entry.idle_cycles;
            VALID_RANDOM_IDLE: return $urandom_range(entry.idle_min, entry.idle_max);
            default:           return 0;
        endcase
    endfunction

    protected function bit get_profile_should_assert_valid();
        axis_valid_profile_entry_t entry = get_current_valid_profile();
        case (entry.mode)
            VALID_WEIGHTED: return ($urandom_range(0, 99) < entry.valid_weight);
            default:        return 1;
        endcase
    endfunction

    protected function axis_ready_profile_entry_t get_current_ready_profile();
        foreach (cfg.ready_profile[i]) begin
            if (cycle_count >= cfg.ready_profile[i].start_cycle &&
                cycle_count <= cfg.ready_profile[i].end_cycle)
                return cfg.ready_profile[i];
        end
        return '{start_cycle: 0, end_cycle: '1, mode: READY_ALWAYS,
                 ready_delay: 0, ready_delay_min: 0, ready_delay_max: 0,
                 ready_advance_cycles: 1, ready_weight: 100,
                 ready_high: 4, ready_low: 2};
    endfunction

    protected function bit get_profile_should_assert_ready(bit tvalid_seen);
        axis_ready_profile_entry_t entry = get_current_ready_profile();
        case (entry.mode)
            READY_ALWAYS:       return 1;
            READY_BEFORE_VALID: return 1;
            READY_WITH_VALID:   return tvalid_seen;
            READY_WEIGHTED:     return ($urandom_range(0, 99) < entry.ready_weight);
            READY_TOGGLE:       return toggle_state;
            default: return 1;
        endcase
    endfunction

endclass
