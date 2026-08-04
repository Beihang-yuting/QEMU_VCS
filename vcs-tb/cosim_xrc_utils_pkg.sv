`ifndef COSIM_XRC_UTILS_PKG_SV
`define COSIM_XRC_UTILS_PKG_SV

package cosim_xrc_utils_pkg;
    function automatic bit [31:0] cosim_pack_cpl_dword_le(
        input byte unsigned payload[],
        input int unsigned base
    );
        cosim_pack_cpl_dword_le = '0;
        for (int b = 0; b < 4 && base + b < payload.size(); b++)
            cosim_pack_cpl_dword_le[b * 8 +: 8] = payload[base + b];
    endfunction
endpackage

`endif
