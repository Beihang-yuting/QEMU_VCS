import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Multi-Root Stress Test  (num_usp=2, ~20K mixed TLPs)
//
// Topology: 2 USP roots + 4 DSP/EP, auto dsp_owner=[0,0,1,1].
//   Root0 owns EP0/EP1, Root1 owns EP2/EP3.
//
// GOAL — stress the multi-root fabric with HEAVY RANDOM traffic and ERROR
// sequences MIXED together, then confirm the fabric never:
//   - crashes / hangs (test must reach check_phase, objection dropped),
//   - leaks across roots (each EP holds ONLY its own root's marker, never the
//     other root's marker — the hard isolation proof, immune to error noise),
//   - silently swallows the cross-root detection mechanism (violations counter
//     must have fired at least for the deliberate probes).
//
// Injected error seqs (poisoned / malformed / tag_conflict / unexpected_cpl)
// DELIBERATELY raise UVM_ERROR and pollute the scoreboards, so per the agreed
// criterion PASS = isolation + no-hang; scoreboard mismatch/unexpected counts
// are reported for visibility but NOT asserted clean.
//
// cross_root_check_enable = 0 so deliberate probes (and any random error TLP
// that happens to cross a root) log as info and still bump the counter.
//=============================================================================
class pcie_tl_multi_root_stress_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_multi_root_stress_test)

    // ---- scale knobs ----
    int writes_per_ep  = 2500;   // random MWr per EP   (4 EP -> 10000)
    int reads_per_root = 1500;   // random MRd per root (2    -> 3000, same tags)
    int dma_per_ep     = 1000;   // EP DMA upstream     (4 EP -> 4000)
    int err_iters      = 250;    // err-seq cycles/root (2*4*250 -> 2000)
    int probes_per_dir = 50;     // cross-root probes   (2 dir -> 100)

    // ---- topology ----
    int        ep_root[4]  = '{0, 0, 1, 1};   // owning root per EP (matches auto owner)
    bit [63:0] win_base[4];                   // EP window base (= ds_mem_base[i])
    bit [63:0] marker[4];                     // per-EP unique marker addr (isolation proof)

    function new(string name = "pcie_tl_multi_root_stress_test",
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
        sw_cfg.init_defaults();              // auto dsp_owner=[0,0,1,1]
        sw_cfg.cross_root_check_enable = 0;  // probes/err-crossings -> info + counter bump
        cfg.switch_enable = 1;
        cfg.switch_cfg    = sw_cfg;

        cfg.use_unified_mem = 1'b0;          // sparse EP mem; proves physical delivery

        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;
        cfg.cpl_timeout_ns  = 1000000;       // generous under heavy load

        cfg.scb_enable              = 1;
        cfg.ordering_check_enable   = 1;
        cfg.completion_check_enable = 1;
        cfg.data_integrity_enable   = 1;
        cfg.ep_auto_response        = 1;
    endfunction

    //=========================================================================
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("MRSTRESS",
            "=== Multi-Root Stress Test START (num_usp=2, mixed heavy+random+err) ===",
            UVM_LOW)

        // Guards
        if (env.sw == null)
            `uvm_fatal("MRSTRESS", "env.sw is null -- switch not built")
        if (cfg.switch_cfg.num_usp != 2)
            `uvm_fatal("MRSTRESS", $sformatf("num_usp=%0d, expected 2",
                cfg.switch_cfg.num_usp))
        if (env.v_seqr.rc_seqr_arr.size() < 2)
            `uvm_fatal("MRSTRESS", $sformatf("rc_seqr_arr.size=%0d, expected >=2",
                env.v_seqr.rc_seqr_arr.size()))

        // Windows + per-EP unique marker (16MB into window, above random region).
        for (int i = 0; i < 4; i++) begin
            win_base[i] = {32'h0, cfg.switch_cfg.ds_mem_base[i]};
            marker[i]   = win_base[i] + 64'h0100_0000;
            `uvm_info("MRSTRESS", $sformatf("EP%0d window=0x%016h marker=0x%016h root%0d",
                i, win_base[i], marker[i], ep_root[i]), UVM_LOW)
        end

        // -- Phase 0: lay down each EP's unique marker from its OWNING root --
        for (int i = 0; i < 4; i++) begin
            automatic int ii = i;
            issue_wr(ep_root[ii], marker[ii], 64, $sformatf("marker_ep%0d", ii));
            #100ns;
        end
        #1us;

        // -- Phase 1: THE MIX — all traffic classes concurrent on both roots --
        `uvm_info("MRSTRESS", "--- Phase 1: heavy random writes + reads + errors + cross-root probes + EP DMA, ALL concurrent ---", UVM_LOW)
        fork
            //----- per-root heavy random writes (own EPs only) -----
            for (int r = 0; r < 2; r++) begin
                automatic int rr = r;
                fork begin
                    for (int n = 0; n < writes_per_ep * 2; n++) begin
                        // pick one of this root's two EPs
                        automatic int        ep  = (rr * 2) + (n & 1);
                        automatic bit [63:0] off = ($urandom_range(24'h00FF_FF00, 0)) & ~64'h3F;
                        automatic int        len = 1 + $urandom_range(31, 0);
                        issue_wr(rr, win_base[ep] + off, len * 4,
                                 $sformatf("r%0d_wr_%0d", rr, n));
                        #1ns;
                    end
                end join_none
            end

            //----- per-root random reads (BOTH roots use overlapping tags) -----
            for (int r = 0; r < 2; r++) begin
                automatic int rr = r;
                fork begin
                    for (int n = 0; n < reads_per_root; n++) begin
                        automatic int        ep  = (rr * 2) + (n & 1);
                        automatic bit [63:0] off = ($urandom_range(24'h00FF_FF00, 0)) & ~64'h3F;
                        automatic int        len = 1 + $urandom_range(15, 0);
                        issue_rd(rr, win_base[ep] + off, len,
                                 $sformatf("r%0d_rd_%0d", rr, n));
                        #3ns;
                    end
                end join_none
            end

            //----- error-sequence injection, cycled on BOTH roots -----
            for (int r = 0; r < 2; r++) begin
                automatic int rr = r;
                fork begin
                    for (int n = 0; n < err_iters; n++) begin
                        inject_err(rr, n);
                        #5ns;
                    end
                end join_none
            end

            //----- deliberate cross-root probes (RC0->root1 EP, RC1->root0 EP) -----
            begin
                for (int n = 0; n < probes_per_dir; n++) begin
                    // RC0 -> EP2 marker band (root1); offset distinct from EP2's own marker
                    issue_wr(0, marker[2] + 64'h0020_0000 + n * 64'h40, 64,
                             $sformatf("probe_r0_to_r1_%0d", n));
                    // RC1 -> EP0 marker band (root0)
                    issue_wr(1, marker[0] + 64'h0020_0000 + n * 64'h40, 64,
                             $sformatf("probe_r1_to_r0_%0d", n));
                    #50ns;
                end
            end

            //----- EP DMA upstream (each EP -> its owner root host region) -----
            for (int e = 0; e < 4; e++) begin
                automatic int ee = e;
                fork begin
                    for (int n = 0; n < dma_per_ep; n++) begin
                        env.ep_agents[ee].ep_driver.initiate_dma(
                            64'h0000_0000_0100_0000 + (ee * 64'h0100_0000) + (n * 64),
                            64, 0);
                        #2ns;
                    end
                end join_none
            end

            //----- periodic monitor (also a liveness heartbeat) -----
            begin
                for (int m = 0; m < 12; m++) begin
                    #8000ns;
                    `uvm_info("MRSTRESS", $sformatf(
                        "  [@%0t] routed=%0d dropped=%0d xroot=%0d | scb0 m=%0d u=%0d | scb1 m=%0d u=%0d",
                        $realtime, env.sw.total_routed, env.sw.total_dropped,
                        env.sw.fabric.cross_root_violations,
                        env.scbs[0].matched, env.scbs[0].unexpected,
                        env.scbs[1].matched, env.scbs[1].unexpected), UVM_LOW)
                end
            end
        join

        // Drain heavy completions.
        #150us;
        `uvm_info("MRSTRESS", "=== run_phase DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

    //=========================================================================
    // check_phase — PASS = isolation + no-hang (errors are expected noise)
    //=========================================================================
    function void check_phase(uvm_phase phase);
        bit ok = 1;
        super.check_phase(phase);

        // 1. ISOLATION (hard): every EP holds ONLY its own marker, never any
        //    other EP's marker -> no cross-root data leak under heavy mixed load.
        for (int i = 0; i < 4; i++) begin
            if (!ep_saw(i, marker[i])) begin
                ok = 0;
                `uvm_error("MRSTRESS_FAIL", $sformatf(
                    "EP%0d missing its OWN marker 0x%016h", i, marker[i]))
            end
            for (int j = 0; j < 4; j++) begin
                if (ep_root[j] == ep_root[i]) continue;  // only cross-root pairs
                if (ep_saw(i, marker[j])) begin
                    ok = 0;
                    `uvm_error("MRSTRESS_FAIL", $sformatf(
                        "CROSS-ROOT LEAK: EP%0d (root%0d) holds EP%0d's marker 0x%016h (root%0d)",
                        i, ep_root[i], j, marker[j], ep_root[j]))
                end
            end
        end

        // 1b. Cross-root probes must NOT have landed on their target EPs.
        for (int n = 0; n < probes_per_dir; n++) begin
            if (ep_saw(2, marker[2] + 64'h0020_0000 + n * 64'h40) ||
                ep_saw(0, marker[0] + 64'h0020_0000 + n * 64'h40)) begin
                ok = 0;
                `uvm_error("MRSTRESS_FAIL",
                    "a cross-root probe write reached its target EP (should be dropped)")
            end
        end

        // 2. Detection mechanism fired at least for the deliberate probes.
        if (env.sw.fabric.cross_root_violations < probes_per_dir * 2) begin
            ok = 0;
            `uvm_error("MRSTRESS_FAIL", $sformatf(
                "cross_root_violations=%0d < deliberate probes=%0d (mechanism under-fired)",
                env.sw.fabric.cross_root_violations, probes_per_dir * 2))
        end else begin
            `uvm_info("MRSTRESS", $sformatf(
                "cross_root_violations=%0d (>= %0d deliberate probes) OK",
                env.sw.fabric.cross_root_violations, probes_per_dir * 2), UVM_LOW)
        end

        // 3. Liveness: real traffic flowed (not an early deadlock).
        if (env.sw.total_routed < writes_per_ep) begin
            ok = 0;
            `uvm_error("MRSTRESS_FAIL", $sformatf(
                "total_routed=%0d suspiciously low -- possible hang", env.sw.total_routed))
        end

        // Visibility (NOT asserted clean — error seqs pollute these by design).
        `uvm_info("MRSTRESS", $sformatf(
            "STATS routed=%0d dropped=%0d xroot=%0d | scb0[m=%0d mis=%0d unx=%0d to=%0d] scb1[m=%0d mis=%0d unx=%0d to=%0d]",
            env.sw.total_routed, env.sw.total_dropped,
            env.sw.fabric.cross_root_violations,
            env.scbs[0].matched, env.scbs[0].mismatched, env.scbs[0].unexpected,
            env.scbs[0].timed_out,
            env.scbs[1].matched, env.scbs[1].mismatched, env.scbs[1].unexpected,
            env.scbs[1].timed_out), UVM_LOW)

        if (ok) `uvm_info("MRSTRESS", "MRSTRESS PASSED (isolation intact, no hang)", UVM_LOW)
        else    `uvm_info("MRSTRESS", "MRSTRESS FAILED", UVM_LOW)
    endfunction

    //=========================================================================
    // helpers
    //=========================================================================
    // Clamp a byte count so [a, a+bytes) stays inside one 4KB page (PCIe: no TLP
    // may cross a 4KB boundary).  `a` is 64B-aligned at all call sites.
    function int clamp_4kb(bit [63:0] a, int bytes);
        int room = 4096 - int'(a[11:0]);
        clamp_4kb = (bytes > room) ? room : bytes;
        if (clamp_4kb < 4) clamp_4kb = 4;
    endfunction

    task issue_wr(int root, bit [63:0] a, int bytes, string nm);
        int len = (clamp_4kb(a, bytes) + 3) / 4;
        pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(nm);
        wr.addr     = a;
        wr.length   = len;
        wr.first_be = 4'hF;
        wr.last_be  = (len == 1) ? 4'h0 : 4'hF;  // single-DW: last_be must be 0 (PCIe)
        wr.is_64bit = (a[63:32] != 0);
        wr.start(env.v_seqr.rc_seqr_arr[root]);
    endtask

    task issue_rd(int root, bit [63:0] a, int dwords, string nm);
        int len = clamp_4kb(a, dwords * 4) / 4;
        pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create(nm);
        rd.addr     = a;
        rd.length   = len;
        rd.first_be = 4'hF;
        rd.last_be  = (len == 1) ? 4'h0 : 4'hF;  // single-DW: last_be must be 0 (PCIe)
        rd.is_64bit = (a[63:32] != 0);
        rd.start(env.v_seqr.rc_seqr_arr[root]);
    endtask

    // Cycle the four error sequence kinds on the given root's RC sequencer.
    task inject_err(int root, int n);
        uvm_sequencer #(pcie_tl_tlp) seqr = env.v_seqr.rc_seqr_arr[root];
        case (n & 3)
            0: begin pcie_tl_err_poisoned_seq      s =
                 pcie_tl_err_poisoned_seq::type_id::create($sformatf("err_pois_r%0d_%0d", root, n));
                 s.start(seqr); end
            1: begin pcie_tl_err_malformed_seq     s =
                 pcie_tl_err_malformed_seq::type_id::create($sformatf("err_mal_r%0d_%0d", root, n));
                 s.start(seqr); end
            2: begin pcie_tl_err_tag_conflict_seq  s =
                 pcie_tl_err_tag_conflict_seq::type_id::create($sformatf("err_tag_r%0d_%0d", root, n));
                 s.start(seqr); end
            3: begin pcie_tl_err_unexpected_cpl_seq s =
                 pcie_tl_err_unexpected_cpl_seq::type_id::create($sformatf("err_ucpl_r%0d_%0d", root, n));
                 s.start(seqr); end
        endcase
    endtask

    // Did EP[i]'s driver physically store address `a`?
    function bit ep_saw(int i, bit [63:0] a);
        if (env.ep_agents[i] == null || env.ep_agents[i].ep_driver == null) return 0;
        return env.ep_agents[i].ep_driver.mem_space.exists(a);
    endfunction

endclass
