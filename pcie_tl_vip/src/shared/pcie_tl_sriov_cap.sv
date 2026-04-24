//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - SR-IOV Extended Capability
//-----------------------------------------------------------------------------

class pcie_tl_sriov_cap extends pcie_ext_capability;
    `uvm_object_utils(pcie_tl_sriov_cap)

    //--- Set by func_manager to identify which PF owns this capability ---
    bit [15:0] pf_bdf;

    //--- SR-IOV Capability Register fields ---
    bit        vf_migration_capable;
    bit        ari_capable_hierarchy;

    //--- SR-IOV Control Register fields ---
    bit        vf_enable;
    bit        vf_migration_enable;
    bit        ari_capable;
    bit        vf_mse;

    //--- SR-IOV Status ---
    bit        vf_migration_status;

    //--- SR-IOV Parameters ---
    bit [15:0] initial_vfs     = 16'h0000;
    bit [15:0] total_vfs       = 16'd256;
    bit [15:0] num_vfs         = 16'h0000;
    bit [15:0] first_vf_offset = 16'h0001;
    bit [15:0] vf_stride       = 16'h0001;
    bit [15:0] vf_device_id    = 16'h1235;

    //--- VF BAR registers ---
    bit [31:0] vf_bar[6];

    //--- Page size registers ---
    bit [31:0] supported_page_sizes = 32'h00000553;
    bit [31:0] system_page_size     = 32'h00000001;

    function new(string name = "pcie_tl_sriov_cap");
        super.new(name);
        cap_id  = EXT_CAP_ID_SRIOV;
        cap_ver = 4'h1;
        foreach (vf_bar[i]) vf_bar[i] = 32'h0;
    endfunction

    //=========================================================================
    // Compute Routing ID for a given VF index (0-based)
    //=========================================================================
    function bit [15:0] get_vf_rid(int vf_idx);
        return pf_bdf + first_vf_offset + vf_idx * vf_stride;
    endfunction

    //=========================================================================
    // Serialize all SR-IOV registers into data[] (60 bytes)
    // Covers config space at offset+0x04 through offset+0x3F
    //
    // Byte layout:
    //   [0..3]   SR-IOV Capabilities
    //   [4..5]   SR-IOV Control
    //   [6..7]   SR-IOV Status
    //   [8..9]   InitialVFs
    //   [10..11] TotalVFs
    //   [12..13] NumVFs
    //   [14..15] FuncDepLink (zeros)
    //   [16..17] First VF Offset
    //   [18..19] VF Stride
    //   [20..21] Reserved
    //   [22..23] VF Device ID
    //   [24..27] Supported Page Sizes
    //   [28..31] System Page Size
    //   [32..55] VF BAR[0..5] (6 x 4 bytes)
    //   [56..59] VF Migration State Array Offset (zeros)
    //=========================================================================
    function void build_data();
        bit [31:0] sriov_cap_reg;
        bit [15:0] sriov_ctrl_reg;
        bit [15:0] sriov_stat_reg;

        data = new[60];

        // SR-IOV Capabilities Register
        sriov_cap_reg      = 32'h0;
        sriov_cap_reg[0]   = vf_migration_capable;
        sriov_cap_reg[1]   = ari_capable_hierarchy;
        data[0]  = sriov_cap_reg[7:0];
        data[1]  = sriov_cap_reg[15:8];
        data[2]  = sriov_cap_reg[23:16];
        data[3]  = sriov_cap_reg[31:24];

        // SR-IOV Control Register
        sriov_ctrl_reg     = 16'h0;
        sriov_ctrl_reg[0]  = vf_enable;
        sriov_ctrl_reg[1]  = vf_migration_enable;
        sriov_ctrl_reg[3]  = ari_capable;
        sriov_ctrl_reg[4]  = vf_mse;
        data[4]  = sriov_ctrl_reg[7:0];
        data[5]  = sriov_ctrl_reg[15:8];

        // SR-IOV Status Register
        sriov_stat_reg     = 16'h0;
        sriov_stat_reg[0]  = vf_migration_status;
        data[6]  = sriov_stat_reg[7:0];
        data[7]  = sriov_stat_reg[15:8];

        // InitialVFs
        data[8]  = initial_vfs[7:0];
        data[9]  = initial_vfs[15:8];

        // TotalVFs
        data[10] = total_vfs[7:0];
        data[11] = total_vfs[15:8];

        // NumVFs
        data[12] = num_vfs[7:0];
        data[13] = num_vfs[15:8];

        // FuncDepLink (reserved/zero)
        data[14] = 8'h00;
        data[15] = 8'h00;

        // First VF Offset
        data[16] = first_vf_offset[7:0];
        data[17] = first_vf_offset[15:8];

        // VF Stride
        data[18] = vf_stride[7:0];
        data[19] = vf_stride[15:8];

        // Reserved
        data[20] = 8'h00;
        data[21] = 8'h00;

        // VF Device ID
        data[22] = vf_device_id[7:0];
        data[23] = vf_device_id[15:8];

        // Supported Page Sizes
        data[24] = supported_page_sizes[7:0];
        data[25] = supported_page_sizes[15:8];
        data[26] = supported_page_sizes[23:16];
        data[27] = supported_page_sizes[31:24];

        // System Page Size
        data[28] = system_page_size[7:0];
        data[29] = system_page_size[15:8];
        data[30] = system_page_size[23:16];
        data[31] = system_page_size[31:24];

        // VF BAR[0..5]
        for (int i = 0; i < 6; i++) begin
            int base = 32 + i * 4;
            data[base]     = vf_bar[i][7:0];
            data[base + 1] = vf_bar[i][15:8];
            data[base + 2] = vf_bar[i][23:16];
            data[base + 3] = vf_bar[i][31:24];
        end

        // VF Migration State Array Offset (zeros)
        data[56] = 8'h00;
        data[57] = 8'h00;
        data[58] = 8'h00;
        data[59] = 8'h00;
    endfunction

endclass
