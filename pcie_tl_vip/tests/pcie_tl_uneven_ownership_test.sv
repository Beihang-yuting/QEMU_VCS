import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Uneven Ownership Test  (num_usp=2, num_ds_ports=4)
//
// Explicit dsp_owner = '{0,0,0,1}  (set BEFORE init_defaults so it is respected):
//   Root0 owns EP0, EP1, EP2   (3 DSPs)
//   Root1 owns EP3             (1 DSP)
// init_defaults() must NOT fatal (each root has >=1 DSP).
//
// Actual per-DSP addresses come from switch_cfg.ds_mem_base[] (read at runtime,
// not hardcoded).  With this owner map the config lays out:
//   root0 rbase=0x8000_0000: EP0,EP1,EP2 at +0/+64M/+128M
//   root1 rbase=0xA000_0000: EP3 at +0
//
// RC0 writes EP0/EP1/EP2 (its 3 owned EPs) -> all land.
// RC1 writes EP3 (its 1 owned EP)          -> lands.
// RC0 writes EP3's window (root1)           -> cross-root, dropped + counted.
//
// cross_root_check_enable=0 keeps UVM_ERROR deterministic (=0); counter bumps.
// check_phase:
//   - each owned write physically reached its EP (mem_space.exists)
//   - cross_root_violations == 1 (the single RC0->EP3 probe)
//   - EP3 did NOT receive RC0's cross write
//   - scoreboards clean
//=============================================================================
class pcie_tl_uneven_ownership_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_uneven_ownership_test)

    bit [63:0] dsp_addr[4];                  // resolved at runtime from ds_mem_base[]
    int        dsp_root[4] = '{0, 0, 0, 1};  // matches explicit dsp_owner
    bit [63:0] cross_probe_addr;             // RC0 -> EP3 window (cross)

    function new(string name = "pcie_tl_uneven_ownership_test",
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
        // EXPLICIT uneven owner map — must be set BEFORE init_defaults().
        sw_cfg.dsp_owner    = new[4];
        sw_cfg.dsp_owner    = '{0, 0, 0, 1};
        sw_cfg.init_defaults();
        sw_cfg.cross_root_check_enable = 0;
        cfg.switch_enable = 1;
        cfg.switch_cfg    = sw_cfg;

        cfg.use_unified_mem = 1'b0;

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
        `uvm_info("UNEVEN", "=== Uneven Ownership Test START (owner=0,0,0,1) ===", UVM_LOW)

        if (env.sw == null)
            `uvm_fatal("UNEVEN", "env.sw is null -- switch not built")
        if (env.v_seqr.rc_seqr_arr.size() < 2)
            `uvm_fatal("UNEVEN", $sformatf("rc_seqr_arr.size=%0d, expected >=2",
                env.v_seqr.rc_seqr_arr.size()))
        // Confirm owner map was respected.
        foreach (dsp_root[i])
            if (cfg.switch_cfg.dsp_owner[i] != dsp_root[i])
                `uvm_fatal("UNEVEN", $sformatf("dsp_owner[%0d]=%0d, expected %0d",
                    i, cfg.switch_cfg.dsp_owner[i], dsp_root[i]))

        // Resolve real per-DSP base addresses from config (NOT hardcoded).
        for (int i = 0; i < 4; i++) begin
            dsp_addr[i] = {32'h0, cfg.switch_cfg.ds_mem_base[i]};
            `uvm_info("UNEVEN", $sformatf("DSP%0d base=0x%016h owner root %0d",
                i, dsp_addr[i], dsp_root[i]), UVM_LOW)
        end

        // Each owning root writes each of its EPs.
        for (int i = 0; i < 4; i++) begin
            automatic int        di = i;
            automatic int        rc = dsp_root[i];
            automatic bit [63:0] a  = dsp_addr[di];
            automatic pcie_tl_mem_wr_seq wr;
            wr = pcie_tl_mem_wr_seq::type_id::create(
                     $sformatf("rc%0d_wr_ep%0d", rc, di));
            wr.addr     = a;
            wr.length   = 256 / 4;
            wr.first_be = 4'hF;
            wr.last_be  = 4'hF;
            wr.is_64bit = (a[63:32] != 0);
            wr.start(env.v_seqr.rc_seqr_arr[rc]);
            #1us;
        end

        // Negative probe: RC0 (root0) writes EP3's window (root1) -> cross-root drop.
        begin
            automatic pcie_tl_mem_wr_seq xw;
            cross_probe_addr = dsp_addr[3] + 64'h0001_0000;  // distinct from EP3's own write
            `uvm_info("UNEVEN", $sformatf(
                "RC0 cross probe -> 0x%016h (EP3/root1 window, expect drop)",
                cross_probe_addr), UVM_LOW)
            xw = pcie_tl_mem_wr_seq::type_id::create("rc0_xroot_ep3");
            xw.addr     = cross_probe_addr;
            xw.length   = 256 / 4;
            xw.first_be = 4'hF;
            xw.last_be  = 4'hF;
            xw.is_64bit = (cross_probe_addr[63:32] != 0);
            xw.start(env.v_seqr.rc_seqr_arr[0]);
            #2us;
        end

        #5us;
        `uvm_info("UNEVEN", "=== Uneven Ownership Test run_phase DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

    function void check_phase(uvm_phase phase);
        bit ok = 1;
        super.check_phase(phase);

        // 1. Each owned write physically reached its EP.
        for (int i = 0; i < 4; i++) begin
            if (!ep_saw(i, dsp_addr[i])) begin
                ok = 0;
                `uvm_error("UNEVEN_FAIL", $sformatf(
                    "EP%0d (root %0d) did NOT receive its own write @0x%016h",
                    i, dsp_root[i], dsp_addr[i]))
            end else begin
                `uvm_info("UNEVEN", $sformatf("EP%0d delivery OK (root %0d)",
                    i, dsp_root[i]), UVM_LOW)
            end
        end

        // 2. Exactly one cross-root violation (the RC0->EP3 probe).
        if (env.sw.fabric.cross_root_violations != 1) begin
            ok = 0;
            `uvm_error("UNEVEN_FAIL", $sformatf(
                "cross_root_violations=%0d (expected 1)",
                env.sw.fabric.cross_root_violations))
        end else begin
            `uvm_info("UNEVEN", "cross_root_violations=1 OK", UVM_LOW)
        end

        // 3. EP3 must NOT hold the cross probe.
        if (ep_saw(3, cross_probe_addr)) begin
            ok = 0;
            `uvm_error("UNEVEN_FAIL",
                "EP3 received RC0's cross-root probe (should have been dropped)")
        end else begin
            `uvm_info("UNEVEN", "EP3 cross-root probe correctly dropped OK", UVM_LOW)
        end

        // 4. Scoreboards clean.
        for (int r = 0; r < 2; r++) begin
            if (r >= env.scbs.size() || env.scbs[r] == null) continue;
            if (env.scbs[r].mismatched != 0 || env.scbs[r].unexpected != 0) begin
                ok = 0;
                `uvm_error("UNEVEN_FAIL", $sformatf(
                    "scbs[%0d]: mismatched=%0d unexpected=%0d",
                    r, env.scbs[r].mismatched, env.scbs[r].unexpected))
            end
        end

        if (ok) `uvm_info("UNEVEN", "UNEVEN PASSED", UVM_LOW)
        else    `uvm_info("UNEVEN", "UNEVEN FAILED", UVM_LOW)
    endfunction

    function bit ep_saw(int i, bit [63:0] a);
        if (env.ep_agents[i] == null || env.ep_agents[i].ep_driver == null) return 0;
        return env.ep_agents[i].ep_driver.mem_space.exists(a);
    endfunction

endclass
