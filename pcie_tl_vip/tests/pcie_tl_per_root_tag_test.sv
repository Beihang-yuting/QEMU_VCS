import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Per-Root Tag Independence Test  (num_usp=2)
//
// Each root has its OWN tag_mgrs[r], so the two roots' tag spaces are fully
// independent: RC0 and RC1 may use the SAME tag values concurrently with no
// conflict, and each completion must return to its own root.
//
// APPROACH — SATURATION (documented):
//   The mem_rd seq auto-allocates tags from tag_mgrs[r]; it exposes no field to
//   pin tag=5, so we cannot force a literal tag collision.  Instead we drive
//   N concurrent reads on BOTH roots at once (fork/join).  The two roots WILL
//   allocate overlapping tag values (both start near 0) — if the tag space were
//   shared, those overlaps would collide / mis-route.  Because the managers are
//   per-root, every read on every root must complete cleanly and land on its
//   own root's scoreboard.
//
//   Pre-step: RC writes known data to each owned EP window so the read-backs
//   have deterministic data (data_integrity check exercised).
//
// check_phase:
//   - each root's scb saw exactly its own N completions (matched == N)
//   - no mismatched / unexpected / timed_out on either root
//   - cross_root_violations == 0  (nothing crossed)
//   - UVM_ERROR == 0
//=============================================================================
class pcie_tl_per_root_tag_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_per_root_tag_test)

    int        n_reads = 8;          // concurrent reads per root (tag spaces overlap)
    bit [63:0] root_base[2];         // one EP window per root to read/write
    int        root_dsp[2] = '{0, 2};// DSP0 (root0) and DSP2 (root1)

    function new(string name = "pcie_tl_per_root_tag_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();

        sw_cfg = new("sw_cfg");
        sw_cfg.num_usp      = 2;
        sw_cfg.num_ds_ports = 4;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();        // auto dsp_owner=[0,0,1,1]
        cfg.switch_enable = 1;
        cfg.switch_cfg    = sw_cfg;

        cfg.use_unified_mem = 1'b0;    // sparse EP mem; EP auto-responds to reads

        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;
        cfg.cpl_timeout_ns  = 200000;

        cfg.scb_enable              = 1;
        cfg.ordering_check_enable   = 1;
        cfg.completion_check_enable = 1;
        cfg.data_integrity_enable   = 1;
        cfg.ep_auto_response        = 1;
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TAGINDEP",
            "=== Per-Root Tag Independence Test START (num_usp=2) ===", UVM_LOW)

        if (env.sw == null)
            `uvm_fatal("TAGINDEP", "env.sw is null -- switch not built")
        if (env.v_seqr.rc_seqr_arr.size() < 2)
            `uvm_fatal("TAGINDEP", $sformatf("rc_seqr_arr.size=%0d, expected >=2",
                env.v_seqr.rc_seqr_arr.size()))
        if (env.tag_mgrs.size() < 2)
            `uvm_fatal("TAGINDEP", $sformatf("tag_mgrs.size=%0d, expected >=2",
                env.tag_mgrs.size()))

        // One window per root (DSP0 for root0, DSP2 for root1).
        root_base[0] = {32'h0, cfg.switch_cfg.ds_mem_base[root_dsp[0]]};
        root_base[1] = {32'h0, cfg.switch_cfg.ds_mem_base[root_dsp[1]]};
        `uvm_info("TAGINDEP", $sformatf("root0 window=0x%016h  root1 window=0x%016h",
            root_base[0], root_base[1]), UVM_LOW)

        // Pre-step: write known data to each root's window (n_reads slots, 256B each).
        for (int r = 0; r < 2; r++) begin
            for (int k = 0; k < n_reads; k++) begin
                automatic int        rr = r;
                automatic bit [63:0] a  = root_base[rr] + k * 256;
                automatic pcie_tl_mem_wr_seq wr;
                wr = pcie_tl_mem_wr_seq::type_id::create(
                         $sformatf("rc%0d_pre_wr_%0d", rr, k));
                wr.addr     = a;
                wr.length   = 256 / 4;
                wr.first_be = 4'hF;
                wr.last_be  = 4'hF;
                wr.is_64bit = (a[63:32] != 0);
                wr.start(env.v_seqr.rc_seqr_arr[rr]);
                #200ns;
            end
        end
        #2us;

        // Concurrent reads on BOTH roots at once: overlapping tag values per root.
        fork
            begin : root0_reads
                for (int k = 0; k < n_reads; k++) begin
                    automatic bit [63:0] a = root_base[0] + k * 256;
                    automatic pcie_tl_mem_rd_seq rd;
                    rd = pcie_tl_mem_rd_seq::type_id::create(
                             $sformatf("rc0_rd_%0d", k));
                    rd.addr     = a;
                    rd.length   = 256 / 4;
                    rd.first_be = 4'hF;
                    rd.last_be  = 4'hF;
                    rd.is_64bit = (a[63:32] != 0);
                    rd.start(env.v_seqr.rc_seqr_arr[0]);
                    #100ns;
                end
            end
            begin : root1_reads
                for (int k = 0; k < n_reads; k++) begin
                    automatic bit [63:0] a = root_base[1] + k * 256;
                    automatic pcie_tl_mem_rd_seq rd;
                    rd = pcie_tl_mem_rd_seq::type_id::create(
                             $sformatf("rc1_rd_%0d", k));
                    rd.addr     = a;
                    rd.length   = 256 / 4;
                    rd.first_be = 4'hF;
                    rd.last_be  = 4'hF;
                    rd.is_64bit = (a[63:32] != 0);
                    rd.start(env.v_seqr.rc_seqr_arr[1]);
                    #100ns;
                end
            end
        join

        // Drain for all completions.
        #20us;
        `uvm_info("TAGINDEP", "=== Per-Root Tag Independence run_phase DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

    function void check_phase(uvm_phase phase);
        bit ok = 1;
        super.check_phase(phase);

        // 1. Each root's scoreboard completed exactly its own N reads, no errors.
        for (int r = 0; r < 2; r++) begin
            if (r >= env.scbs.size() || env.scbs[r] == null) begin
                ok = 0;
                `uvm_error("TAGINDEP_FAIL", $sformatf("scbs[%0d] missing", r))
                continue;
            end
            if (env.scbs[r].matched != n_reads) begin
                ok = 0;
                `uvm_error("TAGINDEP_FAIL", $sformatf(
                    "scbs[%0d].matched=%0d (expected %0d completions)",
                    r, env.scbs[r].matched, n_reads))
            end else begin
                `uvm_info("TAGINDEP", $sformatf(
                    "scbs[%0d] matched=%0d OK (all reads completed on own root)",
                    r, env.scbs[r].matched), UVM_LOW)
            end
            if (env.scbs[r].mismatched != 0 || env.scbs[r].unexpected != 0 ||
                env.scbs[r].timed_out != 0) begin
                ok = 0;
                `uvm_error("TAGINDEP_FAIL", $sformatf(
                    "scbs[%0d]: mismatched=%0d unexpected=%0d timed_out=%0d",
                    r, env.scbs[r].mismatched, env.scbs[r].unexpected,
                    env.scbs[r].timed_out))
            end
        end

        // 2. No cross-root traffic occurred.
        if (env.sw.fabric.cross_root_violations != 0) begin
            ok = 0;
            `uvm_error("TAGINDEP_FAIL", $sformatf(
                "cross_root_violations=%0d (expected 0)",
                env.sw.fabric.cross_root_violations))
        end else begin
            `uvm_info("TAGINDEP", "cross_root_violations=0 OK", UVM_LOW)
        end

        if (ok) `uvm_info("TAGINDEP", "TAGINDEP PASSED", UVM_LOW)
        else    `uvm_info("TAGINDEP", "TAGINDEP FAILED", UVM_LOW)
    endfunction

endclass
