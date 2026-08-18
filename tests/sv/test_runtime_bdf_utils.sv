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
        bit prepolled_tlp_valid;
        int poll_calls;
        int poll_result;
        int dispatch_count;
        bit [31:0] scalar_data;
        bit [31:0] dispatched_data[2];

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

        // Model the driver boundary where realization polling and the main
        // request loop share the scalar DPI getter storage. A ret==0 poll has
        // already populated the first TLP and must not be repeated before the
        // getter/dispatch path consumes it.
        poll_calls = 0;
        dispatch_count = 0;
        scalar_data = 32'h1111_aaaa;
        poll_result = 0;
        poll_calls++;
        prepolled_tlp_valid =
            cosim_realization_poll_captured_tlp(poll_result);
        if (!prepolled_tlp_valid)
            $fatal(1, "realization poll ret==0 must retain the scalar TLP");

        if (prepolled_tlp_valid) begin
            poll_result = 0;
            prepolled_tlp_valid = 0;
        end else begin
            poll_calls++;
            scalar_data = 32'h2222_bbbb;
        end
        dispatched_data[dispatch_count++] = scalar_data;
        if (poll_calls != 1 || dispatched_data[0] != 32'h1111_aaaa)
            $fatal(1, "first main-loop dispatch re-polled over the retained TLP");

        if (prepolled_tlp_valid) begin
            poll_result = 0;
            prepolled_tlp_valid = 0;
        end else begin
            poll_calls++;
            poll_result = 0;
            scalar_data = 32'h2222_bbbb;
        end
        dispatched_data[dispatch_count++] = scalar_data;
        if (poll_calls != 2 || dispatched_data[1] != 32'h2222_bbbb)
            $fatal(1, "second main-loop iteration must resume normal polling");
        if (cosim_realization_poll_captured_tlp(1) ||
            cosim_realization_poll_captured_tlp(-1))
            $fatal(1, "empty/error realization polls must not retain a TLP");

        $display("PASS: runtime BDF arithmetic, bind trigger, launch and pre-poll policy");
        $finish;
    end
endmodule
