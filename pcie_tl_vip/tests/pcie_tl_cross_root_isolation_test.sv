import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Cross-Root Isolation Test  (num_usp=2)
//
// Topology: 2 USP roots + 4 DSP/EP, auto dsp_owner=[0,0,1,1].
//   Root0 owns EP0 (0x8000_0000) / EP1 (0x8400_0000).
//   Root1 owns EP2 (0xA000_0000) / EP3 (0xA400_0000).
//
// RC0 (rc_seqr_arr[0]) deliberately issues N MWr into ROOT1's address domain
// (EP2 @ 0xA000_0000 and EP3 @ 0xA400_0000).  Every one of these is a cross-root
// access: the fabric must classify CROSS_ROOT, DROP it, and bump
// cross_root_violations.  Root1's EPs must NEVER receive any of RC0's writes.
//
// To keep UVM_ERROR deterministic we set cross_root_check_enable=0 so the drops
// are uvm_info (the violation COUNTER still increments).  PASS criterion:
//   - cross_root_violations == N (all cross attempts caught)
//   - EP2/EP3 mem_space does NOT contain any of RC0's cross addresses (no leak)
//   - total UVM_ERROR == 0
//=============================================================================
class pcie_tl_cross_root_isolation_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_cross_root_isolation_test)

    // RC0's deliberate cross-root targets (root1 domain).  4 writes total.
    bit [63:0] cross_addr[4];
    int        n_cross = 4;

    function new(string name = "pcie_tl_cross_root_isolation_test",
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
        sw_cfg.init_defaults();
        // Demote cross-root drop to uvm_info so UVM_ERROR stays 0; counter still bumps.
        sw_cfg.cross_root_check_enable = 0;
        cfg.switch_enable = 1;
        cfg.switch_cfg    = sw_cfg;

        cfg.use_unified_mem = 1'b0;       // sparse EP mem — prove physical delivery

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
        `uvm_info("ISO", "=== Cross-Root Isolation Test START (num_usp=2) ===", UVM_LOW)

        if (env.sw == null)
            `uvm_fatal("ISO", "env.sw is null -- switch not built")
        if (cfg.switch_cfg.num_usp != 2)
            `uvm_fatal("ISO", $sformatf("num_usp=%0d, expected 2", cfg.switch_cfg.num_usp))
        if (env.v_seqr.rc_seqr_arr.size() < 2)
            `uvm_fatal("ISO", $sformatf("rc_seqr_arr.size=%0d, expected >=2",
                env.v_seqr.rc_seqr_arr.size()))

        // Build RC0's cross-root targets: 2 distinct addrs each in EP2 and EP3 windows.
        cross_addr[0] = {32'h0, cfg.switch_cfg.ds_mem_base[2]};                 // EP2 base
        cross_addr[1] = {32'h0, cfg.switch_cfg.ds_mem_base[2]} + 64'h0001_0000; // EP2 +64K
        cross_addr[2] = {32'h0, cfg.switch_cfg.ds_mem_base[3]};                 // EP3 base
        cross_addr[3] = {32'h0, cfg.switch_cfg.ds_mem_base[3]} + 64'h0001_0000; // EP3 +64K

        foreach (cross_addr[i])
            `uvm_info("ISO", $sformatf(
                "RC0 cross-root probe %0d -> 0x%016h (root1 domain, expect drop)",
                i, cross_addr[i]), UVM_LOW)

        // RC0 issues all N MWr into root1's domain.
        for (int i = 0; i < n_cross; i++) begin
            automatic bit [63:0] a = cross_addr[i];
            automatic pcie_tl_mem_wr_seq wr;
            wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("rc0_xroot_%0d", i));
            wr.addr     = a;
            wr.length   = 256 / 4;
            wr.first_be = 4'hF;
            wr.last_be  = 4'hF;
            wr.is_64bit = (a[63:32] != 0);
            wr.start(env.v_seqr.rc_seqr_arr[0]);
            #1us;
        end

        #5us;
        `uvm_info("ISO", "=== Cross-Root Isolation Test run_phase DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask

    function void check_phase(uvm_phase phase);
        bit ok = 1;
        super.check_phase(phase);

        // 1. Every cross attempt was caught and dropped.
        if (env.sw.fabric.cross_root_violations != n_cross) begin
            ok = 0;
            `uvm_error("ISO_FAIL", $sformatf(
                "cross_root_violations=%0d (expected %0d)",
                env.sw.fabric.cross_root_violations, n_cross))
        end else begin
            `uvm_info("ISO", $sformatf("cross_root_violations=%0d OK (all %0d caught)",
                env.sw.fabric.cross_root_violations, n_cross), UVM_LOW)
        end

        // 2. Zero leak: root1's EPs must NOT hold ANY of RC0's cross addresses.
        if (ep_saw(2, cross_addr[0]) || ep_saw(2, cross_addr[1])) begin
            ok = 0;
            `uvm_error("ISO_FAIL", "EP2 (root1) received an RC0 cross-root write (leak)")
        end else begin
            `uvm_info("ISO", "EP2 zero-leak OK (no RC0 cross write present)", UVM_LOW)
        end
        if (ep_saw(3, cross_addr[2]) || ep_saw(3, cross_addr[3])) begin
            ok = 0;
            `uvm_error("ISO_FAIL", "EP3 (root1) received an RC0 cross-root write (leak)")
        end else begin
            `uvm_info("ISO", "EP3 zero-leak OK (no RC0 cross write present)", UVM_LOW)
        end

        // 3. Scoreboards clean.
        for (int r = 0; r < 2; r++) begin
            if (r >= env.scbs.size() || env.scbs[r] == null) continue;
            if (env.scbs[r].mismatched != 0 || env.scbs[r].unexpected != 0) begin
                ok = 0;
                `uvm_error("ISO_FAIL", $sformatf(
                    "scbs[%0d]: mismatched=%0d unexpected=%0d",
                    r, env.scbs[r].mismatched, env.scbs[r].unexpected))
            end
        end

        if (ok) `uvm_info("ISO", "ISO PASSED", UVM_LOW)
        else    `uvm_info("ISO", "ISO FAILED", UVM_LOW)
    endfunction

    function bit ep_saw(int i, bit [63:0] a);
        if (env.ep_agents[i] == null || env.ep_agents[i].ep_driver == null) return 0;
        return env.ep_agents[i].ep_driver.mem_space.exists(a);
    endfunction

endclass
