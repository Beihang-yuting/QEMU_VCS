//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Port (USP/DSP)
//-----------------------------------------------------------------------------

class pcie_tl_switch_port extends uvm_component;
    `uvm_component_utils(pcie_tl_switch_port)

    switch_port_role_e  role;
    int                 port_id;

    uvm_tlm_fifo #(pcie_tl_tlp) rx_fifo;
    uvm_tlm_fifo #(pcie_tl_tlp) tx_fifo;

    switch_route_entry_t route_entry;

    pcie_tl_fc_manager fc_mgr;

    pcie_tl_link_delay_model ingress_delay;
    pcie_tl_link_delay_model egress_delay;

    int forwarded_count = 0;
    int dropped_count   = 0;

    function new(string name = "pcie_tl_switch_port", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        rx_fifo       = new("rx_fifo", this, 256);
        tx_fifo       = new("tx_fifo", this, 256);
        fc_mgr        = pcie_tl_fc_manager::type_id::create($sformatf("fc_mgr_p%0d", port_id));
        ingress_delay = pcie_tl_link_delay_model::type_id::create(
                            $sformatf("ingress_delay_p%0d", port_id), this);
        egress_delay  = pcie_tl_link_delay_model::type_id::create(
                            $sformatf("egress_delay_p%0d", port_id), this);
    endfunction

    function void apply_config(pcie_tl_switch_config sw_cfg, int idx);
        if (role == SWITCH_USP) begin
            route_entry.primary_bus     = sw_cfg.usp_primary_bus;
            route_entry.secondary_bus   = sw_cfg.usp_secondary_bus;
            route_entry.subordinate_bus = sw_cfg.usp_subordinate_bus;
            route_entry.mem_base  = 0;
            route_entry.mem_limit = 0;
        end else begin
            route_entry.primary_bus     = sw_cfg.usp_secondary_bus;
            route_entry.secondary_bus   = sw_cfg.ds_secondary_bus[idx];
            route_entry.subordinate_bus = sw_cfg.ds_subordinate_bus[idx];
            route_entry.mem_base        = sw_cfg.ds_mem_base[idx];
            route_entry.mem_limit       = sw_cfg.ds_mem_limit[idx];
        end

        fc_mgr.fc_enable       = 1;
        fc_mgr.infinite_credit = 0;
        fc_mgr.init_credits(sw_cfg.port_ph_credit, sw_cfg.port_pd_credit,
                            sw_cfg.port_nph_credit, sw_cfg.port_npd_credit,
                            sw_cfg.port_cplh_credit, sw_cfg.port_cpld_credit);

        ingress_delay.enable         = sw_cfg.port_link_delay_enable;
        ingress_delay.latency_min_ns = sw_cfg.port_latency_min_ns;
        ingress_delay.latency_max_ns = sw_cfg.port_latency_max_ns;
        egress_delay.enable          = sw_cfg.port_link_delay_enable;
        egress_delay.latency_min_ns  = sw_cfg.port_latency_min_ns;
        egress_delay.latency_max_ns  = sw_cfg.port_latency_max_ns;
    endfunction

    function bit [31:0] cfg_read(bit [11:0] addr);
        case (addr)
            12'h018: return {route_entry.subordinate_bus,
                             route_entry.secondary_bus,
                             route_entry.primary_bus, 8'h0};
            12'h020: return {route_entry.mem_limit[31:20], 4'h0,
                             route_entry.mem_base[31:20], 4'h0};
            default: return 32'h0;
        endcase
    endfunction

    function void cfg_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        case (addr)
            12'h018: begin
                if (be[1]) route_entry.primary_bus     = data[15:8];
                if (be[2]) route_entry.secondary_bus   = data[23:16];
                if (be[3]) route_entry.subordinate_bus = data[31:24];
            end
            12'h020: begin
                if (be[0] || be[1]) route_entry.mem_base[31:20]  = data[15:4];
                if (be[2] || be[3]) route_entry.mem_limit[31:20] = data[31:20];
            end
        endcase
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info(get_name(), $sformatf(
            "\n===== Switch Port %0d (%s) =====\n  Bus: pri=%0d sec=%0d sub=%0d\n  Mem: [0x%08h - 0x%08h]\n  Forwarded: %0d  Dropped: %0d\n================================",
            port_id, role.name(),
            route_entry.primary_bus, route_entry.secondary_bus, route_entry.subordinate_bus,
            route_entry.mem_base, route_entry.mem_limit,
            forwarded_count, dropped_count), UVM_LOW)
    endfunction

endclass
