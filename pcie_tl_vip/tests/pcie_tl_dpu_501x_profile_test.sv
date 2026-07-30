import uvm_pkg::*;
import pcie_tl_pkg::*;
import pcie_tl_device_profile_pkg::*;
`include "uvm_macros.svh"

// Direct configuration-space regression for the DPU 20f9:501x PF profile.
// It deliberately uses the function manager's public cfg_read/cfg_write API
// rather than looking into the per-function config image.
class pcie_tl_dpu_501x_profile_test extends uvm_test;
    `uvm_component_utils(pcie_tl_dpu_501x_profile_test)

    pcie_tl_func_manager mgr;
    pcie_tl_config_proxy dpu_sriov_proxy;

    function new(string name = "pcie_tl_dpu_501x_profile_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        dpu_sriov_proxy = pcie_tl_config_proxy::type_id::create(
            "dpu_sriov_proxy", this);
    endfunction

    function void expect_dw(
        string label,
        bit [31:0] actual,
        bit [31:0] expected
    );
        if (actual !== expected)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "%s: got 0x%08h, expected 0x%08h", label, actual, expected))
        else
            `uvm_info("DPU_501X_CFG", $sformatf(
                "%s: 0x%08h", label, actual), UVM_LOW)
    endfunction

    // These helpers deliberately exercise the production configuration proxy
    // rather than inspecting cfg_mgr or BAR state arrays directly.
    function void proxy_write_dw(
        bit [15:0] rid,
        int dw_addr,
        bit [31:0] data
    );
        if (!dpu_sriov_proxy.handle_cfg_write_bdf(rid, dw_addr, data, 0, 4))
            `uvm_error("DPU_501X_CFG", $sformatf(
                "proxy did not intercept write RID=%04h DW=%0h", rid, dw_addr))
    endfunction

    function void proxy_write_bytes(
        bit [15:0] rid,
        int dw_addr,
        bit [31:0] packed_data,
        int byte_off,
        int byte_len
    );
        if (!dpu_sriov_proxy.handle_cfg_write_bdf(
                rid, dw_addr, packed_data, byte_off, byte_len))
            `uvm_error("DPU_501X_CFG", $sformatf(
                "proxy did not intercept byte write RID=%04h DW=%0h off=%0d len=%0d",
                rid, dw_addr, byte_off, byte_len))
    endfunction

    function void expect_proxy_dw(
        string label,
        bit [15:0] rid,
        int dw_addr,
        bit [31:0] expected
    );
        bit [31:0] actual;

        if (!dpu_sriov_proxy.handle_cfg_read_bdf(rid, dw_addr, actual))
            `uvm_error("DPU_501X_CFG", $sformatf(
                "%s: proxy did not intercept read RID=%04h DW=%0h", label, rid, dw_addr))
        else
            expect_dw(label, actual, expected);
    endfunction

    function void expect_proxy_paired_bar(
        string label,
        bit [15:0] rid,
        int low_dw,
        bit [31:0] expected_low,
        bit [31:0] expected_high,
        bit [63:0] size
    );
        bit [31:0] low_dw_value;
        bit [31:0] high_dw_value;
        bit [63:0] paired_base;

        if (!dpu_sriov_proxy.handle_cfg_read_bdf(rid, low_dw, low_dw_value) ||
            !dpu_sriov_proxy.handle_cfg_read_bdf(rid, low_dw + 1, high_dw_value)) begin
            `uvm_error("DPU_501X_CFG", $sformatf(
                "%s: proxy did not intercept paired BAR read", label))
            return;
        end
        expect_dw($sformatf("%s low", label), low_dw_value, expected_low);
        expect_dw($sformatf("%s high/paired sibling", label), high_dw_value,
                  expected_high);
        paired_base = {high_dw_value, low_dw_value & 32'hffff_fff0};
        if ((paired_base & (size - 64'd1)) != 0)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "%s: paired base %016h is not aligned to %0d bytes",
                label, paired_base, size))
    endfunction

    function bit [31:0] dpu_pf_bar_sizing_mask(input int bar);
        case (bar)
            0: dpu_pf_bar_sizing_mask = 32'hfe00_000c;
            1: dpu_pf_bar_sizing_mask = 32'hffff_ffff;
            2: dpu_pf_bar_sizing_mask = 32'hffff_000c;
            3: dpu_pf_bar_sizing_mask = 32'hffff_ffff;
            4: dpu_pf_bar_sizing_mask = 32'hffff_000c;
            default: dpu_pf_bar_sizing_mask = 32'hffff_ffff;
        endcase
    endfunction

    function bit [31:0] dpu_vf_bar_sizing_mask(input int bar);
        case (bar)
            0: dpu_vf_bar_sizing_mask = 32'hffff_c00c;
            1: dpu_vf_bar_sizing_mask = 32'hffff_ffff;
            2: dpu_vf_bar_sizing_mask = 32'hffff_c00c;
            3: dpu_vf_bar_sizing_mask = 32'hffff_ffff;
            4: dpu_vf_bar_sizing_mask = 32'hffff_800c;
            default: dpu_vf_bar_sizing_mask = 32'hffff_ffff;
        endcase
    endfunction

    // Walk only extended-capability headers. Payload DWs are deliberately not
    // interpreted as headers, so a value matching a capability ID in payload
    // data cannot produce a false forbidden-capability hit.
    function void expect_no_forbidden_dpu_pf_ext_caps(bit [15:0] rid);
        bit [11:0] cap_offset;
        bit [31:0] cap_header;

        cap_offset = 12'h100;
        for (int hops = 0; hops < 16 && cap_offset != 0; hops++) begin
            cap_header = mgr.cfg_read(rid, cap_offset);
            if (cap_header[15:0] == 16'h000f ||
                cap_header[15:0] == 16'h0013 ||
                cap_header[15:0] == 16'h001b)
                `uvm_error("DPU_501X_CFG", $sformatf(
                    "DPU PF RID %04h advertises forbidden extended capability ID %04h at %03h",
                    rid, cap_header[15:0], cap_offset))
            cap_offset = cap_header[31:20];
        end

        if (cap_offset != 0)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "DPU PF RID %04h extended-capability chain did not terminate within 16 headers",
                rid))
    endfunction

    function void expect_two_pf_rids_unique(pcie_tl_func_manager fresh_mgr);
        bit seen_rids[bit [15:0]];
        bit [15:0] rid;

        for (int pf = 0; pf < 2; pf++) begin
            rid = fresh_mgr.pf_ctx[pf].bdf;
            if (seen_rids.exists(rid))
                `uvm_error("DPU_501X_CFG", $sformatf(
                    "2-PF DPU topology aliases PF RID %04h", rid))
            seen_rids[rid] = 1'b1;
        end
        for (int pf = 0; pf < 2; pf++) begin
            for (int vf = 0; vf < 16; vf++) begin
                rid = fresh_mgr.sriov_caps[pf].get_vf_rid(vf);
                if (seen_rids.exists(rid))
                    `uvm_error("DPU_501X_CFG", $sformatf(
                        "2-PF DPU topology aliases PF%0d VF%0d RID %04h",
                        pf, vf, rid))
                seen_rids[rid] = 1'b1;
            end
        end
    endfunction

    task run_phase(uvm_phase phase);
        bit [31:0] msix_before;
        bit [31:0] msix_after;
        bit [31:0] expected_offset_stride;
        bit [31:0] expected_ari_next;
        pcie_tl_func_manager two_pf_mgr;
        pcie_tl_func_manager legacy_mgr;
        int dpu_sriov_dw_base;
        int legacy_sriov_dw_base;
        int active_count_before;
        bit [31:0] proxy_read_data;

        phase.raise_objection(this);

        mgr = pcie_tl_func_manager::type_id::create("mgr");
        mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        mgr.build_topology(0, 4, 16, 16'h20f9, 16'h5011, 16'h8689);

        expect_dw("PF0 vendor/device", mgr.cfg_read(16'h0100, 12'h000),
                  32'h5011_20f9);
        expect_dw("PF1 vendor/device", mgr.cfg_read(16'h0101, 12'h000),
                  32'h5012_20f9);
        expect_dw("PF0 class/revision", mgr.cfg_read(16'h0100, 12'h008),
                  32'h0200_0000);
        expect_dw("PF0 subsystem", mgr.cfg_read(16'h0100, 12'h02c),
                  32'h0000_20f9);
        expect_dw("PF0 capability pointer", mgr.cfg_read(16'h0100, 12'h034),
                  32'h0000_0040);
        expect_dw("PF0 PM capability", mgr.cfg_read(16'h0100, 12'h040),
                  32'h0003_6001);
        // PMC occupies bytes +2/+3. A write using only those byte enables
        // must not alter the static version/capability bits or the cap header.
        mgr.cfg_write(16'h0100, 12'h040, 32'hffff_0000, 4'b1100);
        expect_dw("PF0 PM capability protected", mgr.cfg_read(16'h0100, 12'h040),
                  32'h0003_6001);
        // PMCSR is a separate, dynamic DW and must remain writable.
        mgr.cfg_write(16'h0100, 12'h044, 32'h0000_0003, 4'b0001);
        expect_dw("PF0 PMCSR write", mgr.cfg_read(16'h0100, 12'h044),
                  32'h0000_0003);

        msix_before = mgr.cfg_read(16'h0100, 12'h060);
        expect_dw("PF0 MSI-X capability", msix_before, 32'h000f_7011);
        expect_dw("PF0 MSI-X table", mgr.cfg_read(16'h0100, 12'h064),
                  32'h0000_0004);
        expect_dw("PF0 MSI-X PBA", mgr.cfg_read(16'h0100, 12'h068),
                  32'h0000_4004);
        expect_dw("PF0 PCIe capability", mgr.cfg_read(16'h0100, 12'h070),
                  32'h0002_0010);
        expect_dw("PF0 Device Capabilities", mgr.cfg_read(16'h0100, 12'h074),
                  32'h0000_8022);
        expect_dw("PF0 Device Control reset", mgr.cfg_read(16'h0100, 12'h078),
                  32'h0000_0000);
        expect_dw("PF0 Link Capabilities", mgr.cfg_read(16'h0100, 12'h07c),
                  32'h0043_f043);
        expect_dw("PF0 Link Status", mgr.cfg_read(16'h0100, 12'h080),
                  32'h1043_0000);
        expect_dw("PF0 Device Capabilities 2", mgr.cfg_read(16'h0100, 12'h094),
                  32'h0000_0016);
        expect_dw("PF0 Link Capabilities 2", mgr.cfg_read(16'h0100, 12'h09c),
                  32'h0000_000e);
        expect_dw("PF0 Link Status 2", mgr.cfg_read(16'h0100, 12'h0a0),
                  32'h001e_0000);

        // DPU-only extended capability chain. These checks intentionally use
        // public configuration reads rather than inspecting cfg_space.
        expect_dw("PF0 AER v1 header", mgr.cfg_read(16'h0100, 12'h100),
                  32'h1401_0001);
        expect_dw("PF0 SR-IOV v1 header", mgr.cfg_read(16'h0100, 12'h140),
                  32'h1801_0010);
        expect_dw("PF0 ARI v1 header", mgr.cfg_read(16'h0100, 12'h180),
                  32'h1c01_000e);
        expect_dw("PF0 Secondary PCIe v1 header", mgr.cfg_read(16'h0100, 12'h1c0),
                  32'h4001_0019);
        expect_dw("PF0 ACS v1 terminal header", mgr.cfg_read(16'h0100, 12'h400),
                  32'h0001_000d);

        // Captured AER payload: status is clear at reset; masks and severity
        // are host-programmable values, not status/control snapshots.
        expect_dw("PF0 AER UE Status reset", mgr.cfg_read(16'h0100, 12'h104),
                  32'h0000_0000);
        expect_dw("PF0 AER UE Mask", mgr.cfg_read(16'h0100, 12'h108),
                  32'h0040_0000);
        expect_dw("PF0 AER UE Severity", mgr.cfg_read(16'h0100, 12'h10c),
                  32'h0046_2030);
        expect_dw("PF0 AER CE Status reset", mgr.cfg_read(16'h0100, 12'h110),
                  32'h0000_0000);
        expect_dw("PF0 AER CE Mask", mgr.cfg_read(16'h0100, 12'h114),
                  32'h0000_e000);
        mgr.cfg_write(16'h0100, 12'h100, 32'hffff_ffff, 4'b1111);
        expect_dw("PF0 AER header protected", mgr.cfg_read(16'h0100, 12'h100),
                  32'h1401_0001);
        mgr.cfg_write(16'h0100, 12'h104, 32'hffff_ffff, 4'b1111);
        expect_dw("PF0 AER UE Status RW1C", mgr.cfg_read(16'h0100, 12'h104),
                  32'h0000_0000);
        mgr.cfg_write(16'h0100, 12'h108, 32'h0000_000a, 4'b1111);
        expect_dw("PF0 AER UE Mask writable", mgr.cfg_read(16'h0100, 12'h108),
                  32'h0000_000a);
        mgr.cfg_write(16'h0100, 12'h10c, 32'h0000_000b, 4'b1111);
        expect_dw("PF0 AER UE Severity writable", mgr.cfg_read(16'h0100, 12'h10c),
                  32'h0000_000b);

        expect_dw("PF0 Secondary PCIe zero payload", mgr.cfg_read(16'h0100, 12'h1c4),
                  32'h0000_0000);
        expect_dw("PF0 ACS captured payload", mgr.cfg_read(16'h0100, 12'h404),
                  32'h0000_2020);
        mgr.cfg_write(16'h0100, 12'h404, 32'hffff_ffff, 4'b1111);
        expect_dw("PF0 ACS payload protected", mgr.cfg_read(16'h0100, 12'h404),
                  32'h0000_2020);

        for (int pf = 0; pf < 4; pf++) begin
            case (pf)
                0: expected_offset_stride = 32'h0001_0004;
                1: expected_offset_stride = 32'h0001_0013;
                2: expected_offset_stride = 32'h0001_0022;
                default: expected_offset_stride = 32'h0001_0031;
            endcase
            expected_ari_next = (pf + 1 < 4) ? ((pf + 1) << 8) : 32'h0;
            expect_dw($sformatf("PF%0d SR-IOV InitialVFs/TotalVFs", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h14c), 32'h0010_0010);
            expect_dw($sformatf("PF%0d SR-IOV NumVFs/FDL", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h150), pf << 16);
            expect_dw($sformatf("PF%0d SR-IOV FirstVFOffset/VFStride", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h154), expected_offset_stride);
            expect_dw($sformatf("PF%0d SR-IOV VF Device ID", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h158), 32'h8689_0000);
            expect_dw($sformatf("PF%0d SR-IOV Supported Page Sizes", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h15c), 32'h0000_0553);
            expect_dw($sformatf("PF%0d SR-IOV System Page Size", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h160), 32'h0000_0001);
            expect_dw($sformatf("PF%0d ARI Next Function", pf),
                      mgr.cfg_read(16'h0100 + pf, 12'h184) & 32'h0000_ff00,
                      expected_ari_next);
        end
        mgr.cfg_write(16'h0100, 12'h150, 32'h0000_0005, 4'b0011);
        expect_dw("PF0 SR-IOV NumVFs writable", mgr.cfg_read(16'h0100, 12'h150),
                  32'h0000_0005);

        // Exercise the normal multi-function config proxy path: DPU SR-IOV
        // starts at 0x140, so Control/NumVFs/VF BAR0 are DW 0x52/0x54/0x59.
        dpu_sriov_proxy.func_mgr = mgr;
        dpu_sriov_proxy.multi_function_mode = 1'b1;
        dpu_sriov_dw_base = int'(mgr.sriov_caps[0].offset >> 2);
        if (dpu_sriov_dw_base != 'h50)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "DPU SR-IOV base DW is %0h, expected 50", dpu_sriov_dw_base))

        // The raw manager image must already describe the DPU BAR pairs; this
        // protects direct config reads before a proxy-side BAR transaction.
        expect_dw("DPU PF BAR0 reset image", mgr.cfg_read(16'h0100, 12'h010),
                  32'h0000_000c);
        expect_dw("DPU PF BAR1 reset image", mgr.cfg_read(16'h0100, 12'h014),
                  32'h0000_0000);
        expect_dw("DPU PF BAR2 reset image", mgr.cfg_read(16'h0100, 12'h018),
                  32'h0000_000c);
        expect_dw("DPU PF BAR3 reset image", mgr.cfg_read(16'h0100, 12'h01c),
                  32'h0000_0000);
        expect_dw("DPU PF BAR4 reset image", mgr.cfg_read(16'h0100, 12'h020),
                  32'h0000_000c);
        expect_dw("DPU PF BAR5 reset image", mgr.cfg_read(16'h0100, 12'h024),
                  32'h0000_0000);
        expect_dw("DPU VF BAR0 reset image", mgr.cfg_read(16'h0100, 12'h164),
                  32'h0000_000c);
        expect_dw("DPU VF BAR1 reset image", mgr.cfg_read(16'h0100, 12'h168),
                  32'h0000_0000);
        expect_dw("DPU VF BAR2 reset image", mgr.cfg_read(16'h0100, 12'h16c),
                  32'h0000_000c);
        expect_dw("DPU VF BAR3 reset image", mgr.cfg_read(16'h0100, 12'h170),
                  32'h0000_0000);
        expect_dw("DPU VF BAR4 reset image", mgr.cfg_read(16'h0100, 12'h174),
                  32'h0000_000c);
        expect_dw("DPU VF BAR5 reset image", mgr.cfg_read(16'h0100, 12'h178),
                  32'h0000_0000);

        // Every DPU BAR register is a word of one of three 64-bit,
        // prefetchable apertures. Exercise exact full-DWORD writes through the
        // configuration proxy and require both halves of each sizing mask.
        for (int bar = 0; bar < 6; bar++) begin
            proxy_write_dw(16'h0100, 4 + bar, 32'hffff_ffff);
            expect_proxy_dw($sformatf("DPU PF BAR%0d sizing", bar), 16'h0100,
                            4 + bar, dpu_pf_bar_sizing_mask(bar));
        end
        for (int bar = 0; bar < 6; bar++) begin
            proxy_write_dw(16'h0100, dpu_sriov_dw_base + 9 + bar, 32'hffff_ffff);
            expect_proxy_dw($sformatf("DPU VF BAR%0d sizing", bar), 16'h0100,
                            dpu_sriov_dw_base + 9 + bar, dpu_vf_bar_sizing_mask(bar));
        end

        // Low and high writes must form one aligned 64-bit BAR. The non-zero
        // high words prove BAR1/BAR5 are paired high halves, not independent
        // BARs; the low DWORD always retains its 64-bit/prefetchable flags.
        proxy_write_dw(16'h0100, 4, 32'h3456_7890);
        proxy_write_dw(16'h0100, 5, 32'h0000_0012);
        expect_proxy_paired_bar("DPU PF BAR0/BAR1", 16'h0100, 4,
                                32'h3400_000c, 32'h0000_0012,
                                64'd32 * 1024 * 1024);
        proxy_write_dw(16'h0100, 8, 32'h5678_9870);
        proxy_write_dw(16'h0100, 9, 32'h0000_0023);
        expect_proxy_paired_bar("DPU PF BAR4/BAR5", 16'h0100, 8,
                                32'h5678_000c, 32'h0000_0023,
                                64'd64 * 1024);

        // Packed byte-lane writes exercise the Task4 merge path in both
        // halves of the same 64-bit BAR pair, not just SR-IOV control fields.
        proxy_write_dw(16'h0100, 6, 32'h1111_0000);
        proxy_write_dw(16'h0100, 7, 32'h0000_0055);
        proxy_write_bytes(16'h0100, 6, 32'h0000_00ab, 2, 1);
        proxy_write_bytes(16'h0100, 7, 32'h0000_00cd, 1, 1);
        expect_proxy_paired_bar("DPU PF BAR2/BAR3 packed-byte writes", 16'h0100,
                                6, 32'h11ab_000c, 32'h0000_cd55,
                                64'd64 * 1024);

        proxy_write_dw(16'h0100, dpu_sriov_dw_base + 9, 32'h9abc_def0);
        proxy_write_dw(16'h0100, dpu_sriov_dw_base + 10, 32'h0000_0034);
        expect_proxy_paired_bar("DPU VF BAR0/BAR1", 16'h0100,
                                dpu_sriov_dw_base + 9, 32'h9abc_c00c,
                                32'h0000_0034, 64'd16 * 1024);
        proxy_write_dw(16'h0100, dpu_sriov_dw_base + 13, 32'h1234_7890);
        proxy_write_dw(16'h0100, dpu_sriov_dw_base + 14, 32'h0000_0045);
        expect_proxy_paired_bar("DPU VF BAR4/BAR5", 16'h0100,
                                dpu_sriov_dw_base + 13, 32'h1234_000c,
                                32'h0000_0045, 64'd32 * 1024);

        // BAR programming must not alter the captured MSI-X Table/PBA BIR or
        // offsets; both point at the implemented PF BAR4 aperture.
        expect_proxy_dw("DPU MSI-X Table after BAR programming", 16'h0100,
                        12'h064 >> 2, 32'h0000_0004);
        expect_proxy_dw("DPU MSI-X PBA after BAR programming", 16'h0100,
                        12'h068 >> 2, 32'h0000_4004);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 4,
                                                   32'h0000_0001, 0, 4));
        if (mgr.sriov_caps[0].num_vfs != 16'h0001)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "DPU proxy NumVFs state is %0d, expected 1", mgr.sriov_caps[0].num_vfs))
        expect_dw("DPU proxy NumVFs raw config", mgr.cfg_read(16'h0100, 12'h150),
                  32'h0000_0001);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 2,
                                                   32'h0000_0001));
        if (!mgr.sriov_caps[0].vf_enable || !mgr.vf_ctx[0][0].enabled ||
            mgr.lookup_by_bdf(mgr.sriov_caps[0].get_vf_rid(0)) == null)
            `uvm_error("DPU_501X_CFG",
                "DPU proxy VF Enable did not activate VF0 through the BDF lookup")
        expect_dw("DPU proxy VF Enable raw config", mgr.cfg_read(16'h0100, 12'h148),
                  32'h0000_0001);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 9,
                                                   32'h3456_7000, 0, 4));
        expect_dw("DPU proxy VF BAR0 raw config", mgr.cfg_read(16'h0100, 12'h164),
                  32'h3456_400c);
        expect_dw("DPU proxy VF BAR0 model", mgr.sriov_caps[0].vf_bar[0],
                  32'h3456_4000);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 2,
                                                   32'h0000_0000));
        if (mgr.sriov_caps[0].vf_enable || mgr.vf_ctx[0][0].enabled ||
            mgr.lookup_by_bdf(mgr.sriov_caps[0].get_vf_rid(0)) != null)
            `uvm_error("DPU_501X_CFG",
                "DPU proxy VF Disable did not tear down VF0 state and BDF lookup")
        expect_dw("DPU proxy VF Disable raw config", mgr.cfg_read(16'h0100, 12'h148),
                  32'h0000_0000);

        // QEMU packs a partial configuration payload at data[7:0] and passes
        // its target byte separately. A write to SR-IOV Status (byte 2) must
        // neither be mistaken for VFE nor overwrite the Control byte. Status
        // is reset-clear RW1C, so writing one leaves the status byte clear.
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 2,
                                                   32'h0000_0001, 2, 1));
        if (mgr.sriov_caps[0].vf_enable || mgr.vf_ctx[0][0].enabled ||
            mgr.get_active_count() != 4)
            `uvm_error("DPU_501X_CFG",
                "DPU proxy Status-byte write changed the VF enable lifecycle")
        expect_dw("DPU proxy Status byte preserves Control", mgr.cfg_read(16'h0100, 12'h148),
                  32'h0000_0000);

        // Update only the high NumVFs byte. The packed 0x02 must land in byte
        // one, producing 0x0201 rather than replacing the low byte with 0x02.
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 4,
                                                   32'h0000_0002, 1, 1));
        if (mgr.sriov_caps[0].num_vfs != 16'h0201)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "DPU proxy partial NumVFs is %04h, expected 0201",
                mgr.sriov_caps[0].num_vfs))
        expect_dw("DPU proxy partial NumVFs raw config", mgr.cfg_read(16'h0100, 12'h150),
                  32'h0000_0201);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 4,
                                                   32'h0000_0000, 1, 1));
        if (mgr.sriov_caps[0].num_vfs != 16'h0001)
            `uvm_error("DPU_501X_CFG", "DPU proxy partial NumVFs restore failed")

        // A low-byte VFE write enables exactly once. A subsequent control-byte
        // update that retains VFE changes only other control state and must
        // preserve the active-function count and VF lifecycle. The standalone
        // filelist has DPI disabled, so this observes model state rather than
        // bridge event count.
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 2,
                                                   32'h0000_0001, 0, 1));
        active_count_before = mgr.get_active_count();
        if (!mgr.sriov_caps[0].vf_enable || !mgr.vf_ctx[0][0].enabled ||
            active_count_before != 5)
            `uvm_error("DPU_501X_CFG",
                "DPU proxy low-byte VFE write did not enable exactly one VF")
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 2,
                                                   32'h0000_0009, 0, 1));
        if (!mgr.sriov_caps[0].vf_enable || !mgr.vf_ctx[0][0].enabled ||
            mgr.get_active_count() != active_count_before)
            `uvm_error("DPU_501X_CFG",
                "DPU proxy retained-VFE Control update changed VF lifecycle")
        expect_dw("DPU proxy retained-VFE Control raw config",
                  mgr.cfg_read(16'h0100, 12'h148), 32'h0000_0009);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 2,
                                                   32'h0000_0000, 0, 1));
        if (mgr.sriov_caps[0].vf_enable || mgr.vf_ctx[0][0].enabled ||
            mgr.get_active_count() != 4)
            `uvm_error("DPU_501X_CFG",
                "DPU proxy low-byte VFE clear did not disable VF0")

        // VF BAR read handling must use the same derived DPU base. Verify an
        // assigned value and then the BAR0 sizing response.
        void'(dpu_sriov_proxy.handle_cfg_read_bdf(16'h0100, dpu_sriov_dw_base + 9,
                                                  proxy_read_data));
        expect_dw("DPU proxy VF BAR0 read", proxy_read_data, 32'h3456_400c);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, dpu_sriov_dw_base + 9,
                                                   32'hffff_ffff, 0, 4));
        void'(dpu_sriov_proxy.handle_cfg_read_bdf(16'h0100, dpu_sriov_dw_base + 9,
                                                  proxy_read_data));
        expect_dw("DPU proxy VF BAR0 sizing read", proxy_read_data, 32'hffff_c00c);

        // Legacy SR-IOV remains at 0x200: the derived positions retain the
        // historical NumVFs/Control DWs 0x84/0x82 and their behavior.
        legacy_mgr = pcie_tl_func_manager::type_id::create("legacy_sriov_mgr");
        legacy_mgr.build_topology(0, 1, 16, 16'habcd, 16'h1234, 16'h1235);
        dpu_sriov_proxy.func_mgr = legacy_mgr;
        dpu_sriov_proxy.multi_function_mode = 1'b1;
        legacy_sriov_dw_base = int'(legacy_mgr.sriov_caps[0].offset >> 2);
        if (legacy_sriov_dw_base != 'h80)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "Legacy SR-IOV base DW is %0h, expected 80", legacy_sriov_dw_base))
        // Legacy keeps its original single 64KiB BAR0 and no accidental DPU
        // BAR2/BAR4 apertures or 64-bit/prefetchable type bits appear.
        proxy_write_dw(16'h0100, 4, 32'hffff_ffff);
        expect_proxy_dw("Legacy PF BAR0 sizing", 16'h0100, 4, 32'hffff_0000);
        proxy_write_dw(16'h0100, 4, 32'h2468_0000);
        expect_proxy_dw("Legacy PF BAR0 assignment", 16'h0100, 4, 32'h2468_0000);
        expect_proxy_dw("Legacy PF BAR2 remains absent", 16'h0100, 6, 32'h0000_0000);
        expect_proxy_dw("Legacy PF BAR4 remains absent", 16'h0100, 8, 32'h0000_0000);
        proxy_write_dw(16'h0100, 6, 32'hffff_ffff);
        expect_proxy_dw("Legacy PF BAR2 sizing remains absent", 16'h0100, 6,
                        32'h0000_0000);
        proxy_write_dw(16'h0100, 8, 32'hffff_ffff);
        expect_proxy_dw("Legacy PF BAR4 sizing remains absent", 16'h0100, 8,
                        32'h0000_0000);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, legacy_sriov_dw_base + 4,
                                                   32'h0000_0001));
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, legacy_sriov_dw_base + 2,
                                                   32'h0000_0001));
        if (!legacy_mgr.sriov_caps[0].vf_enable || !legacy_mgr.vf_ctx[0][0].enabled)
            `uvm_error("DPU_501X_CFG",
                "Legacy proxy SR-IOV DW 84/82 sequence did not activate VF0")
        expect_dw("Legacy proxy NumVFs raw config",
                  legacy_mgr.cfg_read(16'h0100, 12'h210), 32'h0000_0001);
        expect_dw("Legacy proxy VF Enable raw config",
                  legacy_mgr.cfg_read(16'h0100, 12'h208), 32'h0000_0001);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, legacy_sriov_dw_base + 9,
                                                   32'h2468_0000, 0, 4));
        void'(dpu_sriov_proxy.handle_cfg_read_bdf(16'h0100, legacy_sriov_dw_base + 9,
                                                  proxy_read_data));
        expect_dw("Legacy proxy VF BAR0 read", proxy_read_data, 32'h2468_0000);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, legacy_sriov_dw_base + 9,
                                                   32'hffff_ffff, 0, 4));
        void'(dpu_sriov_proxy.handle_cfg_read_bdf(16'h0100, legacy_sriov_dw_base + 9,
                                                  proxy_read_data));
        expect_dw("Legacy proxy VF BAR0 sizing read", proxy_read_data, 32'hffff_0000);
        void'(dpu_sriov_proxy.handle_cfg_write_bdf(16'h0100, legacy_sriov_dw_base + 2,
                                                   32'h0000_0000));
        if (legacy_mgr.sriov_caps[0].vf_enable || legacy_mgr.vf_ctx[0][0].enabled)
            `uvm_error("DPU_501X_CFG",
                "Legacy proxy SR-IOV Control disable did not tear down VF0")

        expect_no_forbidden_dpu_pf_ext_caps(16'h0100);

        // Construct a fresh topology to prevent a previous UVM object or BDF
        // lookup table from masking the 2-PF arithmetic.
        two_pf_mgr = pcie_tl_func_manager::type_id::create("two_pf_mgr");
        two_pf_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
        two_pf_mgr.build_topology(0, 2, 16, 16'h20f9, 16'h5011, 16'h8689);
        expect_dw("2-PF PF0 FirstVFOffset/VFStride",
                  two_pf_mgr.cfg_read(16'h0100, 12'h154), 32'h0001_0002);
        expect_dw("2-PF PF1 FirstVFOffset/VFStride",
                  two_pf_mgr.cfg_read(16'h0101, 12'h154), 32'h0001_0011);
        expect_dw("2-PF PF0 FDL", two_pf_mgr.cfg_read(16'h0100, 12'h150),
                  32'h0000_0000);
        expect_dw("2-PF PF1 FDL", two_pf_mgr.cfg_read(16'h0101, 12'h150),
                  32'h0001_0000);
        expect_two_pf_rids_unique(two_pf_mgr);

        // Captured control fields remain writable and Device Control must not
        // be initialized from the captured host-programmed 0x2910 value.
        mgr.cfg_write(16'h0100, 12'h078, 32'h0000_2910, 4'b0011);
        expect_dw("PF0 Device Control write", mgr.cfg_read(16'h0100, 12'h078),
                  32'h0000_2910);
        mgr.cfg_write(16'h0100, 12'h080, 32'h0000_0001, 4'b0011);
        expect_dw("PF0 Link Control write", mgr.cfg_read(16'h0100, 12'h080),
                  32'h1043_0001);

        // MSI-X Enable is Message Control bit 15, byte 3 of the capability
        // header DW. This deliberately also attempts to overwrite Table Size
        // [10:8] and reserved bits [13:11] through the real BE path.
        mgr.cfg_write(16'h0100, 12'h060, 32'hbf00_0000, 4'b1000);
        msix_after = mgr.cfg_read(16'h0100, 12'h060);
        if (msix_after[26:16] !== 11'h00f)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "MSI-X table size changed after Enable write: got 0x%03h, expected 0x00f",
                msix_after[26:16]))
        if (msix_after[29:27] !== 3'b000)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "MSI-X reserved Message Control bits changed: got 0x%01h, expected 0",
                msix_after[29:27]))
        if (msix_after[31] !== 1'b1)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "MSI-X Enable did not set: got header 0x%08h", msix_after))

        // Function Mask (bit14) shares the byte but is independently writable.
        mgr.cfg_write(16'h0100, 12'h060, 32'hc000_0000, 4'b1000);
        msix_after = mgr.cfg_read(16'h0100, 12'h060);
        if (msix_after[30] !== 1'b1)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "MSI-X Function Mask did not set: got header 0x%08h", msix_after))
        if (msix_after[26:16] !== 11'h00f || msix_after[29:27] !== 3'b000 ||
            msix_after[31] !== 1'b1)
            `uvm_error("DPU_501X_CFG", $sformatf(
                "MSI-X Function Mask write changed protected bits: got header 0x%08h",
                msix_after))

        phase.drop_objection(this);
    endtask
endclass
