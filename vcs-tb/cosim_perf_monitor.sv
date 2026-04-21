//-----------------------------------------------------------------------------
// PCIe Cosim Platform - Performance Monitor
//
// Subscribes to the pcie_tl_env monitor's analysis_port and collects:
//   - Throughput statistics (TLP/s, MB/s, per-kind counts/bytes)
//   - Latency statistics for Non-Posted TLPs (min/avg/p50/p90/p99/max)
//   - Tag utilization (outstanding, peak, alloc, free, timeouts)
//   - Stability counters (scoreboard mismatch, unknown TLP, FC/ordering violations)
//
// Enabled only when COSIM_PERF_EN is defined at compile time.
//-----------------------------------------------------------------------------

`ifdef COSIM_PERF_EN

class cosim_perf_monitor extends uvm_subscriber #(pcie_tl_tlp);
    `uvm_component_utils(cosim_perf_monitor)

    //=========================================================================
    // Tunable parameters
    //=========================================================================

    // Timeout threshold for outstanding Non-Posted TLPs (in simulation time units)
    realtime tag_timeout_threshold = 10000ns;

    //=========================================================================
    // Throughput statistics
    //=========================================================================

    longint unsigned total_tlp_count;
    longint unsigned total_bytes;

    // Per-kind counters (associative array keyed by tlp_kind_e)
    longint unsigned kind_count[tlp_kind_e];
    longint unsigned kind_bytes[tlp_kind_e];

    // Per-category counters
    longint unsigned cat_count[tlp_category_e];
    longint unsigned cat_bytes[tlp_category_e];

    // Rolling window for TLP/s and MB/s computation
    localparam int WINDOW_SIZE = 1024;
    realtime   ts_window    [WINDOW_SIZE];
    longint    bytes_window [WINDOW_SIZE];
    int        win_head;
    int        win_count;

    //=========================================================================
    // Latency statistics (Non-Posted TLPs only)
    //=========================================================================

    // Pending request table: tag -> send timestamp
    realtime   pending_ts[bit [9:0]];

    // Collected latency samples (simulation time units)
    real       latency_samples[$];

    // Running stats (updated on each completion)
    longint unsigned lat_count;
    real             lat_sum;
    real             lat_min;
    real             lat_max;

    //=========================================================================
    // Tag utilization
    //=========================================================================

    // Set of currently outstanding tags
    bit          outstanding_tags[bit [9:0]];
    int unsigned cur_outstanding;
    int unsigned peak_outstanding;
    longint unsigned total_tag_alloc;
    longint unsigned total_tag_free;
    longint unsigned total_tag_timeout;

    //=========================================================================
    // Stability counters
    //=========================================================================

    longint unsigned scoreboard_mismatch_count;
    longint unsigned unknown_tlp_count;
    longint unsigned fc_violation_count;
    longint unsigned ordering_violation_count;

    //=========================================================================
    // Simulation start time (for rate calculations)
    //=========================================================================

    realtime sim_start_time;

    //=========================================================================
    // Constructor
    //=========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    //=========================================================================
    // build_phase
    //=========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        total_tlp_count          = 0;
        total_bytes              = 0;
        win_head                 = 0;
        win_count                = 0;
        lat_count                = 0;
        lat_sum                  = 0.0;
        lat_min                  = 1e38;
        lat_max                  = 0.0;
        cur_outstanding          = 0;
        peak_outstanding         = 0;
        total_tag_alloc          = 0;
        total_tag_free           = 0;
        total_tag_timeout        = 0;
        scoreboard_mismatch_count   = 0;
        unknown_tlp_count           = 0;
        fc_violation_count          = 0;
        ordering_violation_count    = 0;
    endfunction

    //=========================================================================
    // start_of_simulation_phase
    //=========================================================================

    virtual function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        sim_start_time = $realtime;
    endfunction

    //=========================================================================
    // write() - called by analysis port for every observed TLP
    //=========================================================================

    virtual function void write(pcie_tl_tlp t);
        realtime       now;
        int            payload_bytes;
        tlp_category_e cat;

        now           = $realtime;
        payload_bytes = t.get_payload_size();
        cat           = t.get_category();

        //--- Throughput accounting -------------------------------------------
        total_tlp_count++;
        total_bytes += payload_bytes;

        if (kind_count.exists(t.kind))
            kind_count[t.kind]++;
        else
            kind_count[t.kind] = 1;

        if (kind_bytes.exists(t.kind))
            kind_bytes[t.kind] += payload_bytes;
        else
            kind_bytes[t.kind] = payload_bytes;

        if (cat_count.exists(cat))
            cat_count[cat]++;
        else
            cat_count[cat] = 1;

        if (cat_bytes.exists(cat))
            cat_bytes[cat] += payload_bytes;
        else
            cat_bytes[cat] = payload_bytes;

        //--- Rolling window update -------------------------------------------
        ts_window   [win_head % WINDOW_SIZE] = now;
        bytes_window[win_head % WINDOW_SIZE] = payload_bytes;
        win_head++;
        if (win_count < WINDOW_SIZE) win_count++;

        //--- Ordering violation flag → stability counter ---------------------
        if (t.violate_ordering)
            ordering_violation_count++;

        //--- Latency tracking (Non-Posted requests and Completions) ----------
        case (cat)
            TLP_CAT_NON_POSTED: begin
                // Record send timestamp; allocate tag
                pending_ts[t.tag] = now;
                if (!outstanding_tags.exists(t.tag)) begin
                    outstanding_tags[t.tag] = 1'b1;
                    cur_outstanding++;
                    total_tag_alloc++;
                    if (cur_outstanding > peak_outstanding)
                        peak_outstanding = cur_outstanding;
                end
            end

            TLP_CAT_COMPLETION: begin
                // Match completion back to pending request by tag
                if (pending_ts.exists(t.tag)) begin
                    real lat_sample;
                    lat_sample = real'(now - pending_ts[t.tag]);
                    latency_samples.push_back(lat_sample);
                    lat_count++;
                    lat_sum += lat_sample;
                    if (lat_sample < lat_min) lat_min = lat_sample;
                    if (lat_sample > lat_max) lat_max = lat_sample;
                    pending_ts.delete(t.tag);
                    if (outstanding_tags.exists(t.tag)) begin
                        outstanding_tags.delete(t.tag);
                        cur_outstanding--;
                        total_tag_free++;
                    end
                end
            end

            default: ; // Posted TLPs: no latency tracking needed
        endcase
    endfunction

    //=========================================================================
    // check_phase - scan for tag timeouts
    //=========================================================================

    virtual function void check_phase(uvm_phase phase);
        realtime     now;
        bit [9:0]    tag;
        now = $realtime;
        if (pending_ts.first(tag)) begin
            do begin
                if ((now - pending_ts[tag]) >= tag_timeout_threshold) begin
                    `uvm_warning("COSIM_PERF", $sformatf(
                        "Tag 0x%03h timed out: outstanding for %0t",
                        tag, now - pending_ts[tag]))
                    total_tag_timeout++;
                end
            end while (pending_ts.next(tag));
        end
    endfunction

    //=========================================================================
    // report_phase - print formatted performance report
    //=========================================================================

    virtual function void report_phase(uvm_phase phase);
        realtime sim_elapsed;
        real     tlps_per_sec;
        real     mb_per_sec;
        real     win_tlps_per_sec;
        real     win_mb_per_sec;
        string   sep;

        sim_elapsed = $realtime - sim_start_time;

        // Overall rates (guard against zero elapsed time)
        if (sim_elapsed > 0) begin
            tlps_per_sec = real'(total_tlp_count) / (real'(sim_elapsed) * 1e-9);
            mb_per_sec   = real'(total_bytes)     / (real'(sim_elapsed) * 1e-9) / 1.0e6;
        end else begin
            tlps_per_sec = 0.0;
            mb_per_sec   = 0.0;
        end

        // Rolling-window rates (last up-to-WINDOW_SIZE TLPs)
        if (win_count >= 2) begin
            int      oldest_idx;
            realtime win_elapsed;
            longint  win_bytes;
            oldest_idx  = (win_count < WINDOW_SIZE) ? 0 : (win_head % WINDOW_SIZE);
            win_elapsed = ts_window[(win_head - 1) % WINDOW_SIZE] -
                          ts_window[oldest_idx];
            win_bytes   = 0;
            for (int i = 0; i < win_count; i++)
                win_bytes += bytes_window[(oldest_idx + i) % WINDOW_SIZE];
            if (win_elapsed > 0) begin
                win_tlps_per_sec = real'(win_count) / (real'(win_elapsed) * 1e-9);
                win_mb_per_sec   = real'(win_bytes) / (real'(win_elapsed) * 1e-9) / 1.0e6;
            end else begin
                win_tlps_per_sec = 0.0;
                win_mb_per_sec   = 0.0;
            end
        end else begin
            win_tlps_per_sec = 0.0;
            win_mb_per_sec   = 0.0;
        end

        sep = "=============================================================";

        `uvm_info(get_full_name(), "\n", UVM_NONE)
        `uvm_info(get_full_name(), sep, UVM_NONE)
        `uvm_info(get_full_name(), "  COSIM PERFORMANCE REPORT", UVM_NONE)
        `uvm_info(get_full_name(), sep, UVM_NONE)

        //--- Throughput section -----------------------------------------------
        `uvm_info(get_full_name(), "  [THROUGHPUT]", UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Simulation elapsed   : %0t", sim_elapsed), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Total TLPs           : %0d", total_tlp_count), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Total payload bytes  : %0d", total_bytes), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Overall TLP/s        : %.2f", tlps_per_sec), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Overall MB/s         : %.2f", mb_per_sec), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Rolling  TLP/s       : %.2f  (last %0d TLPs)",
            win_tlps_per_sec, win_count), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Rolling  MB/s        : %.2f  (last %0d TLPs)",
            win_mb_per_sec, win_count), UVM_NONE)

        //--- Per-category breakdown -------------------------------------------
        `uvm_info(get_full_name(), "  [CATEGORY BREAKDOWN]", UVM_NONE)
        begin
            tlp_category_e cats[3] = '{TLP_CAT_POSTED, TLP_CAT_NON_POSTED, TLP_CAT_COMPLETION};
            string cat_names[3]    = '{"Posted", "Non-Posted", "Completion"};
            for (int i = 0; i < 3; i++) begin
                longint unsigned cnt = cat_count.exists(cats[i]) ? cat_count[cats[i]] : 0;
                longint unsigned byt = cat_bytes.exists(cats[i]) ? cat_bytes[cats[i]] : 0;
                `uvm_info(get_full_name(), $sformatf(
                    "    %-12s  TLPs=%0d  bytes=%0d",
                    cat_names[i], cnt, byt), UVM_NONE)
            end
        end

        //--- Per-kind breakdown (non-zero entries only) -----------------------
        `uvm_info(get_full_name(), "  [KIND BREAKDOWN (non-zero)]", UVM_NONE)
        begin
            tlp_kind_e k;
            if (kind_count.first(k)) begin
                do begin
                    `uvm_info(get_full_name(), $sformatf(
                        "    %-20s  TLPs=%0d  bytes=%0d",
                        k.name(), kind_count[k],
                        kind_bytes.exists(k) ? kind_bytes[k] : 0), UVM_NONE)
                end while (kind_count.next(k));
            end
        end

        //--- Latency section --------------------------------------------------
        `uvm_info(get_full_name(), "  [LATENCY (Non-Posted completions)]", UVM_NONE)
        if (lat_count > 0) begin
            real lat_avg;
            real lat_p50, lat_p90, lat_p99;
            lat_avg = lat_sum / real'(lat_count);
            latency_samples.sort();
            lat_p50 = latency_samples[int'(real'(lat_count) * 0.50)];
            lat_p90 = latency_samples[int'(real'(lat_count) * 0.90)];
            lat_p99 = latency_samples[int'(real'(lat_count) * 0.99)];
            `uvm_info(get_full_name(), $sformatf(
                "    Samples  : %0d", lat_count), UVM_NONE)
            `uvm_info(get_full_name(), $sformatf(
                "    Min      : %.1f (sim time units)", lat_min), UVM_NONE)
            `uvm_info(get_full_name(), $sformatf(
                "    Avg      : %.1f (sim time units)", lat_avg), UVM_NONE)
            `uvm_info(get_full_name(), $sformatf(
                "    p50      : %.1f (sim time units)", lat_p50), UVM_NONE)
            `uvm_info(get_full_name(), $sformatf(
                "    p90      : %.1f (sim time units)", lat_p90), UVM_NONE)
            `uvm_info(get_full_name(), $sformatf(
                "    p99      : %.1f (sim time units)", lat_p99), UVM_NONE)
            `uvm_info(get_full_name(), $sformatf(
                "    Max      : %.1f (sim time units)", lat_max), UVM_NONE)
        end else begin
            `uvm_info(get_full_name(),
                "    No completed Non-Posted TLPs observed.", UVM_NONE)
        end

        //--- Tag utilization section ------------------------------------------
        `uvm_info(get_full_name(), "  [TAG UTILIZATION]", UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Current outstanding  : %0d", cur_outstanding), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Peak outstanding     : %0d", peak_outstanding), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Total alloc          : %0d", total_tag_alloc), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Total free           : %0d", total_tag_free), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Timeouts             : %0d", total_tag_timeout), UVM_NONE)

        //--- Stability section ------------------------------------------------
        `uvm_info(get_full_name(), "  [STABILITY]", UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Scoreboard mismatches: %0d", scoreboard_mismatch_count), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Unknown TLPs         : %0d", unknown_tlp_count), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    FC violations        : %0d", fc_violation_count), UVM_NONE)
        `uvm_info(get_full_name(), $sformatf(
            "    Ordering violations  : %0d", ordering_violation_count), UVM_NONE)

        `uvm_info(get_full_name(), sep, UVM_NONE)

        // Escalate non-zero stability issues to UVM warnings
        if (scoreboard_mismatch_count > 0)
            `uvm_warning("COSIM_PERF", $sformatf(
                "%0d scoreboard mismatch(es) detected",
                scoreboard_mismatch_count))
        if (fc_violation_count > 0)
            `uvm_warning("COSIM_PERF", $sformatf(
                "%0d FC violation(s) detected", fc_violation_count))
        if (ordering_violation_count > 0)
            `uvm_warning("COSIM_PERF", $sformatf(
                "%0d ordering violation(s) detected", ordering_violation_count))
        if (total_tag_timeout > 0)
            `uvm_warning("COSIM_PERF", $sformatf(
                "%0d tag timeout(s) detected", total_tag_timeout))
    endfunction

    //=========================================================================
    // External increment functions
    // Called by the environment or scoreboard to bump stability counters
    // without requiring direct field access.
    //=========================================================================

    function void incr_scoreboard_mismatch();
        scoreboard_mismatch_count++;
    endfunction

    function void incr_unknown_tlp();
        unknown_tlp_count++;
    endfunction

    function void incr_fc_violation();
        fc_violation_count++;
    endfunction

endclass : cosim_perf_monitor

`endif  // COSIM_PERF_EN
