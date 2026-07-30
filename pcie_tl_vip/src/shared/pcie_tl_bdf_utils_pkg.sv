//-----------------------------------------------------------------------------
// PCIe BDF arithmetic shared by the cosim configuration model and small tests.
//-----------------------------------------------------------------------------
package pcie_tl_bdf_utils_pkg;

    function automatic bit [15:0] pcie_pf_base_bdf(
        input bit [15:0] observed_pf0_bdf
    );
        return observed_pf0_bdf & 16'hFFF8;
    endfunction

    function automatic bit [15:0] pcie_pf_bdf(
        input bit [15:0] base_bdf,
        input int        pf_index
    );
        return base_bdf + pf_index;
    endfunction

    function automatic bit [15:0] pcie_vf_bdf(
        input bit [15:0] pf_bdf,
        input int        first_vf_offset,
        input int        vf_stride,
        input int        vf_index
    );
        return pf_bdf + first_vf_offset + vf_index * vf_stride;
    endfunction

    function automatic bit pcie_should_bind_runtime_bdf(
        input bit        bypass_enable,
        input bit        runtime_bdf_bound,
        input int        dw_addr,
        input bit [15:0] target_bdf
    );
        return bypass_enable && !runtime_bdf_bound &&
               dw_addr == 0 && target_bdf[2:0] == 3'b000;
    endfunction

endpackage : pcie_tl_bdf_utils_pkg
