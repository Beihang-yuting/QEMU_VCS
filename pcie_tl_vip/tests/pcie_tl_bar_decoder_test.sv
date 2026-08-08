import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_tl_device_profile_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_bar_decoder_test extends uvm_test;
    `uvm_component_utils(pcie_tl_bar_decoder_test)

    pcie_tl_config_proxy proxy;
    pcie_tl_config_proxy aux_proxy;
    pcie_tl_config_proxy legacy_proxy;
    pcie_tl_func_manager mgr;
    pcie_tl_bar_decoder decoder;
    bit [63:0] pf_base[4][6];
    bit [63:0] vf_base[4][6];

    function new(string name = "pcie_tl_bar_decoder_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        proxy = pcie_tl_config_proxy::type_id::create("proxy", this);
        aux_proxy = pcie_tl_config_proxy::type_id::create("aux_proxy", this);
        legacy_proxy = pcie_tl_config_proxy::type_id::create("legacy_proxy", this);
    endfunction

    function pcie_tl_mem_tlp make_read(bit [63:0] addr);
        pcie_tl_mem_tlp req;
        req = pcie_tl_mem_tlp::type_id::create($sformatf("rd_%016h", addr));
        req.kind = TLP_MEM_RD;
        req.fmt = FMT_4DW_NO_DATA;
        req.type_f = TLP_TYPE_MEM_RD;
        req.is_64bit = 1;
        req.addr = addr;
        req.length = 1;
        req.first_be = 4'hf;
        req.last_be = 4'h0;
        return req;
    endfunction

    function void proxy_write(pcie_tl_config_proxy cfg_proxy,
                              bit [15:0] bdf, int dw_addr,
                              bit [31:0] data);
        if (!cfg_proxy.handle_cfg_write_bdf(bdf, dw_addr, data, 0, 4))
            `uvm_error("BAR_DECODE", $sformatf(
                "proxy did not intercept BDF=%04h DW=%0h", bdf, dw_addr))
    endfunction

    function void program_pf_bar(pcie_tl_config_proxy cfg_proxy,
                                 pcie_tl_func_manager fm, int pf, int bar,
                                 bit [63:0] base);
        proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf, 4 + bar, base[31:0]);
        if (bar + 1 < 6 && fm.pf_ctx[pf].bar_owner[bar + 1] == bar)
            proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf, 5 + bar, base[63:32]);
    endfunction

    function void program_vf_bar(pcie_tl_config_proxy cfg_proxy,
                                 pcie_tl_func_manager fm, int pf, int bar,
                                 bit [63:0] base);
        int sriov_dw;
        sriov_dw = int'(fm.sriov_caps[pf].offset >> 2);
        proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf,
                    sriov_dw + 9 + bar, base[31:0]);
        if (bar + 1 < 6 && fm.sriov_caps[pf].vf_bar_owner[bar + 1] == bar)
            proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf,
                        sriov_dw + 10 + bar, base[63:32]);
    endfunction

    function void set_command(pcie_tl_config_proxy cfg_proxy,
                              pcie_tl_func_manager fm, int pf,
                              bit mse, bit bme);
        bit [31:0] command;
        command = 0;
        command[1] = mse;
        command[2] = bme;
        proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf, 1, command);
    endfunction

    function void set_sriov(pcie_tl_config_proxy cfg_proxy,
                            pcie_tl_func_manager fm, int pf,
                            int num_vfs, bit vfe, bit vf_mse);
        int sriov_dw;
        bit [31:0] control;
        sriov_dw = int'(fm.sriov_caps[pf].offset >> 2);
        if (!fm.sriov_caps[pf].vf_enable)
            proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf,
                        sriov_dw + 4, num_vfs);
        control = 0;
        control[0] = vfe;
        control[4] = vf_mse;
        proxy_write(cfg_proxy, fm.pf_ctx[pf].bdf, sriov_dw + 2, control);
    endfunction

    function pcie_tl_cq_route_t expect_decode(
        string label, pcie_tl_bar_decoder dec, pcie_tl_mem_tlp req,
        bit [15:0] target_bdf, pcie_bar_decode_result_e expected);
        pcie_tl_cq_route_t route;
        pcie_bar_decode_result_e actual;
        string reason;
        actual = dec.decode(req, target_bdf, route, reason);
        if (actual != expected)
            `uvm_error("BAR_DECODE", $sformatf(
                "%s: result=%s expected=%s reason=%s",
                label, actual.name(), expected.name(), reason))
        if (expected != PCIE_BAR_DECODE_OK &&
            (route.valid || route.vf_index != -1))
            `uvm_error("BAR_DECODE", $sformatf(
                "%s: failure leaked route valid=%0b vf_index=%0d",
                label, route.valid, route.vf_index))
        return route;
    endfunction

    function void expect_route(string label, pcie_tl_cq_route_t route,
                               bit [15:0] bdf, int bar, int aperture,
                               bit [63:0] offset, bit is_vf,
                               int pf, int vf);
        if (!route.valid || route.target_bdf != bdf ||
            route.target_func != bdf[7:0] || route.bar_id != bar ||
            route.bar_aperture != aperture || route.bar_offset != offset ||
            route.is_vf != is_vf || route.pf_index != pf ||
            route.vf_index != vf)
            `uvm_error("BAR_DECODE", $sformatf(
                "%s: route mismatch valid=%0b bdf=%04h func=%02h bar=%0d ap=%0d off=%h vf=%0b pf=%0d vi=%0d",
                label, route.valid, route.target_bdf, route.target_func,
                route.bar_id, route.bar_aperture, route.bar_offset,
                route.is_vf, route.pf_index, route.vf_index))
    endfunction

    task run_phase(uvm_phase phase);
        pcie_tl_mem_tlp req;
        pcie_tl_cq_route_t route;
        pcie_tl_func_manager overlap_mgr;
        pcie_tl_func_manager invalid_mgr;
        pcie_tl_func_manager isolated_mgr;
        pcie_tl_func_manager legacy_mgr;
        pcie_tl_bar_decoder overlap_decoder;
        pcie_tl_bar_decoder invalid_decoder;
        pcie_tl_bar_decoder isolated_decoder;
        pcie_tl_bar_decoder legacy_decoder;
        pcie_tl_bar_decoder null_decoder;
        pcie_tl_bar_decode_entry saved_entry;
        pcie_tl_bar_decode_entry isolated_entry;
        longint unsigned saved_generation;
        longint unsigned isolated_generation;
        bit [63:0] new_bar2_base;
        bit [15:0] vf_bdf;
        int owners[3];
        int pf_apertures[3];
        int vf_apertures[3];

        phase.raise_objection(this);
        owners[0] = 0; owners[1] = 2; owners[2] = 4;
        pf_apertures[0] = 13; pf_apertures[1] = 4; pf_apertures[2] = 4;
        vf_apertures[0] = 2; vf_apertures[1] = 2; vf_apertures[2] = 3;

        mgr = pcie_tl_func_manager::type_id::create("mgr");
        mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        mgr.build_topology(0, 4, 16, 16'h20f9, 16'h5011, 16'h8689);
        proxy.func_mgr = mgr;
        proxy.multi_function_mode = 1;
        decoder = pcie_tl_bar_decoder::type_id::create("decoder");
        decoder.func_mgr = mgr;

        for (int pf = 0; pf < 4; pf++) begin
            pf_base[pf][0] = 64'h0000_0008_0000_0000 + pf * 64'h1000_0000;
            pf_base[pf][2] = (pf == 0) ? 64'h0000_0009_0800_0000 :
                64'h0000_0009_0000_0000 + pf * 64'h1000_0000;
            pf_base[pf][4] = pf_base[pf][2] + 64'h0010_0000;
            vf_base[pf][0] = 64'h0000_000a_0000_0000 + pf * 64'h1000_0000;
            vf_base[pf][2] = vf_base[pf][0] + 64'h0100_0000;
            vf_base[pf][4] = vf_base[pf][0] + 64'h0200_0000;
            for (int oi = 0; oi < 3; oi++) begin
                program_pf_bar(proxy, mgr, pf, owners[oi], pf_base[pf][owners[oi]]);
                program_vf_bar(proxy, mgr, pf, owners[oi], vf_base[pf][owners[oi]]);
            end
            set_command(proxy, mgr, pf, 1, 0);
            set_sriov(proxy, mgr, pf, 16, 1, 1);
        end

        route = expect_decode("mailbox PF0 BAR2",
            decoder, make_read(64'h0000_0009_0800_002c),
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK);
        expect_route("mailbox PF0 BAR2", route, mgr.pf_ctx[0].bdf,
                     2, 4, 64'h2c, 0, 0, -1);

        for (int pf = 0; pf < 4; pf++) begin
            for (int oi = 0; oi < 3; oi++) begin
                int bar;
                bit [63:0] size;
                bar = owners[oi];
                size = mgr.pf_ctx[pf].bar_size[bar];
                route = expect_decode($sformatf("PF%0d BAR%0d first", pf, bar),
                    decoder, make_read(pf_base[pf][bar]),
                    mgr.pf_ctx[pf].bdf, PCIE_BAR_DECODE_OK);
                expect_route($sformatf("PF%0d BAR%0d", pf, bar), route,
                    mgr.pf_ctx[pf].bdf, bar, pf_apertures[oi], 0, 0, pf, -1);
                req = make_read(pf_base[pf][bar] + size - 4);
                req.first_be = 4'h8;
                void'(expect_decode($sformatf("PF%0d BAR%0d last byte", pf, bar),
                    decoder, req, mgr.pf_ctx[pf].bdf, PCIE_BAR_DECODE_OK));
                void'(expect_decode($sformatf("PF%0d BAR%0d end exclusive", pf, bar),
                    decoder, make_read(pf_base[pf][bar] + size),
                    mgr.pf_ctx[pf].bdf, PCIE_BAR_DECODE_NO_MATCH));
                req = make_read(pf_base[pf][bar] + size - 4);
                req.length = 2; req.first_be = 4'h8; req.last_be = 4'h1;
                void'(expect_decode($sformatf("PF%0d BAR%0d one-byte cross", pf, bar),
                    decoder, req, mgr.pf_ctx[pf].bdf,
                    PCIE_BAR_DECODE_CROSS_BOUNDARY));
            end
        end

        foreach (decoder.entries[i])
            if (decoder.entries[i].bar_id inside {1, 3, 5})
                `uvm_error("BAR_DECODE", "upper BAR appeared as an owner entry")

        for (int pf = 0; pf < 4; pf++) begin
            for (int oi = 0; oi < 3; oi++) begin
                int bar;
                bit [63:0] size;
                bar = owners[oi];
                size = mgr.sriov_caps[pf].vf_bar_size[bar];
                for (int vf = 0; vf < 16; vf++) begin
                    bit [15:0] vf_bdf;
                    vf_bdf = mgr.sriov_caps[pf].get_vf_rid(vf);
                    route = expect_decode($sformatf("PF%0d VF%0d BAR%0d", pf, vf, bar),
                        decoder, make_read(vf_base[pf][bar] + vf * size + 64'h20),
                        vf_bdf, PCIE_BAR_DECODE_OK);
                    expect_route($sformatf("PF%0d VF%0d BAR%0d", pf, vf, bar),
                        route, vf_bdf, bar, vf_apertures[oi], 64'h20, 1, pf, vf);
                end
            end
        end

        req = make_read(vf_base[0][0] + mgr.sriov_caps[0].vf_bar_size[0] - 4);
        req.length = 2; req.first_be = 4'h8; req.last_be = 4'h1;
        void'(expect_decode("cross VF function", decoder, req,
            mgr.sriov_caps[0].get_vf_rid(0), PCIE_BAR_DECODE_CROSS_BOUNDARY));

        void'(expect_decode("wrong target BDF", decoder, make_read(pf_base[0][0]),
            mgr.pf_ctx[1].bdf, PCIE_BAR_DECODE_BDF_MISMATCH));
        void'(expect_decode("wrong VF target leaves default route", decoder,
            make_read(vf_base[0][0]), mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_BDF_MISMATCH));
        void'(expect_decode("no BAR hit", decoder, make_read(64'h0000_00ff_0000_0000),
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_NO_MATCH));

        req = make_read(pf_base[0][0]); req.first_be = 0;
        void'(expect_decode("zero first BE", decoder, req, mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_MALFORMED));
        req = make_read(pf_base[0][0]); req.first_be = 4'h5;
        void'(expect_decode("noncontiguous first BE", decoder, req, mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_MALFORMED));
        req = make_read(pf_base[0][0]); req.last_be = 4'h1;
        void'(expect_decode("one-DW last BE", decoder, req, mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_MALFORMED));
        req = make_read(pf_base[0][0]); req.length = 2; req.last_be = 4'h5;
        void'(expect_decode("multi-DW noncontiguous last BE", decoder, req,
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_MALFORMED));
        req = make_read(64'hffff_ffff_ffff_fffc);
        req.length = 2; req.last_be = 4'h1;
        void'(expect_decode("64-bit request overflow", decoder, req,
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_MALFORMED));

        req = make_read(pf_base[0][0] + 1);
        void'(expect_decode("unaligned request address", decoder, req,
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_MALFORMED));
        req = make_read(pf_base[0][0]); req.length = 2; req.last_be = 0;
        void'(expect_decode("multi-DW zero last BE", decoder, req,
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_MALFORMED));
        req = make_read(pf_base[0][0]); req.length = 0; req.last_be = 4'hf;
        void'(expect_decode("length zero is 1024 DW", decoder, req,
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));
        req = make_read(pf_base[0][4] + mgr.pf_ctx[0].bar_size[4] - 8);
        req.length = 2; req.first_be = 4'h8; req.last_be = 4'h8;
        void'(expect_decode("multi-DW exact last byte", decoder, req,
            mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));

        // Cache reuse, sizing writes, repeated assignments, and low/high BAR
        // programming are all driven through the configuration proxy.
        if (decoder.entries.size() != 24)
            `uvm_error("BAR_DECODE", $sformatf(
                "DPU cache has %0d entries, expected 24", decoder.entries.size()))
        saved_entry = decoder.entries[1];
        saved_generation = mgr.config_generation;
        proxy_write(proxy, mgr.pf_ctx[0].bdf, 6, 32'hffff_ffff);
        if (mgr.config_generation != saved_generation)
            `uvm_error("BAR_DECODE", "PF BAR sizing write changed generation")
        void'(expect_decode("sizing keeps old route", decoder,
            make_read(pf_base[0][2]), mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));
        if (decoder.entries[1] != saved_entry)
            `uvm_error("BAR_DECODE", "decoder rebuilt without generation change")
        proxy_write(proxy, mgr.pf_ctx[0].bdf, 6, pf_base[0][2][31:0]);
        if (mgr.config_generation != saved_generation)
            `uvm_error("BAR_DECODE", "same-base sizing exit changed generation")

        new_bar2_base = {32'h0000_000b, pf_base[0][2][31:0]};
        proxy_write(proxy, mgr.pf_ctx[0].bdf, 7, new_bar2_base[63:32]);
        if (mgr.config_generation != saved_generation + 1)
            `uvm_error("BAR_DECODE", "PF BAR high reprogram generation mismatch")
        void'(expect_decode("old BAR2 after high reprogram", decoder,
            make_read(pf_base[0][2]), mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_NO_MATCH));
        void'(expect_decode("new BAR2 after high reprogram", decoder,
            make_read(new_bar2_base), mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));
        saved_entry = decoder.entries[1];
        saved_generation = mgr.config_generation;
        new_bar2_base[31:0] = 32'h0900_0000;
        proxy_write(proxy, mgr.pf_ctx[0].bdf, 6, new_bar2_base[31:0]);
        if (mgr.config_generation != saved_generation + 1)
            `uvm_error("BAR_DECODE", "PF BAR low reprogram generation mismatch")
        void'(expect_decode("new BAR2 after low reprogram", decoder,
            make_read(new_bar2_base), mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));
        saved_entry = decoder.entries[1];
        saved_generation = mgr.config_generation;
        proxy_write(proxy, mgr.pf_ctx[0].bdf, 6, new_bar2_base[31:0]);
        void'(expect_decode("repeated BAR2 low assignment", decoder,
            make_read(new_bar2_base), mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));
        if (mgr.config_generation != saved_generation ||
            decoder.entries[1] != saved_entry)
            `uvm_error("BAR_DECODE", "repeated BAR write rebuilt cache")
        pf_base[0][2] = new_bar2_base;

        saved_generation = mgr.config_generation;
        saved_entry = decoder.entries[0];
        set_command(proxy, mgr, 0, 1, 1);
        void'(expect_decode("BME does not gate BAR", decoder,
            make_read(pf_base[0][0]), mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));
        if (mgr.config_generation != saved_generation ||
            decoder.entries[0] != saved_entry)
            `uvm_error("BAR_DECODE", "BME-only write invalidated BAR cache")
        set_command(proxy, mgr, 0, 0, 0);
        void'(expect_decode("MSE disables PF BAR", decoder,
            make_read(pf_base[0][0]), mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_DISABLED));
        saved_generation = mgr.config_generation;
        set_command(proxy, mgr, 0, 0, 0);
        if (mgr.config_generation != saved_generation)
            `uvm_error("BAR_DECODE", "repeated MSE disable changed generation")
        set_command(proxy, mgr, 0, 1, 0);
        void'(expect_decode("MSE re-enables PF BAR", decoder,
            make_read(pf_base[0][0]), mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_OK));

        // VF edge bytes, aperture edge, exact context validation, and all
        // SR-IOV enable transitions use normal proxy writes.
        req = make_read(vf_base[0][0] +
            15 * mgr.sriov_caps[0].vf_bar_size[0] +
            mgr.sriov_caps[0].vf_bar_size[0] - 4);
        req.first_be = 4'h8;
        route = expect_decode("last byte of last VF", decoder, req,
            mgr.sriov_caps[0].get_vf_rid(15), PCIE_BAR_DECODE_OK);
        expect_route("last byte of last VF", route,
            mgr.sriov_caps[0].get_vf_rid(15), 0, 2,
            mgr.sriov_caps[0].vf_bar_size[0] - 4, 1, 0, 15);
        void'(expect_decode("VF aperture end exclusive", decoder,
            make_read(vf_base[0][0] +
                16 * mgr.sriov_caps[0].vf_bar_size[0]),
            mgr.sriov_caps[0].get_vf_rid(15), PCIE_BAR_DECODE_NO_MATCH));
        req.length = 2; req.last_be = 4'h1;
        void'(expect_decode("cross VF aperture", decoder, req,
            mgr.sriov_caps[0].get_vf_rid(15),
            PCIE_BAR_DECODE_CROSS_BOUNDARY));

        vf_bdf = mgr.sriov_caps[0].get_vf_rid(3);
        mgr.bdf_lut.delete(vf_bdf);
        mgr.mark_routing_dirty("test-only invalid VF LUT metadata");
        void'(expect_decode("missing exact VF context", decoder,
            make_read(vf_base[0][0] +
                3 * mgr.sriov_caps[0].vf_bar_size[0]),
            vf_bdf, PCIE_BAR_DECODE_DISABLED));
        mgr.bdf_lut[vf_bdf] = mgr.vf_ctx[0][3];
        mgr.mark_routing_dirty("restore test-only VF LUT metadata");

        set_sriov(proxy, mgr, 0, 16, 1, 0);
        void'(expect_decode("VF MSE disabled", decoder,
            make_read(vf_base[0][0]), mgr.sriov_caps[0].get_vf_rid(0),
            PCIE_BAR_DECODE_DISABLED));
        set_sriov(proxy, mgr, 0, 16, 1, 1);
        void'(expect_decode("VF MSE restored", decoder,
            make_read(vf_base[0][0]), mgr.sriov_caps[0].get_vf_rid(0),
            PCIE_BAR_DECODE_OK));
        set_sriov(proxy, mgr, 0, 16, 0, 1);
        void'(expect_decode("VFE disabled", decoder,
            make_read(vf_base[0][0]), mgr.sriov_caps[0].get_vf_rid(0),
            PCIE_BAR_DECODE_DISABLED));
        set_sriov(proxy, mgr, 0, 0, 0, 0);
        void'(expect_decode("zero NumVFs removes aperture", decoder,
            make_read(vf_base[0][0]), mgr.sriov_caps[0].get_vf_rid(0),
            PCIE_BAR_DECODE_NO_MATCH));
        set_sriov(proxy, mgr, 0, 16, 1, 1);
        void'(expect_decode("NumVFs and VFE restored", decoder,
            make_read(vf_base[0][0]), mgr.sriov_caps[0].get_vf_rid(0),
            PCIE_BAR_DECODE_OK));

        // A disabled range overlapping an enabled one is not fatal. Enabling
        // both through Command.MSE makes the same address ambiguous.
        overlap_mgr = pcie_tl_func_manager::type_id::create("overlap_mgr");
        overlap_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        overlap_mgr.build_topology(0, 2, 16, 16'h20f9, 16'h5011, 16'h8689);
        aux_proxy.func_mgr = overlap_mgr;
        aux_proxy.multi_function_mode = 1;
        program_pf_bar(aux_proxy, overlap_mgr, 0, 2, 64'h0000_000c_0000_0000);
        program_pf_bar(aux_proxy, overlap_mgr, 1, 2, 64'h0000_000c_0000_0000);
        set_command(aux_proxy, overlap_mgr, 0, 1, 0);
        overlap_decoder = pcie_tl_bar_decoder::type_id::create("overlap_decoder");
        overlap_decoder.func_mgr = overlap_mgr;
        void'(expect_decode("disabled overlap is routable", overlap_decoder,
            make_read(64'h0000_000c_0000_0000), overlap_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_OK));
        set_command(aux_proxy, overlap_mgr, 1, 1, 0);
        void'(expect_decode("enabled overlap is fatal before BDF hint",
            overlap_decoder, make_read(64'h0000_000c_0000_0000), 16'hffff,
            PCIE_BAR_DECODE_OVERLAP));

        // Direct writes below deliberately inject impossible metadata that
        // cannot be produced by the config proxy, then mark the generation.
        invalid_mgr = pcie_tl_func_manager::type_id::create("invalid_mgr");
        invalid_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        invalid_mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        invalid_decoder = pcie_tl_bar_decoder::type_id::create("invalid_decoder");
        invalid_decoder.func_mgr = invalid_mgr;
        void'(expect_decode("valid disabled cache before injection", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_DISABLED));
        invalid_mgr.pf_ctx[0].bar_size[0] = 64'h1800;
        invalid_mgr.mark_routing_dirty("test-only non-power-of-two PF BAR");
        void'(expect_decode("invalid PF BAR size", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_INVALID_CONFIG));
        if (invalid_decoder.entries.size() != 0 ||
            invalid_decoder.cache_result != PCIE_BAR_DECODE_INVALID_CONFIG ||
            invalid_decoder.cache_reason == "")
            `uvm_error("BAR_DECODE", "failed rebuild left a partial cache")
        saved_generation = invalid_decoder.cached_generation;
        invalid_mgr.pf_ctx[0].bar_size[0] = 64'h1_0000;
        void'(expect_decode("invalid cache stable within generation", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_INVALID_CONFIG));
        if (invalid_decoder.cached_generation != saved_generation ||
            invalid_decoder.entries.size() != 0)
            `uvm_error("BAR_DECODE", "failed cache rebuilt without generation change")
        invalid_mgr.mark_routing_dirty("restore test-only PF BAR size");
        void'(expect_decode("invalid cache recovers on generation", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf, PCIE_BAR_DECODE_DISABLED));

        invalid_mgr.pf_ctx[0].bar_size[0] = 64'h1000;
        invalid_mgr.pf_ctx[0].bar_base[0] = 64'hffff_ffff_ffff_f800;
        invalid_mgr.mark_routing_dirty("test-only PF base plus size overflow");
        void'(expect_decode("PF base plus size overflow", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_INVALID_CONFIG));
        invalid_mgr.pf_ctx[0].bar_base[0] = 0;
        invalid_mgr.pf_ctx[0].bar_size[0] = 64'h1_0000;
        invalid_mgr.sriov_caps[0].num_vfs = 2;
        invalid_mgr.sriov_caps[0].vf_bar_size[0] = 64'h8000_0000_0000_0000;
        invalid_mgr.mark_routing_dirty("test-only VF size multiplication overflow");
        void'(expect_decode("VF size multiplication overflow", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_INVALID_CONFIG));
        invalid_mgr.sriov_caps[0].vf_bar_size[0] = 64'h4000;
        invalid_mgr.sriov_caps[0].vf_bar[0] = 64'hffff_ffff_ffff_f000;
        invalid_mgr.mark_routing_dirty("test-only VF base plus span overflow");
        void'(expect_decode("VF base plus span overflow", invalid_decoder,
            make_read(0), invalid_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_INVALID_CONFIG));

        // Separate managers own separate cache queues and generations.
        isolated_mgr = pcie_tl_func_manager::type_id::create("isolated_mgr");
        isolated_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        isolated_mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
        aux_proxy.func_mgr = isolated_mgr;
        program_pf_bar(aux_proxy, isolated_mgr, 0, 0,
                       64'h0000_000d_0000_0000);
        set_command(aux_proxy, isolated_mgr, 0, 1, 0);
        isolated_decoder = pcie_tl_bar_decoder::type_id::create("isolated_decoder");
        isolated_decoder.func_mgr = isolated_mgr;
        void'(expect_decode("isolated decoder route", isolated_decoder,
            make_read(64'h0000_000d_0000_0000), isolated_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_OK));
        isolated_entry = isolated_decoder.entries[0];
        isolated_generation = isolated_decoder.cached_generation;
        program_pf_bar(proxy, mgr, 1, 4, 64'h0000_000e_0000_0000);
        void'(expect_decode("other manager cache unchanged", isolated_decoder,
            make_read(64'h0000_000d_0000_0000), isolated_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_OK));
        if (isolated_decoder.cached_generation != isolated_generation ||
            isolated_decoder.entries[0] != isolated_entry ||
            isolated_decoder.entries[0] == decoder.entries[0])
            `uvm_error("BAR_DECODE", "decoder caches are not manager-isolated")

        // Legacy no-truncation unit regression: only PF8 is routable.
        legacy_mgr = pcie_tl_func_manager::type_id::create("legacy_mgr");
        legacy_mgr.cfg_profile = PCIE_CFG_PROFILE_LEGACY;
        legacy_mgr.build_topology(0, 9, 1, 16'h1234, 16'h5678, 16'h9abc);
        legacy_proxy.func_mgr = legacy_mgr;
        legacy_proxy.multi_function_mode = 1;
        program_pf_bar(legacy_proxy, legacy_mgr, 8, 0,
                       64'h0000_0000_f000_0000);
        set_command(legacy_proxy, legacy_mgr, 8, 1, 0);
        legacy_decoder = pcie_tl_bar_decoder::type_id::create("legacy_decoder");
        legacy_decoder.func_mgr = legacy_mgr;
        if (legacy_mgr.pf_ctx[8].bdf != 16'h0108 ||
            legacy_mgr.pf_ctx[0].bdf == legacy_mgr.pf_ctx[8].bdf)
            `uvm_error("BAR_DECODE", "legacy PF8 BDF aliases PF0")
        route = expect_decode("legacy PF8 full target function", legacy_decoder,
            make_read(64'h0000_0000_f000_0008), legacy_mgr.pf_ctx[8].bdf,
            PCIE_BAR_DECODE_OK);
        expect_route("legacy PF8 full target function", route, 16'h0108,
                     0, 4, 64'h8, 0, 8, -1);
        void'(expect_decode("legacy PF0 hint cannot alias PF8", legacy_decoder,
            make_read(64'h0000_0000_f000_0008), legacy_mgr.pf_ctx[0].bdf,
            PCIE_BAR_DECODE_BDF_MISMATCH));

        null_decoder = pcie_tl_bar_decoder::type_id::create("null_decoder");
        void'(expect_decode("null manager", null_decoder, make_read(0), 0,
            PCIE_BAR_DECODE_INVALID_CONFIG));
        void'(expect_decode("null request", decoder, null, 0,
            PCIE_BAR_DECODE_INVALID_CONFIG));

        `uvm_info("BAR_DECODE", "completed PF/VF BAR decode matrix", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
