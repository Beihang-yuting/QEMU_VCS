//-----------------------------------------------------------------------------
// Immutable PCIe device-profile helpers shared by configuration-space models.
//-----------------------------------------------------------------------------
package pcie_tl_device_profile_pkg;

    typedef enum int {
        PCIE_CFG_PROFILE_LEGACY = 0,
        PCIE_CFG_PROFILE_DPU_20F9_501X = 1
    } pcie_cfg_profile_e;

    function automatic bit pcie_cfg_profile_parse(input string name);
        pcie_cfg_profile_parse =
            name == "" || name == "LEGACY" || name == "DPU_20F9_501X";
    endfunction

    function automatic pcie_cfg_profile_e pcie_cfg_profile_value(
        input string name
    );
        if (name == "DPU_20F9_501X")
            pcie_cfg_profile_value = PCIE_CFG_PROFILE_DPU_20F9_501X;
        else
            pcie_cfg_profile_value = PCIE_CFG_PROFILE_LEGACY;
    endfunction

    function automatic bit [15:0] pcie_dpu_pf_device_id(input int pf);
        pcie_dpu_pf_device_id = 16'h5011 + pf;
    endfunction

    function automatic int unsigned pcie_dpu_first_vf_offset(
        input int unsigned num_pfs,
        input int unsigned pf
    );
        pcie_dpu_first_vf_offset = num_pfs + pf * 15;
    endfunction

    function automatic int unsigned pcie_dpu_bar_size(
        input bit is_vf,
        input int bar
    );
        pcie_dpu_bar_size = 0;
        if (is_vf) begin
            case (bar)
                0, 2: pcie_dpu_bar_size = 16 * 1024;
                4:    pcie_dpu_bar_size = 32 * 1024;
                default: ;
            endcase
        end else begin
            case (bar)
                0:    pcie_dpu_bar_size = 32 * 1024 * 1024;
                2, 4: pcie_dpu_bar_size = 64 * 1024;
                default: ;
            endcase
        end
    endfunction

    function automatic bit [31:0] pcie_dpu_bar_flags(input int bar);
        case (bar)
            0, 2, 4: pcie_dpu_bar_flags = 32'h0000_000c;
            default: pcie_dpu_bar_flags = 32'h0000_0000;
        endcase
    endfunction

    function automatic bit [31:0] pcie_bar_sizing_dw(
        input int unsigned size,
        input bit [31:0] flags,
        input bit upper
    );
        bit [63:0] size64;
        bit [63:0] mask;

        if (size == 0) begin
            pcie_bar_sizing_dw = 32'h0000_0000;
        end else begin
            size64 = size;
            mask = ~(size64 - 64'd1);
            if (upper)
                pcie_bar_sizing_dw = mask[63:32];
            else
                pcie_bar_sizing_dw = mask[31:0] | flags;
        end
    endfunction

endpackage : pcie_tl_device_profile_pkg
