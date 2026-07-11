import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Non-Switch Multi-Pair Heavy-Traffic Test
//
// Exercises the reconciled non-switch multi-agent path (cfg.num_rc/num_ep)
// under HEAVY load: N independent RC[i] <-> EP[i] TLM pairs, each its own
// per-pair manager set (fc/tag/ord/cfg) and scoreboard — no switch.
//
//   +NUM_PAIRS=1  -> direct 1RC+1EP (backward-compat heavy; single loopback)
//   +NUM_PAIRS=2  -> two independent pairs (paired loopback; per-pair isolation)
//
// Per pair: thousands of MWr (posted) + MRd (completion-matched by tag). EP
// auto-responds with CplD; each pair's scoreboard matches request<->completion
// on its OWN tag pool (overlapping tags across pairs must NOT collide — the
// isolation proof under load). data_integrity off (non-unified EP returns a
// pattern), completion+ordering checks ON. PASS = UVM_ERROR=0 and no hang.
//=============================================================================
class pcie_tl_multipair_heavy_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_multipair_heavy_test)

    int num_pairs      = 2;      // overridden by +NUM_PAIRS
    int writes_per_pair = 1500;
    int reads_per_pair  = 400;

    function new(string name = "pcie_tl_multipair_heavy_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        super.configure_test();              // if_mode = TLM_MODE
        void'($value$plusargs("NUM_PAIRS=%d", num_pairs));
        if (num_pairs < 1) num_pairs = 1;

        cfg.rc_agent_enable = 1;
        cfg.ep_agent_enable = 1;
        cfg.num_rc          = num_pairs;     // N independent RC host links
        cfg.num_ep          = num_pairs;     // paired 1:1 with the RCs
        cfg.switch_enable   = 0;

        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;             // no FC stall under heavy load
        cfg.cpl_timeout_ns  = 2000000;       // generous while draining bursts
        cfg.ep_auto_response = 1;

        cfg.scb_enable              = 1;
        cfg.ordering_check_enable   = 1;
        cfg.completion_check_enable = 1;
        cfg.data_integrity_enable   = 0;     // non-unified EP returns pattern data
        cfg.use_unified_mem         = 0;

        cfg.extended_tag_enable = 1;
        cfg.max_outstanding     = 1024;
    endfunction

    // one MWr on pair p's RC sequencer
    task issue_wr(int p, bit [63:0] a, int len_dw, string nm);
        pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(nm);
        wr.addr     = a;
        wr.length   = len_dw;
        wr.first_be = 4'hF;
        wr.last_be  = (len_dw == 1) ? 4'h0 : 4'hF;
        wr.is_64bit = (a[63:32] != 0);
        wr.start(env.rc_agents[p].sequencer);
    endtask

    // one MRd on pair p's RC sequencer
    task issue_rd(int p, bit [63:0] a, int len_dw, string nm);
        pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create(nm);
        rd.addr     = a;
        rd.length   = len_dw;
        rd.first_be = 4'hF;
        rd.last_be  = (len_dw == 1) ? 4'h0 : 4'hF;
        rd.is_64bit = (a[63:32] != 0);
        rd.start(env.rc_agents[p].sequencer);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("MPHEAVY", $sformatf(
            "=== Multi-Pair Heavy START: %0d pair(s), %0d MWr + %0d MRd each ===",
            num_pairs, writes_per_pair, reads_per_pair), UVM_LOW)

        if (env.rc_agents.size() != num_pairs)
            `uvm_fatal("MPHEAVY", $sformatf("rc_agents.size=%0d expected %0d",
                env.rc_agents.size(), num_pairs))

        // heavy random traffic, all pairs concurrent, each on its own link
        fork
            for (int p = 0; p < num_pairs; p++) begin
                automatic int pp = p;
                automatic bit [63:0] base = 64'h0000_0001_0000_0000 + (pp * 64'h0000_0004_0000_0000);
                fork
                    begin
                        // posted writes
                        for (int n = 0; n < writes_per_pair; n++) begin
                            automatic bit [63:0] off = ($urandom_range(24'h00FF_FF00, 0)) & ~64'h3F;
                            automatic int        len = 1 + $urandom_range(31, 0);
                            issue_wr(pp, base + off, len, $sformatf("p%0d_wr_%0d", pp, n));
                            #1ns;
                        end
                    end
                    begin
                        // non-posted reads (overlapping tags across pairs)
                        for (int n = 0; n < reads_per_pair; n++) begin
                            automatic bit [63:0] off = ($urandom_range(24'h00FF_FF00, 0)) & ~64'h3F;
                            automatic int        len = 1 + $urandom_range(15, 0);
                            issue_rd(pp, base + off, len, $sformatf("p%0d_rd_%0d", pp, n));
                            #3ns;
                        end
                    end
                join_none
            end
        join_none

        // wait for all issuing threads + completion drain
        #300us;
        `uvm_info("MPHEAVY", "=== Multi-Pair Heavy DONE (drained) ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
