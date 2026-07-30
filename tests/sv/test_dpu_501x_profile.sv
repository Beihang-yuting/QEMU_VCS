`timescale 1ns/1ps

module test_dpu_501x_profile;
    import pcie_tl_device_profile_pkg::*;

    task automatic expect_u32(
        input string name,
        input bit [31:0] actual,
        input bit [31:0] expected
    );
        if (actual !== expected)
            $fatal(1, "%s: got 0x%08h, expected 0x%08h", name, actual, expected);
    endtask

    task automatic expect_u16(
        input string name,
        input bit [15:0] actual,
        input bit [15:0] expected
    );
        if (actual !== expected)
            $fatal(1, "%s: got 0x%04h, expected 0x%04h", name, actual, expected);
    endtask

    function automatic bit profile_helpers_match(
        input string name,
        input bit expected_valid,
        input pcie_cfg_profile_e expected_profile
    );
        profile_helpers_match =
            pcie_cfg_profile_parse(name) == expected_valid &&
            pcie_cfg_profile_value(name) == expected_profile;
    endfunction

    task automatic check_rid_layout(input int unsigned num_pfs);
        bit [255:0] layout_seen;
        int layout_rid;

        layout_seen = '0;
        for (int pf = 0; pf < num_pfs; pf++) begin
            if (layout_seen[pf])
                $fatal(1, "%0dPF duplicate PF RID %0d", num_pfs, pf);
            layout_seen[pf] = 1'b1;
            for (int vf = 0; vf < 16; vf++) begin
                layout_rid = pf + pcie_dpu_first_vf_offset(num_pfs, pf) + vf;
                if (layout_rid < 0 || layout_rid > 255 || layout_seen[layout_rid])
                    $fatal(1, "%0dPF duplicate or invalid VF RID pf=%0d vf=%0d rid=%0d",
                           num_pfs, pf, vf, layout_rid);
                layout_seen[layout_rid] = 1'b1;
            end
        end
    endtask

    initial begin
        if (!pcie_cfg_profile_parse("") ||
            pcie_cfg_profile_value("") != PCIE_CFG_PROFILE_LEGACY)
            $fatal(1, "empty profile must select LEGACY");
        if (!pcie_cfg_profile_parse("LEGACY") ||
            pcie_cfg_profile_value("LEGACY") != PCIE_CFG_PROFILE_LEGACY)
            $fatal(1, "LEGACY profile must select LEGACY");
        if (!pcie_cfg_profile_parse("DPU_20F9_501X") ||
            pcie_cfg_profile_value("DPU_20F9_501X") != PCIE_CFG_PROFILE_DPU_20F9_501X)
            $fatal(1, "DPU_20F9_501X must select DPU profile");
        if (pcie_cfg_profile_parse("unknown") ||
            pcie_cfg_profile_value("unknown") != PCIE_CFG_PROFILE_LEGACY)
            $fatal(1, "unknown profile must be rejected");
        if (!profile_helpers_match("DPU_20F9_501X", 1'b1,
                                   PCIE_CFG_PROFILE_DPU_20F9_501X) ||
            !profile_helpers_match("unknown", 1'b0, PCIE_CFG_PROFILE_LEGACY))
            $fatal(1, "profile helpers must be callable from a function");

        for (int pf = 0; pf < 4; pf++)
            expect_u16($sformatf("PF%0d device ID", pf),
                       pcie_dpu_pf_device_id(pf), 16'h5011 + pf);

        expect_u32("1PF PF0 VF offset", pcie_dpu_first_vf_offset(1, 0), 1);
        expect_u32("4PF PF0 VF offset", pcie_dpu_first_vf_offset(4, 0), 4);
        expect_u32("4PF PF1 VF offset", pcie_dpu_first_vf_offset(4, 1), 19);
        expect_u32("4PF PF2 VF offset", pcie_dpu_first_vf_offset(4, 2), 34);
        expect_u32("4PF PF3 VF offset", pcie_dpu_first_vf_offset(4, 3), 49);
        expect_u32("2PF PF0 VF offset", pcie_dpu_first_vf_offset(2, 0), 2);
        expect_u32("2PF PF1 VF offset", pcie_dpu_first_vf_offset(2, 1), 17);

        check_rid_layout(1);
        check_rid_layout(2);
        check_rid_layout(4);

        expect_u32("PF BAR0 size", pcie_dpu_bar_size(0, 0), 32 * 1024 * 1024);
        expect_u32("PF BAR2 size", pcie_dpu_bar_size(0, 2), 64 * 1024);
        expect_u32("PF BAR4 size", pcie_dpu_bar_size(0, 4), 64 * 1024);
        expect_u32("PF BAR1 unused", pcie_dpu_bar_size(0, 1), 0);
        expect_u32("VF BAR0 size", pcie_dpu_bar_size(1, 0), 16 * 1024);
        expect_u32("VF BAR2 size", pcie_dpu_bar_size(1, 2), 16 * 1024);
        expect_u32("VF BAR4 size", pcie_dpu_bar_size(1, 4), 32 * 1024);
        expect_u32("VF BAR5 unused", pcie_dpu_bar_size(1, 5), 0);
        expect_u32("BAR0 flags", pcie_dpu_bar_flags(0), 32'h0000_000c);
        expect_u32("BAR2 flags", pcie_dpu_bar_flags(2), 32'h0000_000c);
        expect_u32("BAR4 flags", pcie_dpu_bar_flags(4), 32'h0000_000c);
        expect_u32("BAR1 flags", pcie_dpu_bar_flags(1), 0);

        expect_u32("PF BAR0 sizing low", pcie_bar_sizing_dw(32 * 1024 * 1024, 32'hc, 0), 32'hfe00_000c);
        expect_u32("PF BAR0 sizing high", pcie_bar_sizing_dw(32 * 1024 * 1024, 32'hc, 1), 32'hffff_ffff);
        expect_u32("PF BAR2 sizing low", pcie_bar_sizing_dw(64 * 1024, 32'hc, 0), 32'hffff_000c);
        expect_u32("PF BAR2 sizing high", pcie_bar_sizing_dw(64 * 1024, 32'hc, 1), 32'hffff_ffff);
        expect_u32("PF BAR4 sizing low", pcie_bar_sizing_dw(64 * 1024, 32'hc, 0), 32'hffff_000c);
        expect_u32("PF BAR4 sizing high", pcie_bar_sizing_dw(64 * 1024, 32'hc, 1), 32'hffff_ffff);
        expect_u32("VF BAR0 sizing low", pcie_bar_sizing_dw(16 * 1024, 32'hc, 0), 32'hffff_c00c);
        expect_u32("VF BAR0 sizing high", pcie_bar_sizing_dw(16 * 1024, 32'hc, 1), 32'hffff_ffff);
        expect_u32("VF BAR2 sizing low", pcie_bar_sizing_dw(16 * 1024, 32'hc, 0), 32'hffff_c00c);
        expect_u32("VF BAR2 sizing high", pcie_bar_sizing_dw(16 * 1024, 32'hc, 1), 32'hffff_ffff);
        expect_u32("VF BAR4 sizing low", pcie_bar_sizing_dw(32 * 1024, 32'hc, 0), 32'hffff_800c);
        expect_u32("VF BAR4 sizing high", pcie_bar_sizing_dw(32 * 1024, 32'hc, 1), 32'hffff_ffff);
        expect_u32("unused BAR sizing", pcie_bar_sizing_dw(0, 32'hc, 0), 0);

        $display("PASS: DPU 20f9:501x profile helpers");
        $finish;
    end
endmodule
