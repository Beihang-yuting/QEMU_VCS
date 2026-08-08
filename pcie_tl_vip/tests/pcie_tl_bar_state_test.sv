import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_tl_device_profile_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_cfg_write_recorder extends pcie_cfg_callback;
    `uvm_object_utils(pcie_tl_cfg_write_recorder)

    int write_count;
    bit [11:0] last_addr;
    bit [31:0] last_data;
    bit [3:0] last_be;

    function new(string name = "pcie_tl_cfg_write_recorder");
        super.new(name);
    endfunction

    virtual function void on_read(bit [11:0] addr, ref bit [31:0] data);
    endfunction

    virtual function void on_write(
        bit [11:0] addr,
        bit [31:0] data,
        bit [3:0] be
    );
        write_count++;
        last_addr = addr;
        last_data = data;
        last_be = be;
    endfunction

    function void clear_write_history();
        write_count = 0;
        last_addr = '0;
        last_data = '0;
        last_be = '0;
    endfunction
endclass

class pcie_tl_bar_state_proxy extends pcie_tl_config_proxy;
    `uvm_component_utils(pcie_tl_bar_state_proxy)

    int vf_enable_notifications;
    int vf_disable_notifications;
    int vf_lifecycle_notifications;
    bit last_lifecycle_enable;
    int last_lifecycle_pf_index;
    int last_lifecycle_num_vfs;
    pcie_tl_sriov_cap last_lifecycle_sc;
    bit last_lifecycle_serialized_valid;
    bit [15:0] last_lifecycle_serialized_control;

    function new(string name = "pcie_tl_bar_state_proxy",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void notify_vf_lifecycle(
        bit enable,
        int pf_index,
        int num_vfs,
        pcie_tl_sriov_cap sc
    );
        vf_lifecycle_notifications++;
        last_lifecycle_enable  = enable;
        last_lifecycle_pf_index = pf_index;
        last_lifecycle_num_vfs = num_vfs;
        last_lifecycle_sc      = sc;
        last_lifecycle_serialized_valid =
            sc != null && sc.data.size() > 5;
        if (last_lifecycle_serialized_valid)
            last_lifecycle_serialized_control = {sc.data[5], sc.data[4]};
        else
            last_lifecycle_serialized_control = '0;
        if (enable)
            vf_enable_notifications++;
        else
            vf_disable_notifications++;
    endfunction
endclass

class pcie_tl_bar_state_test extends uvm_test;
    `uvm_component_utils(pcie_tl_bar_state_test)

    pcie_tl_func_manager mgr;
    pcie_tl_bar_state_proxy proxy;

    function new(string name = "pcie_tl_bar_state_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        proxy = pcie_tl_bar_state_proxy::type_id::create("proxy", this);
    endfunction

    function void expect_generation(
        string label,
        longint unsigned actual,
        longint unsigned expected
    );
        if (actual != expected)
            `uvm_error("BAR_STATE", $sformatf(
                "%s: generation=%0d expected=%0d", label, actual, expected))
    endfunction

    function void expect_cfg_callback(
        string label,
        pcie_tl_cfg_write_recorder recorder,
        int expected_count,
        bit [11:0] expected_addr = '0,
        bit [31:0] expected_data = '0,
        bit [3:0] expected_be = '0
    );
        if (recorder.write_count != expected_count)
            `uvm_error("BAR_STATE", $sformatf(
                "%s: callback count=%0d expected=%0d",
                label, recorder.write_count, expected_count))
        if (expected_count > 0 &&
            (recorder.last_addr != expected_addr ||
             recorder.last_data != expected_data ||
             recorder.last_be != expected_be))
            `uvm_error("BAR_STATE", $sformatf(
                "%s: callback addr/data/be=%03h/%08h/%01h expected=%03h/%08h/%01h",
                label, recorder.last_addr, recorder.last_data, recorder.last_be,
                expected_addr, expected_data, expected_be))
    endfunction

    function void expect_owner_bar_enable(
        string label,
        pcie_tl_func_context ctx,
        bit expected
    );
        for (int bar = 0; bar < 6; bar++) begin
            bit owner_enabled = expected && ctx.bar_owner[bar] == bar &&
                                ctx.bar_size[bar] != 0;
            if (ctx.bar_enable[bar] != owner_enabled)
                `uvm_error("BAR_STATE", $sformatf(
                    "%s: BAR%0d enable=%0d expected=%0d owner=%0d size=%0h",
                    label, bar, ctx.bar_enable[bar], owner_enabled,
                    ctx.bar_owner[bar], ctx.bar_size[bar]))
        end
        if (ctx.bar_enable[1] || ctx.bar_enable[3] || ctx.bar_enable[5])
            `uvm_error("BAR_STATE", $sformatf(
                "%s: upper BAR slots became independently enabled", label))
    endfunction

    function void expect_vf_lut(string label, int enabled_count);
        for (int vf = 0; vf < mgr.max_vfs_per_pf; vf++) begin
            bit should_enable = vf < enabled_count;
            pcie_tl_func_context lut_ctx =
                mgr.lookup_by_bdf(mgr.vf_ctx[0][vf].bdf);
            bit lut_matches = lut_ctx == mgr.vf_ctx[0][vf];
            if (mgr.vf_ctx[0][vf].enabled != should_enable ||
                (should_enable && !lut_matches) ||
                (!should_enable && lut_ctx != null))
                `uvm_error("BAR_STATE", $sformatf(
                    "%s: VF%0d enabled=%0d lut_matches=%0d expected=%0d",
                    label, vf, mgr.vf_ctx[0][vf].enabled, lut_matches,
                    should_enable))
        end
    endfunction

    function bit is_current_lut_key(bit [15:0] bdf, int enabled_vfs);
        if (bdf == mgr.pf_ctx[0].bdf)
            return 1;
        for (int vf = 0; vf < enabled_vfs; vf++)
            if (bdf == mgr.vf_ctx[0][vf].bdf)
                return 1;
        return 0;
    endfunction

    function bit is_manager_current_lut_key(
        pcie_tl_func_manager check_mgr,
        bit [15:0] bdf,
        int enabled_vfs
    );
        if (bdf == check_mgr.pf_ctx[0].bdf)
            return 1;
        for (int vf = 0; vf < enabled_vfs; vf++)
            if (bdf == check_mgr.vf_ctx[0][vf].bdf)
                return 1;
        return 0;
    endfunction

    task run_phase(uvm_phase phase);
        bit [15:0] pf_bdf;
        int sriov_dw;
        longint unsigned g0;
        bit [31:0] cfg_dw;
        bit [31:0] old_cfg_dw;
        bit [15:0] old_pf_bdf;
        bit [15:0] stale_disabled_vf_bdf;
        bit [15:0] old_vf_bdf[];
        int enable_notifications;
        int disable_notifications;
        int lifecycle_notifications;
        pcie_tl_func_manager overlap_mgr;
        pcie_tl_func_manager stale_mgr;
        pcie_tl_func_manager direct_mgr;
        pcie_tl_func_manager callback_mgr;
        pcie_tl_cfg_write_recorder control_cb;
        pcie_tl_cfg_write_recorder num_vfs_cb;
        pcie_tl_cfg_write_recorder direct_control_cb;
        pcie_tl_cfg_write_recorder direct_num_vfs_cb;
        bit [15:0] callback_pf_bdf;
        int callback_sriov_dw;

        phase.raise_objection(this);

        mgr = pcie_tl_func_manager::type_id::create("mgr");
        mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        expect_generation("pre-build generation", mgr.config_generation, 0);
        mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        expect_generation("first topology generation", mgr.config_generation, 1);
        g0 = mgr.config_generation;
        mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        expect_generation("cached initial topology invalidated by rebuild",
                          mgr.config_generation, g0 + 1);
        proxy.func_mgr = mgr;
        proxy.multi_function_mode = 1;
        proxy.bypass_enable = 1;
        pf_bdf = mgr.pf_ctx[0].bdf;

        // A guest write is externally observable exactly once at its target
        // DWORD. Internal SR-IOV state reconciliation must neither duplicate
        // that callback nor synthesize a callback for the neighboring DWORD.
        callback_mgr = pcie_tl_func_manager::type_id::create("callback_mgr");
        callback_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        callback_mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        proxy.func_mgr = callback_mgr;
        callback_pf_bdf = callback_mgr.pf_ctx[0].bdf;
        callback_sriov_dw = int'(callback_mgr.sriov_caps[0].offset >> 2);
        control_cb = pcie_tl_cfg_write_recorder::type_id::create("control_cb");
        num_vfs_cb = pcie_tl_cfg_write_recorder::type_id::create("num_vfs_cb");
        callback_mgr.pf_ctx[0].cfg_mgr.register_callback(
            callback_mgr.sriov_caps[0].offset + 12'h008, control_cb);
        callback_mgr.pf_ctx[0].cfg_mgr.register_callback(
            callback_mgr.sriov_caps[0].offset + 12'h010, num_vfs_cb);

        old_cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 4) << 2);
        control_cb.clear_write_history();
        num_vfs_cb.clear_write_history();
        void'(proxy.handle_cfg_write_bdf(
            callback_pf_bdf, callback_sriov_dw + 4, 32'h0000_0002, 1, 1));
        cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 4) << 2);
        if (callback_mgr.sriov_caps[0].num_vfs != 16 ||
            cfg_dw[15:0] != 16)
            `uvm_error("BAR_STATE", "partial NumVFs clamp state/raw mismatch")
        expect_cfg_callback("guest partial NumVFs target", num_vfs_cb, 1,
            callback_mgr.sriov_caps[0].offset + 12'h010,
            {old_cfg_dw[31:16], 16'd16}, 4'b0011);
        expect_cfg_callback("guest partial NumVFs unrelated Control", control_cb, 0);

        // All mutable Control bits must be mirrored before lifecycle handling.
        // A subsequent same-value NumVFs write must not reconstruct 0x9 as 0x1.
        control_cb.clear_write_history();
        num_vfs_cb.clear_write_history();
        void'(proxy.handle_cfg_write_bdf(
            callback_pf_bdf, callback_sriov_dw + 2, 32'h0000_0009, 0, 2));
        cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 2) << 2);
        if (!callback_mgr.sriov_caps[0].vf_enable ||
            !callback_mgr.sriov_caps[0].ari_capable ||
            callback_mgr.sriov_caps[0].vf_migration_enable ||
            callback_mgr.sriov_caps[0].vf_mse ||
            cfg_dw[15:0] != 16'h0009)
            `uvm_error("BAR_STATE", "guest Control 0x9 state/raw mirror mismatch")
        expect_cfg_callback("guest Control enable target", control_cb, 1,
            callback_mgr.sriov_caps[0].offset + 12'h008,
            32'h0000_0009, 4'b0011);
        expect_cfg_callback("guest Control enable unrelated NumVFs", num_vfs_cb, 0);

        old_cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 4) << 2);
        control_cb.clear_write_history();
        num_vfs_cb.clear_write_history();
        void'(proxy.handle_cfg_write_bdf(
            callback_pf_bdf, callback_sriov_dw + 4, 32'd16, 0, 2));
        cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 2) << 2);
        if (!callback_mgr.sriov_caps[0].vf_enable ||
            !callback_mgr.sriov_caps[0].ari_capable ||
            cfg_dw[15:0] != 16'h0009)
            `uvm_error("BAR_STATE", "same NumVFs write corrupted Control 0x9")
        expect_cfg_callback("same NumVFs target", num_vfs_cb, 1,
            callback_mgr.sriov_caps[0].offset + 12'h010,
            {old_cfg_dw[31:16], 16'd16}, 4'b0011);
        expect_cfg_callback("same NumVFs unrelated Control", control_cb, 0);

        control_cb.clear_write_history();
        num_vfs_cb.clear_write_history();
        void'(proxy.handle_cfg_write_bdf(
            callback_pf_bdf, callback_sriov_dw + 2, 32'h0000_0009, 0, 2));
        expect_cfg_callback("repeated guest Control target", control_cb, 1,
            callback_mgr.sriov_caps[0].offset + 12'h008,
            32'h0000_0009, 4'b0011);
        expect_cfg_callback("repeated guest Control unrelated NumVFs", num_vfs_cb, 0);

        // Active NumVFs changes reject the entire guest write before callbacks.
        old_cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 4) << 2);
        control_cb.clear_write_history();
        num_vfs_cb.clear_write_history();
        void'(proxy.handle_cfg_write_bdf(
            callback_pf_bdf, callback_sriov_dw + 4,
            {old_cfg_dw[31:16] ^ 16'h5a5a, 16'd32}, 0, 4));
        cfg_dw = callback_mgr.cfg_read(
            callback_pf_bdf, (callback_sriov_dw + 4) << 2);
        if (cfg_dw != old_cfg_dw || callback_mgr.sriov_caps[0].num_vfs != 16)
            `uvm_error("BAR_STATE", "active 16/request32 callback case was not atomic")
        expect_cfg_callback("rejected active NumVFs target", num_vfs_cb, 0);
        expect_cfg_callback("rejected active NumVFs unrelated Control", control_cb, 0);

        control_cb.clear_write_history();
        num_vfs_cb.clear_write_history();
        void'(proxy.handle_cfg_write_bdf(
            callback_pf_bdf, callback_sriov_dw + 2, 32'h0000_0008, 0, 2));
        expect_cfg_callback("guest Control disable edge target", control_cb, 1,
            callback_mgr.sriov_caps[0].offset + 12'h008,
            32'h0000_0008, 4'b0011);
        expect_cfg_callback("guest Control disable unrelated NumVFs", num_vfs_cb, 0);
        proxy.func_mgr = mgr;

        // One Command write can change MSE and BME together, but only the MSE
        // edge invalidates Host-to-BAR routing.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0006, 0, 4));
        if (!mgr.pf_ctx[0].memory_space_en ||
            !mgr.pf_ctx[0].bus_master_en ||
            !mgr.pf_ctx[0].bar_enable[0] ||
            !mgr.pf_ctx[0].bar_enable[2] ||
            !mgr.pf_ctx[0].bar_enable[4] ||
            mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "Command.MSE/BME was not mirrored exactly")
        expect_owner_bar_enable("Command.MSE set", mgr.pf_ctx[0], 1'b1);

        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0006, 0, 4));
        expect_generation("repeated Command 0x6", mgr.config_generation, g0);

        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0002, 0, 4));
        if (mgr.pf_ctx[0].bus_master_en || mgr.config_generation != g0)
            `uvm_error("BAR_STATE", "BME-only change must not invalidate BAR routing")
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0002, 0, 4));
        expect_generation("repeated Command 0x2", mgr.config_generation, g0);

        // A packed write to the upper Command byte must preserve the MSE/BME
        // bits in byte zero and therefore remain a routing no-op.
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_00ff, 1, 1));
        if (!mgr.pf_ctx[0].memory_space_en || mgr.pf_ctx[0].bus_master_en)
            `uvm_error("BAR_STATE", "partial Command byte write corrupted MSE/BME")
        expect_generation("upper Command byte write", mgr.config_generation, g0);

        // A sizing probe changes only the transient sizing response. Each
        // effective low/high assignment changes the one canonical 64-bit base.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 6, 32'hffff_ffff, 0, 4));
        if (mgr.config_generation != g0)
            `uvm_error("BAR_STATE", "BAR sizing write changed the active generation")

        void'(proxy.handle_cfg_write_bdf(pf_bdf, 6, 32'h0800_000c, 0, 4));
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 7, 32'h0000_0009, 0, 4));
        if (mgr.pf_ctx[0].bar_base[2] != 64'h0000_0009_0800_0000 ||
            mgr.config_generation != g0 + 2)
            `uvm_error("BAR_STATE", "paired BAR2 assignment/generation mismatch")
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 6, 32'h0800_000c, 0, 4));
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 7, 32'h0000_0009, 0, 4));
        expect_generation("repeated PF BAR2 pair", mgr.config_generation, g0);

        // Clearing MSE disables all owner apertures once; re-setting it enables
        // only the owner slots once. Upper halves never route independently.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0000, 0, 1));
        if (mgr.pf_ctx[0].memory_space_en || mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "Command.MSE clear edge mismatch")
        expect_owner_bar_enable("Command.MSE clear", mgr.pf_ctx[0], 1'b0);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0000, 0, 1));
        expect_generation("repeated Command.MSE clear", mgr.config_generation, g0 + 1);

        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0002, 0, 1));
        if (!mgr.pf_ctx[0].memory_space_en || mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "Command.MSE set edge mismatch")
        expect_owner_bar_enable("Command.MSE re-set", mgr.pf_ctx[0], 1'b1);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0002, 0, 1));
        expect_generation("repeated Command.MSE set", mgr.config_generation, g0 + 1);

        sriov_dw = int'(mgr.sriov_caps[0].offset >> 2);

        // SR-IOV VF BARs use the same canonical paired-base and sizing rules.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 9, 32'hffff_ffff, 0, 4));
        expect_generation("VF BAR sizing", mgr.config_generation, g0);
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 9, 32'h1000_000c, 0, 4));
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 10, 32'h0000_000a, 0, 4));
        if (mgr.sriov_caps[0].vf_bar[0] != 64'h0000_000a_1000_0000 ||
            mgr.config_generation != g0 + 2)
            `uvm_error("BAR_STATE", "paired VF BAR0 assignment/generation mismatch")
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 9, 32'h1000_000c, 0, 4));
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 10, 32'h0000_000a, 0, 4));
        expect_generation("repeated VF BAR0 pair", mgr.config_generation, g0);

        // NumVFs, VFE, and VF MSE are three independent route-state edges.
        g0 = mgr.config_generation;
        enable_notifications = proxy.vf_enable_notifications;
        disable_notifications = proxy.vf_disable_notifications;
        lifecycle_notifications = proxy.vf_lifecycle_notifications;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd32, 0, 2));
        cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 4) << 2);
        if (mgr.sriov_caps[0].num_vfs != 16 || cfg_dw[15:0] != 16)
            `uvm_error("BAR_STATE",
                       "oversized NumVFs was not clamped into state/raw image")
        expect_generation("accepted oversized NumVFs",
                          mgr.config_generation, g0 + 1);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_001b, 0, 2));
        cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 4) << 2);
        if (!mgr.sriov_caps[0].vf_enable || !mgr.sriov_caps[0].vf_mse ||
            mgr.sriov_caps[0].num_vfs != 16 ||
            cfg_dw[15:0] != 16 ||
            mgr.config_generation != g0 + 3)
            `uvm_error("BAR_STATE", "SR-IOV state was not mirrored")
        if (proxy.vf_enable_notifications != enable_notifications + 1 ||
            proxy.vf_disable_notifications != disable_notifications)
            `uvm_error("BAR_STATE", "normal VFE set did not notify exactly once")
        if (proxy.vf_lifecycle_notifications != lifecycle_notifications + 1 ||
            !proxy.last_lifecycle_enable ||
            proxy.last_lifecycle_pf_index != 0 ||
            proxy.last_lifecycle_num_vfs != 16 ||
            proxy.last_lifecycle_sc != mgr.sriov_caps[0] ||
            !proxy.last_lifecycle_serialized_valid ||
            proxy.last_lifecycle_serialized_control != 16'h001b ||
            proxy.last_lifecycle_serialized_control[0] !=
                proxy.last_lifecycle_sc.vf_enable ||
            proxy.last_lifecycle_serialized_control[1] !=
                proxy.last_lifecycle_sc.vf_migration_enable ||
            proxy.last_lifecycle_serialized_control[3] !=
                proxy.last_lifecycle_sc.ari_capable ||
            proxy.last_lifecycle_serialized_control[4] !=
                proxy.last_lifecycle_sc.vf_mse)
            `uvm_error("BAR_STATE", "normal VFE enable lifecycle payload mismatch")
        expect_vf_lut("SR-IOV enabled", 16);

        enable_notifications = proxy.vf_enable_notifications;
        disable_notifications = proxy.vf_disable_notifications;
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd16, 0, 2));
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_001b, 0, 2));
        expect_generation("repeated NumVFs/Control", mgr.config_generation, g0);
        if (proxy.vf_enable_notifications != enable_notifications ||
            proxy.vf_disable_notifications != disable_notifications)
            `uvm_error("BAR_STATE", "repeated VFE set emitted a notification")

        // NumVFs is programmed before VFE. Once VFE is active, reject an
        // attempted count change so the register, enabled contexts, LUT, and
        // generation cannot diverge.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd8, 0, 2));
        cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 4) << 2);
        if (mgr.sriov_caps[0].num_vfs != 16 || cfg_dw[15:0] != 16)
            `uvm_error("BAR_STATE", "active NumVFs write was not rejected atomically")
        expect_vf_lut("active NumVFs write rejected", 16);
        expect_generation("active NumVFs write rejected", mgr.config_generation, g0);

        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_000b, 0, 2));
        if (!mgr.sriov_caps[0].vf_enable || mgr.sriov_caps[0].vf_mse ||
            mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "VF MSE clear edge mismatch")
        expect_vf_lut("VF MSE clear preserves enabled VFs", 16);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_000b, 0, 2));
        expect_generation("repeated VF MSE clear", mgr.config_generation, g0 + 1);

        g0 = mgr.config_generation;
        enable_notifications = proxy.vf_enable_notifications;
        disable_notifications = proxy.vf_disable_notifications;
        lifecycle_notifications = proxy.vf_lifecycle_notifications;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_000a, 0, 2));
        if (mgr.sriov_caps[0].vf_enable || mgr.sriov_caps[0].vf_mse ||
            mgr.sriov_caps[0].num_vfs != 16 ||
            mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "VFE clear edge/state mismatch")
        if (proxy.vf_enable_notifications != enable_notifications ||
            proxy.vf_disable_notifications != disable_notifications + 1)
            `uvm_error("BAR_STATE", "normal VFE clear did not notify exactly once")
        if (proxy.vf_lifecycle_notifications != lifecycle_notifications + 1 ||
            proxy.last_lifecycle_enable ||
            proxy.last_lifecycle_pf_index != 0 ||
            proxy.last_lifecycle_num_vfs != 16 ||
            proxy.last_lifecycle_sc != mgr.sriov_caps[0] ||
            !proxy.last_lifecycle_serialized_valid ||
            proxy.last_lifecycle_serialized_control != 16'h000a ||
            proxy.last_lifecycle_serialized_control[0] !=
                proxy.last_lifecycle_sc.vf_enable ||
            proxy.last_lifecycle_serialized_control[1] !=
                proxy.last_lifecycle_sc.vf_migration_enable ||
            proxy.last_lifecycle_serialized_control[3] !=
                proxy.last_lifecycle_sc.ari_capable ||
            proxy.last_lifecycle_serialized_control[4] !=
                proxy.last_lifecycle_sc.vf_mse)
            `uvm_error("BAR_STATE", "normal VFE disable lifecycle payload mismatch")
        expect_vf_lut("VFE clear", 0);
        enable_notifications = proxy.vf_enable_notifications;
        disable_notifications = proxy.vf_disable_notifications;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0000, 0, 2));
        expect_generation("repeated VFE clear", mgr.config_generation, g0 + 1);
        if (proxy.vf_enable_notifications != enable_notifications ||
            proxy.vf_disable_notifications != disable_notifications)
            `uvm_error("BAR_STATE", "repeated VFE clear emitted a notification")

        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0011, 0, 2));
        if (!mgr.sriov_caps[0].vf_enable || !mgr.sriov_caps[0].vf_mse ||
            mgr.config_generation != g0 + 2)
            `uvm_error("BAR_STATE", "combined VFE/VF MSE set edge mismatch")
        expect_vf_lut("VFE/VF MSE re-enabled", 16);

        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0000, 0, 2));
        if (mgr.sriov_caps[0].vf_enable || mgr.sriov_caps[0].vf_mse ||
            mgr.config_generation != g0 + 2)
            `uvm_error("BAR_STATE", "combined VFE/VF MSE clear edge mismatch")
        expect_vf_lut("VFE/VF MSE disabled", 0);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0000, 0, 2));
        expect_generation("repeated disabled Control", mgr.config_generation, g0 + 2);

        // A zero-count VFE edge is still maintained state, but it enables no
        // function and leaves no LUT entry. Repeated writes remain no-ops.
        g0 = mgr.config_generation;
        enable_notifications = proxy.vf_enable_notifications;
        disable_notifications = proxy.vf_disable_notifications;
        lifecycle_notifications = proxy.vf_lifecycle_notifications;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd0, 0, 2));
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0001, 0, 2));
        if (!mgr.sriov_caps[0].vf_enable || mgr.sriov_caps[0].num_vfs != 0 ||
            mgr.config_generation != g0 + 2)
            `uvm_error("BAR_STATE", "zero-NumVFs VFE set edge mismatch")
        if (proxy.vf_enable_notifications != enable_notifications ||
            proxy.vf_disable_notifications != disable_notifications ||
            proxy.vf_lifecycle_notifications != lifecycle_notifications)
            `uvm_error("BAR_STATE", "zero-NumVFs VFE set emitted a notification")
        expect_vf_lut("zero-NumVFs VFE set", 0);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0001, 0, 2));
        expect_generation("repeated zero-NumVFs VFE set",
                          mgr.config_generation, g0 + 2);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0000, 0, 2));
        expect_generation("zero-NumVFs VFE clear",
                          mgr.config_generation, g0 + 3);
        cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 2) << 2);
        if (mgr.sriov_caps[0].vf_enable || mgr.sriov_caps[0].vf_mse ||
            cfg_dw[15:0] != 16'h0000)
            `uvm_error("BAR_STATE", "zero-NumVFs VFE clear left Control state set")
        if (proxy.vf_enable_notifications != enable_notifications ||
            proxy.vf_disable_notifications != disable_notifications ||
            proxy.vf_lifecycle_notifications != lifecycle_notifications)
            `uvm_error("BAR_STATE", "zero-NumVFs VFE clear emitted a notification")
        expect_vf_lut("zero-NumVFs VFE clear", 0);

        // Leave VFs enabled across runtime rekey and then reuse this manager.
        // Rebuild must discard old LUT entries while advancing the existing
        // generation and reopening runtime BDF discovery.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd16, 0, 2));
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0001, 0, 2));
        if (mgr.config_generation != g0 + 2)
            `uvm_error("BAR_STATE", "VF setup before rebuild edge mismatch")
        expect_vf_lut("VFs enabled before rebuild", 16);

        old_pf_bdf = mgr.pf_ctx[0].bdf;
        old_vf_bdf = new[mgr.max_vfs_per_pf];
        for (int vf = 0; vf < mgr.max_vfs_per_pf; vf++)
            old_vf_bdf[vf] = mgr.vf_ctx[0][vf].bdf;
        g0 = mgr.config_generation;
        if (!mgr.bind_runtime_pf_base(16'h0200) ||
            mgr.pf_ctx[0].bdf != 16'h0200 ||
            mgr.sriov_caps[0].pf_bdf != 16'h0200 ||
            mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "runtime BDF bind did not invalidate routing once")
        if (mgr.lookup_by_bdf(mgr.pf_ctx[0].bdf) != mgr.pf_ctx[0])
            `uvm_error("BAR_STATE", "runtime BDF bind mapped the new PF key incorrectly")
        if (!is_current_lut_key(old_pf_bdf, 16) &&
            mgr.lookup_by_bdf(old_pf_bdf) != null)
            `uvm_error("BAR_STATE", "runtime BDF bind retained the old PF LUT key")
        for (int vf = 0; vf < mgr.max_vfs_per_pf; vf++) begin
            if (mgr.vf_ctx[0][vf].bdf != mgr.sriov_caps[0].get_vf_rid(vf))
                `uvm_error("BAR_STATE", $sformatf(
                    "runtime BDF bind left VF%0d context BDF stale", vf))
            if (mgr.lookup_by_bdf(mgr.vf_ctx[0][vf].bdf) != mgr.vf_ctx[0][vf])
                `uvm_error("BAR_STATE", $sformatf(
                    "runtime BDF bind mapped VF%0d to the wrong object", vf))
            if (!is_current_lut_key(old_vf_bdf[vf], 16) &&
                mgr.lookup_by_bdf(old_vf_bdf[vf]) != null)
                `uvm_error("BAR_STATE", $sformatf(
                    "runtime BDF bind retained old VF%0d LUT key", vf))
        end
        g0 = mgr.config_generation;
        if (!mgr.bind_runtime_pf_base(16'h0200))
            `uvm_error("BAR_STATE", "repeated runtime BDF bind was rejected")
        expect_generation("repeated runtime BDF bind", mgr.config_generation, g0);

        g0 = mgr.config_generation;
        mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        expect_generation("rebuilt topology generation",
                          mgr.config_generation, g0 + 1);
        if (mgr.runtime_bdf_bound || mgr.runtime_pf_base_bdf != 16'h0000)
            `uvm_error("BAR_STATE", "topology rebuild retained runtime BDF binding")
        if (mgr.pf_ctx[0].bdf != 16'h0200 ||
            mgr.lookup_by_bdf(16'h0200) != mgr.pf_ctx[0])
            `uvm_error("BAR_STATE", "topology rebuild lost the current PF base")
        expect_vf_lut("fresh topology has no stale VF LUT", 0);
        g0 = mgr.config_generation;
        if (!mgr.bind_runtime_pf_base(16'h0300) ||
            mgr.pf_ctx[0].bdf != 16'h0300 ||
            mgr.sriov_caps[0].pf_bdf != 16'h0300 ||
            mgr.lookup_by_bdf(16'h0300) != mgr.pf_ctx[0] ||
            mgr.lookup_by_bdf(16'h0200) != null ||
            mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "post-rebuild runtime BDF rebind state mismatch")
        expect_vf_lut("post-rebuild runtime BDF rebind", 0);
        g0 = mgr.config_generation;
        if (!mgr.bind_runtime_pf_base(16'h0300))
            `uvm_error("BAR_STATE", "repeated post-rebuild BDF bind was rejected")
        expect_generation("repeated post-rebuild runtime BDF bind",
                          mgr.config_generation, g0);

        // Legacy SR-IOV leaves Function Dependency Link writable. A rejected
        // active NumVFs full-DWORD write must therefore return before the
        // generic config path can change either half of the raw DWORD.
        mgr.cfg_profile = PCIE_CFG_PROFILE_LEGACY;
        mgr.build_topology(0, 1, 16, 16'h1234, 16'h5678, 16'h9abc);
        proxy.func_mgr = mgr;
        pf_bdf = mgr.pf_ctx[0].bdf;
        sriov_dw = int'(mgr.sriov_caps[0].offset >> 2);
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd16, 0, 2));
        void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0001, 0, 2));
        old_cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 4) << 2);
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 4,
            {old_cfg_dw[31:16] ^ 16'h5a5a, 16'd8}, 0, 4));
        cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 4) << 2);
        if (cfg_dw != old_cfg_dw || mgr.sriov_caps[0].num_vfs != 16)
            `uvm_error("BAR_STATE", "active NumVFs full-DWORD write was not atomic")
        expect_vf_lut("active NumVFs full-DWORD write rejected", 16);
        expect_generation("active NumVFs full-DWORD write rejected",
                          mgr.config_generation, g0);

        // Active atomic rejection is based on the raw request, not its
        // inactive-path accepted value. Requested 32 would clamp to the active
        // 16, but must still reject the whole DWORD so writable FDL is stable.
        g0 = mgr.config_generation;
        void'(proxy.handle_cfg_write_bdf(
            pf_bdf, sriov_dw + 4,
            {old_cfg_dw[31:16] ^ 16'h3c3c, 16'd32}, 0, 4));
        cfg_dw = mgr.cfg_read(pf_bdf, (sriov_dw + 4) << 2);
        if (cfg_dw != old_cfg_dw || mgr.sriov_caps[0].num_vfs != 16)
            `uvm_error("BAR_STATE",
                       "active oversized NumVFs full-DWORD write was not atomic")
        expect_vf_lut("active oversized NumVFs full-DWORD write rejected", 16);
        expect_generation("active oversized NumVFs full-DWORD write rejected",
                          mgr.config_generation, g0);

        // Rekey across a numerically overlapping range: old VF7 becomes the
        // new PF key and old VF8..15 become new VF keys. Old keys are removed
        // only when they are not also members of the final key set.
        overlap_mgr = pcie_tl_func_manager::type_id::create("overlap_mgr");
        overlap_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        overlap_mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        overlap_mgr.enable_vfs(0, 16);
        old_pf_bdf = overlap_mgr.pf_ctx[0].bdf;
        old_vf_bdf = new[overlap_mgr.max_vfs_per_pf];
        for (int vf = 0; vf < overlap_mgr.max_vfs_per_pf; vf++)
            old_vf_bdf[vf] = overlap_mgr.vf_ctx[0][vf].bdf;
        g0 = overlap_mgr.config_generation;
        if (!overlap_mgr.bind_runtime_pf_base(16'h0108) ||
            overlap_mgr.pf_ctx[0].bdf != 16'h0108 ||
            overlap_mgr.sriov_caps[0].pf_bdf != 16'h0108 ||
            overlap_mgr.config_generation != g0 + 1)
            `uvm_error("BAR_STATE", "overlapping runtime BDF bind state mismatch")
        if (overlap_mgr.lookup_by_bdf(overlap_mgr.pf_ctx[0].bdf) !=
            overlap_mgr.pf_ctx[0])
            `uvm_error("BAR_STATE", "overlapping runtime bind mapped the PF incorrectly")
        for (int vf = 0; vf < overlap_mgr.max_vfs_per_pf; vf++) begin
            if (overlap_mgr.vf_ctx[0][vf].bdf !=
                overlap_mgr.sriov_caps[0].get_vf_rid(vf))
                `uvm_error("BAR_STATE", $sformatf(
                    "overlapping runtime bind left VF%0d BDF stale", vf))
            if (overlap_mgr.lookup_by_bdf(overlap_mgr.vf_ctx[0][vf].bdf) !=
                overlap_mgr.vf_ctx[0][vf])
                `uvm_error("BAR_STATE", $sformatf(
                    "overlapping runtime bind mapped VF%0d incorrectly", vf))
            if (!is_manager_current_lut_key(overlap_mgr, old_vf_bdf[vf], 16) &&
                overlap_mgr.lookup_by_bdf(old_vf_bdf[vf]) != null)
                `uvm_error("BAR_STATE", $sformatf(
                    "overlapping runtime bind retained old VF%0d key", vf))
        end
        if (!is_manager_current_lut_key(overlap_mgr, old_pf_bdf, 16) &&
            overlap_mgr.lookup_by_bdf(old_pf_bdf) != null)
            `uvm_error("BAR_STATE", "overlapping runtime bind retained old PF key")
        g0 = overlap_mgr.config_generation;
        if (!overlap_mgr.bind_runtime_pf_base(16'h0108))
            `uvm_error("BAR_STATE", "repeated overlapping runtime bind was rejected")
        expect_generation("repeated overlapping runtime BDF bind",
                          overlap_mgr.config_generation, g0);

        // Runtime rekey must also purge candidate keys for disabled VFs. A
        // stale wrong-object entry must not survive merely because VF15 is off.
        stale_mgr = pcie_tl_func_manager::type_id::create("stale_mgr");
        stale_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        stale_mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        stale_mgr.enable_vfs(0, 1);
        stale_disabled_vf_bdf = stale_mgr.vf_ctx[0][15].bdf;
        stale_mgr.bdf_lut[stale_disabled_vf_bdf] = stale_mgr.pf_ctx[0];
        g0 = stale_mgr.config_generation;
        if (!stale_mgr.bind_runtime_pf_base(16'h0200) ||
            stale_mgr.config_generation != g0 + 1 ||
            stale_mgr.lookup_by_bdf(16'h0200) != stale_mgr.pf_ctx[0] ||
            stale_mgr.lookup_by_bdf(stale_mgr.vf_ctx[0][0].bdf) !=
                stale_mgr.vf_ctx[0][0])
            `uvm_error("BAR_STATE", "disabled-VF stale-key rebind state mismatch")
        if (stale_mgr.lookup_by_bdf(stale_disabled_vf_bdf) != null)
            `uvm_error("BAR_STATE",
                       "runtime BDF bind retained a disabled-VF stale LUT key")
        for (int vf = 0; vf < stale_mgr.max_vfs_per_pf; vf++) begin
            pcie_tl_func_context lut_ctx =
                stale_mgr.lookup_by_bdf(stale_mgr.vf_ctx[0][vf].bdf);
            if (stale_mgr.vf_ctx[0][vf].bdf !=
                stale_mgr.sriov_caps[0].get_vf_rid(vf) ||
                (vf == 0 && lut_ctx != stale_mgr.vf_ctx[0][vf]) ||
                (vf != 0 && lut_ctx != null))
                `uvm_error("BAR_STATE", $sformatf(
                    "disabled-VF stale-key rebind mapped VF%0d incorrectly", vf))
        end

        // Direct lifecycle APIs must use the accepted count and synchronize
        // only NumVFs and Control in the registered PF configuration image.
        direct_mgr = pcie_tl_func_manager::type_id::create("direct_mgr");
        direct_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        direct_mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        sriov_dw = int'(direct_mgr.sriov_caps[0].offset >> 2);
        direct_mgr.pf_ctx[0].cfg_mgr.cfg_space[
            direct_mgr.sriov_caps[0].offset + 10] = 8'h01;
        direct_mgr.pf_ctx[0].cfg_mgr.cfg_space[
            direct_mgr.sriov_caps[0].offset + 8] = 8'h80;
        direct_mgr.pf_ctx[0].cfg_mgr.write_masks[
            direct_mgr.sriov_caps[0].offset + 8] = 8'h7f;
        direct_mgr.pf_ctx[0].cfg_mgr.cfg_space[
            direct_mgr.sriov_caps[0].offset + 18] = 8'ha5;
        direct_mgr.pf_ctx[0].cfg_mgr.cfg_space[
            direct_mgr.sriov_caps[0].offset + 19] = 8'h5a;
        direct_control_cb = pcie_tl_cfg_write_recorder::type_id::create(
            "direct_control_cb");
        direct_num_vfs_cb = pcie_tl_cfg_write_recorder::type_id::create(
            "direct_num_vfs_cb");
        direct_mgr.pf_ctx[0].cfg_mgr.register_callback(
            direct_mgr.sriov_caps[0].offset + 12'h008, direct_control_cb);
        direct_mgr.pf_ctx[0].cfg_mgr.register_callback(
            direct_mgr.sriov_caps[0].offset + 12'h010, direct_num_vfs_cb);
        direct_control_cb.clear_write_history();
        direct_num_vfs_cb.clear_write_history();
        g0 = direct_mgr.config_generation;
        direct_mgr.enable_vfs(0, 32);
        cfg_dw = direct_mgr.cfg_read(
            direct_mgr.pf_ctx[0].bdf, (sriov_dw + 4) << 2);
        old_cfg_dw = direct_mgr.cfg_read(
            direct_mgr.pf_ctx[0].bdf, (sriov_dw + 2) << 2);
        if (direct_mgr.sriov_caps[0].num_vfs != 16 ||
            !direct_mgr.sriov_caps[0].vf_enable ||
            cfg_dw[15:0] != 16 || cfg_dw[31:16] != 16'h5aa5 ||
            !old_cfg_dw[0] || !old_cfg_dw[7] ||
            old_cfg_dw[23:16] != 8'h01)
            `uvm_error("BAR_STATE", "direct VF enable raw config image mismatch")
        for (int vf = 0; vf < direct_mgr.max_vfs_per_pf; vf++)
            if (!direct_mgr.vf_ctx[0][vf].enabled ||
                direct_mgr.lookup_by_bdf(direct_mgr.vf_ctx[0][vf].bdf) !=
                    direct_mgr.vf_ctx[0][vf])
                `uvm_error("BAR_STATE", $sformatf(
                    "direct VF enable mapped VF%0d incorrectly", vf))
        expect_generation("direct oversized VF enable",
                          direct_mgr.config_generation, g0 + 1);
        expect_cfg_callback("direct VF enable Control", direct_control_cb, 0);
        expect_cfg_callback("direct VF enable NumVFs", direct_num_vfs_cb, 0);
        direct_control_cb.clear_write_history();
        direct_num_vfs_cb.clear_write_history();
        g0 = direct_mgr.config_generation;
        direct_mgr.disable_vfs(0);
        cfg_dw = direct_mgr.cfg_read(
            direct_mgr.pf_ctx[0].bdf, (sriov_dw + 4) << 2);
        old_cfg_dw = direct_mgr.cfg_read(
            direct_mgr.pf_ctx[0].bdf, (sriov_dw + 2) << 2);
        if (direct_mgr.sriov_caps[0].num_vfs != 16 ||
            direct_mgr.sriov_caps[0].vf_enable ||
            cfg_dw[15:0] != 16 || cfg_dw[31:16] != 16'h5aa5 ||
            old_cfg_dw[0] || !old_cfg_dw[7] ||
            old_cfg_dw[23:16] != 8'h01)
            `uvm_error("BAR_STATE", "direct VF disable raw config image mismatch")
        for (int vf = 0; vf < direct_mgr.max_vfs_per_pf; vf++)
            if (direct_mgr.vf_ctx[0][vf].enabled ||
                direct_mgr.lookup_by_bdf(direct_mgr.vf_ctx[0][vf].bdf) != null)
                `uvm_error("BAR_STATE", $sformatf(
                    "direct VF disable retained VF%0d routing", vf))
        expect_generation("direct VF disable",
                          direct_mgr.config_generation, g0 + 1);
        expect_cfg_callback("direct VF disable Control", direct_control_cb, 0);
        expect_cfg_callback("direct VF disable NumVFs", direct_num_vfs_cb, 0);

        // Reconciliation must treat removal of a wrong object at a disabled
        // VF key as a routing change, even though the VF itself stays disabled.
        mgr.build_topology(0, 1, 16, 16'h1234, 16'h5678, 16'h9abc);
        mgr.enable_vfs(0, 1);
        mgr.bdf_lut[mgr.vf_ctx[0][15].bdf] = mgr.pf_ctx[0];
        g0 = mgr.config_generation;
        mgr.enable_vfs(0, 1);
        if (mgr.lookup_by_bdf(mgr.vf_ctx[0][15].bdf) != null)
            `uvm_error("BAR_STATE", "disabled VF wrong-object LUT key was not removed")
        expect_generation("disabled VF wrong-object LUT reconciliation",
                          mgr.config_generation, g0 + 1);

        phase.drop_objection(this);
    endtask
endclass
