class axis_bandwidth_checker #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_subscriber #(axis_transfer);

    `uvm_component_param_utils(axis_bandwidth_checker#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    typedef axis_coverage_collector #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) cov_t;
    vif_t vif;
    axis_config cfg;
    cov_t cov_collector;

    protected int unsigned bytes_in_window;
    protected int unsigned cycle_counter;
    protected real         current_bw;
    protected real bw_history[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    function void write(axis_transfer t);
        if (!cfg.bw_check_enable) return;
        for (int i = 0; i < cfg.get_byte_lanes(); i++) begin
            if (t.tkeep[i])
                bytes_in_window++;
        end
    endfunction

    task run_phase(uvm_phase phase);
        bit lvl = (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) ? 1'b0 : 1'b1;
        if (!cfg.bw_check_enable) return;
        forever begin
            @(posedge vif.aclk);
            // Drop the window across reset so reset cycles don't dilute the
            // measured bandwidth (which could otherwise trip a false BW_MIN).
            if (vif.aresetn === lvl) begin
                bytes_in_window = 0;
                cycle_counter   = 0;
                continue;
            end
            cycle_counter++;
            if (cycle_counter >= cfg.bw_window_cycles) begin
                evaluate_window();
                bytes_in_window = 0;
                cycle_counter = 0;
            end
        end
    endtask

    protected function void evaluate_window();
        real min_thresh, max_thresh;
        current_bw = real'(bytes_in_window) / real'(cfg.bw_window_cycles);
        bw_history.push_back(current_bw);
        get_current_thresholds(min_thresh, max_thresh);

        `uvm_info(get_type_name(),
            $sformatf("BW window: %0d bytes / %0d cycles = %.4f bytes/cycle [min=%.4f, max=%.4f]",
                      bytes_in_window, cfg.bw_window_cycles, current_bw, min_thresh, max_thresh),
            UVM_MEDIUM)

        if (current_bw < min_thresh) begin
            `uvm_error("BW_MIN_VIOLATION",
                $sformatf("Bandwidth %.4f below minimum threshold %.4f", current_bw, min_thresh))
        end
        if (max_thresh >= 0 && current_bw > max_thresh) begin
            `uvm_error("BW_MAX_VIOLATION",
                $sformatf("Bandwidth %.4f above maximum threshold %.4f", current_bw, max_thresh))
        end
        if (cov_collector != null)
            cov_collector.sample_bandwidth(current_bw);
    endfunction

    protected function void get_current_thresholds(output real min_thresh, output real max_thresh);
        int unsigned total_cycles;
        total_cycles = bw_history.size() * cfg.bw_window_cycles + cycle_counter;
        foreach (cfg.bw_profile[i]) begin
            if (total_cycles >= cfg.bw_profile[i].start_cycle &&
                total_cycles <= cfg.bw_profile[i].end_cycle) begin
                min_thresh = cfg.bw_profile[i].min_threshold;
                max_thresh = cfg.bw_profile[i].max_threshold;
                return;
            end
        end
        min_thresh = cfg.bw_min_threshold;
        max_thresh = cfg.bw_max_threshold;
    endfunction

    function void report_phase(uvm_phase phase);
        real total_bw;
        real min_bw;
        real max_bw;

        if (!cfg.bw_check_enable || bw_history.size() == 0) return;

        total_bw = 0;
        min_bw = bw_history[0];
        max_bw = bw_history[0];
        foreach (bw_history[i]) begin
            total_bw += bw_history[i];
            if (bw_history[i] < min_bw) min_bw = bw_history[i];
            if (bw_history[i] > max_bw) max_bw = bw_history[i];
        end
        `uvm_info(get_type_name(),
            $sformatf("BW summary: avg=%.4f, min=%.4f, max=%.4f over %0d windows",
                      total_bw / bw_history.size(), min_bw, max_bw, bw_history.size()),
            UVM_LOW)
    endfunction

endclass
