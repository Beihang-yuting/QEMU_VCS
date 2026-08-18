//-----------------------------------------------------------------------------
// Pure launch-policy helpers shared by the cosim driver and standalone tests.
//-----------------------------------------------------------------------------
`ifndef COSIM_RUNTIME_POLICY_PKG_SV
`define COSIM_RUNTIME_POLICY_PKG_SV

package cosim_runtime_policy_pkg;

    function automatic bit cosim_effective_config_bypass(
        input bit real_dut,
        input bit bypass_explicit,
        input int bypass_value
    );
        return bypass_explicit ? (bypass_value != 0) : !real_dut;
    endfunction

    function automatic bit cosim_valid_num_pfs(input int num_pfs);
        return num_pfs >= 1 && num_pfs <= 16;
    endfunction

    function automatic bit cosim_single_bus_profile_fits(
        input int num_pfs,
        input int max_vfs
    );
        longint signed last_devfn;

        if (num_pfs < 1 || max_vfs < 0)
            return 0;
        last_devfn = longint'(num_pfs) - 1;
        if (max_vfs > 0)
            last_devfn += longint'(num_pfs) * longint'(max_vfs);
        return last_devfn <= 255;
    endfunction

    function automatic bit cosim_realization_poll_captured_tlp(
        input int poll_result
    );
        return poll_result == 0;
    endfunction

endpackage : cosim_runtime_policy_pkg

`endif
