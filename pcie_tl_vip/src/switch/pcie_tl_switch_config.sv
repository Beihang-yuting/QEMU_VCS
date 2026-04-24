//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Configuration
//-----------------------------------------------------------------------------

class pcie_tl_switch_config extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_config)

    //--- Topology ---
    int num_ds_ports = 4;

    //--- Switch identity ---
    bit [15:0] switch_bdf = 16'h0100;

    //--- Mode ---
    bit enum_mode  = 0;
    bit p2p_enable = 1;

    //--- USP config (static mode) ---
    bit [7:0] usp_primary_bus     = 8'h00;
    bit [7:0] usp_secondary_bus   = 8'h01;
    bit [7:0] usp_subordinate_bus = 8'h0F;

    //--- DSP config arrays ---
    bit [7:0]  ds_secondary_bus[];
    bit [7:0]  ds_subordinate_bus[];
    bit [31:0] ds_mem_base[];
    bit [31:0] ds_mem_limit[];

    //--- Per-port FC credits ---
    int port_ph_credit   = 32;
    int port_pd_credit   = 256;
    int port_nph_credit  = 32;
    int port_npd_credit  = 256;
    int port_cplh_credit = 32;
    int port_cpld_credit = 256;

    //--- Per-port link delay ---
    bit port_link_delay_enable = 0;
    int port_latency_min_ns    = 0;
    int port_latency_max_ns    = 0;

    function new(string name = "pcie_tl_switch_config");
        super.new(name);
    endfunction

    function void init_defaults();
        ds_secondary_bus   = new[num_ds_ports];
        ds_subordinate_bus = new[num_ds_ports];
        ds_mem_base        = new[num_ds_ports];
        ds_mem_limit       = new[num_ds_ports];

        for (int i = 0; i < num_ds_ports; i++) begin
            ds_secondary_bus[i]   = usp_secondary_bus + 1 + i;
            ds_subordinate_bus[i] = ds_secondary_bus[i];
            ds_mem_base[i]  = 32'h8000_0000 + (i * 32'h1000_0000);
            ds_mem_limit[i] = ds_mem_base[i] + 32'h0FFF_FFFF;
        end
        usp_subordinate_bus = ds_subordinate_bus[num_ds_ports - 1];
    endfunction

endclass
