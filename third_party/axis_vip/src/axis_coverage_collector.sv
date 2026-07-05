class axis_coverage_collector #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_component;

    `uvm_component_param_utils(axis_coverage_collector#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    typedef axis_coverage_collector #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) this_t;
    axis_config cfg;
    vif_t vif;

    uvm_analysis_imp_master_beat #(axis_transfer, this_t) master_beat_export;
    uvm_analysis_imp_slave_beat  #(axis_transfer, this_t) slave_beat_export;

    // Sampled fields for covergroups
    protected bit       sampled_tvalid;
    protected bit       sampled_tready;
    protected int unsigned sampled_pkt_len;
    protected bit [15:0]   sampled_tid;
    protected bit [15:0]   sampled_tdest;
    protected bit       sampled_tdata_all_zero;
    protected bit       sampled_tdata_all_one;
    protected bit [63:0] sampled_tstrb_pattern;
    protected bit [63:0] sampled_tkeep_pattern;
    protected int unsigned sampled_bp_duration;
    protected int unsigned sampled_bp_consec_count;
    protected int unsigned sampled_handshake_latency;
    protected int unsigned sampled_bandwidth_permille;
    protected bit [2:0] sampled_reset_timing;
    protected axis_valid_gen_mode_e sampled_valid_gen_mode;
    protected axis_ready_gen_mode_e sampled_ready_gen_mode;

    // Internal state
    protected int unsigned current_pkt_len;
    protected int unsigned handshake_latency_counter;
    protected int unsigned bp_cycle_count;
    protected int unsigned bp_consec_events;
    protected bit prev_aresetn;
    protected bit prev_tvalid;

    // ---- Covergroup 1: Handshake (valid/ready combos, sampled every cycle) ----
    covergroup handshake_cg;
        cp_valid_ready: coverpoint {sampled_tvalid, sampled_tready} {
            bins idle       = {2'b00};
            bins valid_only = {2'b10};
            bins ready_only = {2'b01};
            bins handshake  = {2'b11};
        }
    endgroup

    // ---- Covergroup 2: Latency (sampled on handshake only) ----
    covergroup latency_cg;
        cp_latency: coverpoint sampled_handshake_latency {
            bins zero      = {0};
            bins one       = {1};
            bins short_    = {[2:5]};
            bins med_      = {[6:20]};
            bins long_     = {[21:100]};
            bins very_long = {[101:$]};
        }
    endgroup

    // ---- Covergroup 3: Packet ----
    covergroup packet_cg;
        cp_length: coverpoint sampled_pkt_len {
            bins single  = {1};
            bins short_  = {[2:4]};
            bins med_    = {[5:16]};
            bins long_   = {[17:64]};
            bins longer  = {[65:256]};
            bins max_    = {[257:$]};
        }
        cp_tid: coverpoint sampled_tid {
            bins values[] = {[0:15]};
        }
        cp_tdest: coverpoint sampled_tdest {
            bins values[] = {[0:15]};
        }
        cp_tid_x_tdest: cross cp_tid, cp_tdest;
    endgroup

    // ---- Covergroup 4: Backpressure ----
    covergroup backpressure_cg;
        cp_bp_duration: coverpoint sampled_bp_duration {
            bins zero    = {0};
            bins one     = {1};
            bins short_  = {[2:5]};
            bins med_    = {[6:20]};
            bins long_   = {[21:$]};
        }
        cp_bp_consec_count: coverpoint sampled_bp_consec_count {
            bins single = {1};
            bins few    = {[2:5]};
            bins many   = {[6:20]};
            bins stress = {[21:$]};
        }
    endgroup

    // ---- Covergroup 5: Data ----
    covergroup data_cg;
        cp_all_zero: coverpoint sampled_tdata_all_zero {
            bins yes = {1};
            bins no  = {0};
        }
        cp_all_one: coverpoint sampled_tdata_all_one {
            bins yes = {1};
            bins no  = {0};
        }
        cp_tstrb_pattern: coverpoint sampled_tstrb_pattern[3:0] {
            bins all_active   = {4'b1111};
            bins all_inactive = {4'b0000};
            bins partial[]    = default;
        }
        cp_tkeep_pattern: coverpoint sampled_tkeep_pattern[3:0] {
            bins all_active   = {4'b1111};
            bins all_inactive = {4'b0000};
            bins partial[]    = default;
        }
    endgroup

    // ---- Covergroup 6: Reset ----
    covergroup reset_cg;
        cp_timing: coverpoint sampled_reset_timing {
            bins idle         = {0};
            bins mid_transfer = {1};
            bins mid_packet   = {2};
        }
    endgroup

    // ---- Covergroup 7: Bandwidth ----
    covergroup bandwidth_cg;
        cp_bw: coverpoint sampled_bandwidth_permille {
            bins zero      = {0};
            bins low       = {[1:250]};
            bins med_      = {[251:500]};
            bins high      = {[501:750]};
            bins very_high = {[751:1000]};
        }
    endgroup

    // ---- Covergroup 8: Cross-coverages ----
    covergroup cross_cg;
        cp_pkt_len: coverpoint sampled_pkt_len {
            bins single  = {1};
            bins short_  = {[2:4]};
            bins med_    = {[5:16]};
            bins long_   = {[17:64]};
            bins longer  = {[65:256]};
            bins max_    = {[257:$]};
        }
        cp_bp_mode: coverpoint sampled_ready_gen_mode;
        cp_rst_timing: coverpoint sampled_reset_timing {
            bins idle         = {0};
            bins mid_transfer = {1};
            bins mid_packet   = {2};
        }
        cp_hs_latency: coverpoint sampled_handshake_latency {
            bins zero      = {0};
            bins one       = {1};
            bins short_    = {[2:5]};
            bins med_      = {[6:20]};
            bins long_     = {[21:100]};
            bins very_long = {[101:$]};
        }
        cp_valid_mode: coverpoint sampled_valid_gen_mode;

        cx_pkt_len_x_bp_mode:       cross cp_pkt_len, cp_bp_mode;
        cx_rst_timing_x_pkt_len:    cross cp_rst_timing, cp_pkt_len;
        cx_hs_latency_x_valid_mode: cross cp_hs_latency, cp_valid_mode;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        handshake_cg    = new();
        latency_cg      = new();
        packet_cg       = new();
        backpressure_cg = new();
        data_cg         = new();
        reset_cg        = new();
        bandwidth_cg    = new();
        cross_cg        = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
        master_beat_export = new("master_beat_export", this);
        slave_beat_export  = new("slave_beat_export",  this);
    endfunction

    // ---- Analysis port callbacks ----
    function void write_master_beat(axis_transfer t);
        sample_beat(t);
    endfunction

    function void write_slave_beat(axis_transfer t);
        sample_beat(t);
    endfunction

    // ---- Beat-level sampling (called on handshake from either port) ----
    protected function void sample_beat(axis_transfer t);
        // Latency sampling (on handshake)
        sampled_handshake_latency = handshake_latency_counter;
        sampled_valid_gen_mode = cfg.valid_gen_mode;
        sampled_ready_gen_mode = cfg.ready_gen_mode;
        latency_cg.sample();

        // Data coverage
        sampled_tdata_all_zero  = (t.tdata == 0);
        sampled_tdata_all_one   = (t.tdata == ((1 << cfg.TDATA_WIDTH) - 1));
        sampled_tstrb_pattern   = t.tstrb;
        sampled_tkeep_pattern   = t.tkeep;
        data_cg.sample();

        // Packet tracking
        current_pkt_len++;
        if (t.tlast || !cfg.HAS_TLAST) begin
            sampled_pkt_len = current_pkt_len;
            sampled_tid     = t.tid;
            sampled_tdest   = t.tdest;
            packet_cg.sample();
            cross_cg.sample();
            current_pkt_len = 0;
        end
    endfunction

    // ---- Per-cycle sampling (handshake combos, backpressure, reset detection) ----
    task run_phase(uvm_phase phase);
        prev_aresetn = vif.aresetn;
        prev_tvalid  = 0;
        forever begin
            @(posedge vif.aclk);

            // Reset edge detection (active-low: aresetn falls)
            if (!vif.aresetn && prev_aresetn) begin
                bit [2:0] timing;
                if (current_pkt_len > 0)
                    timing = 2;  // mid-packet
                else if (prev_tvalid)
                    timing = 1;  // mid-transfer
                else
                    timing = 0;  // idle
                sample_reset_timing(timing);
            end
            prev_aresetn = vif.aresetn;

            if (!vif.aresetn) begin
                prev_tvalid = 0;
                bp_cycle_count = 0;
                bp_consec_events = 0;
                handshake_latency_counter = 0;
                continue;
            end

            // Handshake combo coverage (every cycle)
            sampled_tvalid = vif.tvalid;
            sampled_tready = vif.tready;
            handshake_cg.sample();

            // Handshake latency counter
            if (vif.tvalid && !vif.tready)
                handshake_latency_counter++;
            else
                handshake_latency_counter = 0;

            // Backpressure detection and sampling
            if (vif.tvalid && !vif.tready) begin
                bp_cycle_count++;
            end else if (vif.tvalid && vif.tready && bp_cycle_count > 0) begin
                bp_consec_events++;
                sample_backpressure(bp_cycle_count, bp_consec_events);
                bp_cycle_count = 0;
            end else if (!vif.tvalid) begin
                if (bp_cycle_count > 0) begin
                    bp_consec_events++;
                    sample_backpressure(bp_cycle_count, bp_consec_events);
                    bp_cycle_count = 0;
                end
                bp_consec_events = 0;
            end

            prev_tvalid = vif.tvalid;
        end
    endtask

    // ---- External sampling methods ----
    function void sample_backpressure(int unsigned duration, int unsigned consec_count = 0);
        sampled_bp_duration     = duration;
        sampled_bp_consec_count = consec_count;
        backpressure_cg.sample();
    endfunction

    function void sample_bandwidth(real bw);
        sampled_bandwidth_permille = int'(bw * 1000.0);
        if (sampled_bandwidth_permille > 1000)
            sampled_bandwidth_permille = 1000;
        bandwidth_cg.sample();
    endfunction

    function void sample_reset_timing(int unsigned timing);
        sampled_reset_timing = timing[2:0];
        reset_cg.sample();
        cross_cg.sample();
    endfunction

endclass
