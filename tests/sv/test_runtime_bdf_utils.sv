`timescale 1ns/1ps

module test_runtime_bdf_utils;
    import pcie_tl_bdf_utils_pkg::*;
    import cosim_runtime_policy_pkg::*;

    task automatic expect_bdf(
        input string name,
        input bit [15:0] actual,
        input bit [15:0] expected
    );
        if (actual !== expected) begin
            $error("%s: got 0x%04h, expected 0x%04h", name, actual, expected);
            $fatal(1);
        end
    endtask

    initial begin
        bit [15:0] base;
        bit [15:0] rid;
        bit [255:0] seen;

        base = pcie_pf_base_bdf(16'h0200);
        expect_bdf("02:00.0 base", base, 16'h0200);
        for (int pf = 0; pf < 4; pf++)
            expect_bdf($sformatf("PF%0d", pf), pcie_pf_bdf(base, pf),
                       16'h0200 + pf);

        expect_bdf("PF0 VF0", pcie_vf_bdf(16'h0200, 4, 4, 0), 16'h0204);
        expect_bdf("PF0 VF1", pcie_vf_bdf(16'h0200, 4, 4, 1), 16'h0208);
        expect_bdf("PF1 VF0", pcie_vf_bdf(16'h0201, 4, 4, 0), 16'h0205);

        // Maximum supported one-bus profile: PF RIDs 0..15, followed by
        // 15 interleaved VFs per PF. Together they occupy every devfn once.
        base = 16'h0400;
        seen = '0;
        for (int pf = 0; pf < 16; pf++) begin
            rid = pcie_pf_bdf(base, pf);
            expect_bdf($sformatf("16PF PF%0d", pf), rid, base + pf);
            if (rid[15:8] != base[15:8] || seen[rid[7:0]])
                $fatal(1, "duplicate or cross-bus PF RID 0x%04h", rid);
            seen[rid[7:0]] = 1;
        end
        for (int pf = 0; pf < 16; pf++) begin
            for (int vf = 0; vf < 15; vf++) begin
                rid = pcie_vf_bdf(
                    pcie_pf_bdf(base, pf), 16, 16, vf);
                if (rid[15:8] != base[15:8] || seen[rid[7:0]])
                    $fatal(1, "duplicate or cross-bus VF RID pf=%0d vf=%0d rid=0x%04h",
                           pf, vf, rid);
                seen[rid[7:0]] = 1;
            end
        end
        if (seen !== {256{1'b1}})
            $fatal(1, "16PF+240VF must occupy all 256 devfns exactly once");
        expect_bdf("PF15 VF14", pcie_vf_bdf(16'h040f, 16, 16, 14), 16'h04ff);

        // Required legacy regression: one PF still supports 16 VFs.
        expect_bdf("1PF VF15", pcie_vf_bdf(16'h0300, 1, 1, 15), 16'h0310);

        base = pcie_pf_base_bdf(16'h0018);
        expect_bdf("00:03.0 base", base, 16'h0018);

        if (!pcie_should_bind_runtime_bdf(1, 0, 0, 16'h0200))
            $fatal(1, "first PF0 Vendor ID read must trigger runtime bind");
        if (pcie_should_bind_runtime_bdf(0, 0, 0, 16'h0200) ||
            pcie_should_bind_runtime_bdf(1, 1, 0, 16'h0200) ||
            pcie_should_bind_runtime_bdf(1, 0, 1, 16'h0200) ||
            pcie_should_bind_runtime_bdf(1, 0, 0, 16'h0201))
            $fatal(1, "runtime bind trigger accepted a forbidden condition");

        if (!cosim_effective_config_bypass(0, 0, 0))
            $fatal(1, "stand-in default must bypass config");
        if (cosim_effective_config_bypass(1, 0, 0))
            $fatal(1, "REAL_DUT default must not silently claim config bypass");
        if (!cosim_effective_config_bypass(1, 1, 1) ||
            cosim_effective_config_bypass(1, 1, 0))
            $fatal(1, "explicit BYPASS_CONFIG must override the default");

        if (!cosim_valid_num_pfs(1) || !cosim_valid_num_pfs(8) ||
            !cosim_valid_num_pfs(16) || cosim_valid_num_pfs(0) ||
            cosim_valid_num_pfs(17))
            $fatal(1, "NUM_PFS range must be 1..16");
        if (!cosim_single_bus_profile_fits(16, 15) ||
            !cosim_single_bus_profile_fits(1, 16) ||
            cosim_single_bus_profile_fits(16, 16))
            $fatal(1, "single-bus PF/VF capacity policy is incorrect");
        if (cosim_single_bus_profile_fits(16, 2147483647))
            $fatal(1, "single-bus capacity check accepted an overflowing MAX_VFS");

        $display("PASS: runtime BDF arithmetic, bind trigger, and launch policy");
        $finish;
    end
endmodule
