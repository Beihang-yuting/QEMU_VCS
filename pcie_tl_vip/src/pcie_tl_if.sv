//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - SV Interface
//-----------------------------------------------------------------------------

interface pcie_tl_if(input logic clk, input logic rst_n);

    //-------------------------------------------------------------------------
    // TLP Data Channel
    //-------------------------------------------------------------------------
    logic [255:0]  tlp_data;
    logic [3:0]    tlp_strb;
    logic          tlp_valid;
    logic          tlp_ready;
    logic          tlp_sop;
    logic          tlp_eop;

    //-------------------------------------------------------------------------
    // Flow Control Credit Channel
    //-------------------------------------------------------------------------
    logic [7:0]    ph_credit;
    logic [11:0]   pd_credit;
    logic [7:0]    nph_credit;
    logic [11:0]   npd_credit;
    logic [7:0]    cplh_credit;
    logic [11:0]   cpld_credit;
    logic          fc_update;

    //-------------------------------------------------------------------------
    // Control / Status
    //-------------------------------------------------------------------------
    logic          tlp_error;

    //-------------------------------------------------------------------------
    // Modports
    //-------------------------------------------------------------------------
    modport master (
        input  clk, rst_n,
        output tlp_data, tlp_strb, tlp_valid, tlp_sop, tlp_eop,
        input  tlp_ready,
        input  ph_credit, pd_credit, nph_credit, npd_credit,
               cplh_credit, cpld_credit, fc_update,
        output tlp_error
    );

    modport slave (
        input  clk, rst_n,
        input  tlp_data, tlp_strb, tlp_valid, tlp_sop, tlp_eop,
        output tlp_ready,
        output ph_credit, pd_credit, nph_credit, npd_credit,
               cplh_credit, cpld_credit, fc_update,
        input  tlp_error
    );

    modport monitor (
        input  clk, rst_n,
        input  tlp_data, tlp_strb, tlp_valid, tlp_ready,
               tlp_sop, tlp_eop,
               ph_credit, pd_credit, nph_credit, npd_credit,
               cplh_credit, cpld_credit, fc_update,
               tlp_error
    );

endinterface : pcie_tl_if
