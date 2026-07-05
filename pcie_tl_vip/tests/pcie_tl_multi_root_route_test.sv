import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Multi-Root Route Test  (FIRST num_usp=2 run)
//
// Topology: 2 USP roots + 4 DSP/EP, dsp_owner auto = [0,0,1,1].
//   Root0 owns EP0 (mem 0x8000_0000) and EP1 (0x8400_0000).
//   Root1 owns EP2 (mem 0xA000_0000) and EP3 (0xA400_0000).
//
// RC0 (rc_seqr_arr[0]) writes EP0/EP1 windows (root0 domain).
// RC1 (rc_seqr_arr[1]) writes EP2/EP3 windows (root1 domain).
// Address-based routing in the fabric must land each MWr on its DSP and never
// cross roots.  EP driver stores into its sparse mem_space (no unified mem) so
// we can prove the write physically reached the correct EP.
//
// check_phase asserts:
//   1. env.sw.fabric.cross_root_violations == 0 (all in-root).
//   2. Each EP received exactly its own root's writes:
//        - sw.dsp[i].forwarded_count == wr_per_dsp
//        - ep_agents[i].ep_driver.mem_space holds the written addresses
//        - the OTHER root's EPs did NOT see this EP's addresses
//   3. Scoreboards scbs[0]/scbs[1] clean (mismatched==0, unexpected==0).
//=============================================================================
class pcie_tl_multi_root_route_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_multi_root_route_test)

    bit [63:0] dsp_addr[4];                  // per-DSP base write address (window base)
    int        dsp_root[4] = '{0, 0, 1, 1};  // expected owning root per DSP
    int        wr_per_dsp  = 2;              // MWr issued to each EP
    int        exp_cross   = 1;              // deliberate cross-root probes (RC0->root1)

    function new(string name = "pcie_tl_multi_root_route_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();

        // Multi-root switch topology: 2 USP + 4 DSP, auto dsp_owner=[0,0,1,1]
        sw_cfg = new("sw_cfg");
        sw_cfg.num_usp      = 2;
        sw_cfg.num_ds_ports = 4;
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();
        // Demote the deliberate cross-root probe from uvm_error to uvm_info so the
        // negative check can run without polluting UVM_ERROR; the violation COUNTER
        // still increments either way (verified in check_phase).
        sw_cfg.cross_root_check_enable = 0;
        cfg.switch_enable = 1;
        cfg.switch_cfg    = sw_cfg;

        // Sparse EP memory (no unified mem) — focus is pure routing correctness.
        cfg.use_unified_mem = 1'b0;

        // Infinite credits + generous timeout
        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;
        cfg.cpl_timeout_ns  = 200000;

        // Scoreboards on (posted MWr => no completion expected; should stay clean)
        cfg.scb_enable              = 1;
        cfg.ordering_check_enable   = 1;
        cfg.completion_check_enable = 1;
        cfg.data_integrity_enable   = 1;

        cfg.ep_auto_response = 1;
    endfunction

    //=========================================================================
    // run_phase: RC0 -> root0 EP windows, RC1 -> root1 EP windows
    //=========================================================================
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("MR", "=== Multi-Root Route Test START (num_usp=2) ===", UVM_LOW)

        // Guards
        if (env.sw == null)
            `uvm_fatal("MR", "env.sw is null -- switch not built")
        if (cfg.switch_cfg.num_usp != 2)
            `uvm_fatal("MR", $sformatf("num_usp=%0d, expected 2", cfg.switch_cfg.num_usp))
        if (env.v_seqr.rc_seqr_arr.size() < 2)
            `uvm_fatal("MR", $sformatf("rc_seqr_arr.size=%0d, expected >=2",
                env.v_seqr.rc_seqr_arr.size()))

        // Target = each DSP's own memory window base (forces address routing to it).
        for (int i = 0; i < 4; i++) begin
            dsp_addr[i] = {32'h0, cfg.switch_cfg.ds_mem_base[i]};
            `uvm_info("MR", $sformatf("DSP%0d window base=0x%016h (expected root %0d)",
                i, dsp_addr[i], dsp_root[i]), UVM_LOW)
        end

        // Issue writes: DSP0/1 from RC0, DSP2/3 from RC1.
        for (int i = 0; i < 4; i++) begin
            automatic int di = i;
            automatic int rc = dsp_root[i];                  // owning root drives it
            automatic uvm_sequencer #(pcie_tl_tlp) seqr = env.v_seqr.rc_seqr_arr[rc];
            for (int w = 0; w < wr_per_dsp; w++) begin
                automatic int        sz = 256;
                automatic bit [63:0] a  = dsp_addr[di] + w * sz;
                automatic pcie_tl_mem_wr_seq wr;

                wr = pcie_tl_mem_wr_seq::type_id::create(
                         $sformatf("rc%0d_wr_dsp%0d_%0d", rc, di, w));
                wr.addr     = a;
                wr.length   = sz / 4;
                wr.first_be = 4'hF;
                wr.last_be  = 4'hF;
                wr.is_64bit = (a[63:32] != 0);
                wr.start(seqr);
                #1us;
            end
        end

        // Negative probe: RC0 (root0) attempts a write into DSP2's window
        // (0xA000_0000, owner root1).  The fabric must classify this CROSS_ROOT,
        // drop it, increment cross_root_violations, and EP2 must NOT receive it.
        // We pick an offset distinct from EP2's own writes so a leak is detectable.
        begin
            automatic bit [63:0] xa = dsp_addr[2] + 64'h0010_0000;  // root1 addr, +1MB
            automatic pcie_tl_mem_wr_seq xw;
            `uvm_info("MR", $sformatf(
                "negative probe: RC0 -> 0x%016h (root1 window, expect CROSS_ROOT drop)",
                xa), UVM_LOW)
            xw = pcie_tl_mem_wr_seq::type_id::create("rc0_xroot_probe");
            xw.addr     = xa;
            xw.length   = 256 / 4;
            xw.first_be = 4'hF;
            xw.last_be  = 4'hF;
            xw.is_64bit = (xa[63:32] != 0);
            xw.start(env.v_seqr.rc_seqr_arr[0]);
            #2us;
        end

        // Drain
        #5us;

        `uvm_info("MR", "=== Multi-Root Route Test run_phase DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

    //=========================================================================
    // check_phase: in-root routing + per-EP delivery + clean scoreboards
    //=========================================================================
    function void check_phase(uvm_phase phase);
        bit ok = 1;
        int exp_per_dsp = wr_per_dsp;
        super.check_phase(phase);

        // 1. Cross-root violations == exactly the deliberate probe count.
        //    (All legitimate in-root traffic contributes 0; the one RC0->root1
        //    probe must be caught -> proves the detection mechanism actually fires.)
        if (env.sw.fabric.cross_root_violations != exp_cross) begin
            ok = 0;
            `uvm_error("MR_FAIL", $sformatf("cross_root_violations=%0d (expected %0d)",
                env.sw.fabric.cross_root_violations, exp_cross))
        end else begin
            `uvm_info("MR", $sformatf(
                "cross_root_violations=%0d OK (legit in-root + %0d caught probe)",
                env.sw.fabric.cross_root_violations, exp_cross), UVM_LOW)
        end

        // 1b. The cross-root probe (RC0 -> 0xA010_0000) must NOT have reached EP2.
        if (ep_saw(2, dsp_addr[2] + 64'h0010_0000)) begin
            ok = 0;
            `uvm_error("MR_FAIL",
                "EP2 received the cross-root probe write (it should have been dropped)")
        end else begin
            `uvm_info("MR", "cross-root probe correctly dropped (EP2 did not see it) OK",
                UVM_LOW)
        end

        // 2. Per-EP routed count: each DSP forwarded exactly its own root's writes.
        for (int i = 0; i < 4; i++) begin
            int got = env.sw.dsp[i].forwarded_count;
            if (got != exp_per_dsp) begin
                ok = 0;
                `uvm_error("MR_FAIL", $sformatf(
                    "DSP%0d forwarded_count=%0d, expected %0d (root %0d)",
                    i, got, exp_per_dsp, dsp_root[i]))
            end else begin
                `uvm_info("MR", $sformatf("DSP%0d forwarded_count=%0d OK (root %0d)",
                    i, got, dsp_root[i]), UVM_LOW)
            end
        end

        // 2b. Per-EP physical delivery: EP[i] mem_space must hold its OWN writes and
        //     must NOT hold any other EP's addresses (no cross-root leakage).
        for (int i = 0; i < 4; i++) begin
            // own addresses present
            for (int w = 0; w < wr_per_dsp; w++) begin
                bit [63:0] a = dsp_addr[i] + w * 256;
                if (!ep_saw(i, a)) begin
                    ok = 0;
                    `uvm_error("MR_FAIL", $sformatf(
                        "EP%0d did NOT receive its own write @0x%016h", i, a))
                end
            end
            // other EPs' base addresses absent (cross-root isolation)
            for (int j = 0; j < 4; j++) begin
                if (j == i) continue;
                if (ep_saw(i, dsp_addr[j])) begin
                    ok = 0;
                    `uvm_error("MR_FAIL", $sformatf(
                        "EP%0d wrongly received EP%0d's address 0x%016h (cross-root leak)",
                        i, j, dsp_addr[j]))
                end
            end
            `uvm_info("MR", $sformatf("EP%0d delivery OK (own writes present, no leak)",
                i), UVM_LOW)
        end

        // 3. Scoreboards clean (per root)
        for (int r = 0; r < 2; r++) begin
            if (r >= env.scbs.size() || env.scbs[r] == null) continue;
            if (env.scbs[r].mismatched != 0 || env.scbs[r].unexpected != 0) begin
                ok = 0;
                `uvm_error("MR_FAIL", $sformatf(
                    "scbs[%0d]: mismatched=%0d unexpected=%0d",
                    r, env.scbs[r].mismatched, env.scbs[r].unexpected))
            end else begin
                `uvm_info("MR", $sformatf("scbs[%0d] clean OK", r), UVM_LOW)
            end
        end

        if (ok) `uvm_info("MR", "MULTI_ROUTE PASSED", UVM_LOW)
        else    `uvm_info("MR", "MULTI_ROUTE FAILED", UVM_LOW)
    endfunction

    // Did EP[i]'s driver store byte 0 of address `a`?
    function bit ep_saw(int i, bit [63:0] a);
        if (env.ep_agents[i] == null || env.ep_agents[i].ep_driver == null) return 0;
        return env.ep_agents[i].ep_driver.mem_space.exists(a);
    endfunction

endclass
