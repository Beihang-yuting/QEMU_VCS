//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Top-Level
//-----------------------------------------------------------------------------

class pcie_tl_switch extends uvm_component;
    `uvm_component_utils(pcie_tl_switch)

    //--- Configuration ---
    pcie_tl_switch_config  sw_cfg;

    //--- Ports ---
    pcie_tl_switch_port    usp;
    pcie_tl_switch_port    dsp[];

    //--- All ports flat array for fabric ---
    pcie_tl_switch_port    all_ports[];

    //--- Routing Fabric ---
    pcie_tl_switch_fabric  fabric;

    //--- Statistics ---
    int total_routed   = 0;
    int total_dropped  = 0;
    int total_p2p      = 0;
    int total_bcast    = 0;

    function new(string name = "pcie_tl_switch", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        int n;
        super.build_phase(phase);

        if (sw_cfg == null)
            `uvm_fatal("SWITCH", "sw_cfg is null")

        n = sw_cfg.num_ds_ports;

        usp = pcie_tl_switch_port::type_id::create("usp", this);
        usp.role    = SWITCH_USP;
        usp.port_id = 0;

        dsp = new[n];
        for (int i = 0; i < n; i++) begin
            dsp[i] = pcie_tl_switch_port::type_id::create($sformatf("dsp_%0d", i), this);
            dsp[i].role    = SWITCH_DSP;
            dsp[i].port_id = i + 1;
        end

        all_ports = new[n + 1];
        all_ports[0] = usp;
        for (int i = 0; i < n; i++)
            all_ports[i + 1] = dsp[i];

        fabric = pcie_tl_switch_fabric::type_id::create("fabric");
        fabric.ports      = all_ports;
        fabric.num_ports  = n + 1;
        fabric.p2p_enable = sw_cfg.p2p_enable;
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!sw_cfg.enum_mode) begin
            usp.apply_config(sw_cfg, 0);
            for (int i = 0; i < sw_cfg.num_ds_ports; i++)
                dsp[i].apply_config(sw_cfg, i);
        end
    endfunction

    task run_phase(uvm_phase phase);
        fork
            usp_forward_loop();
            for (int i = 0; i < sw_cfg.num_ds_ports; i++) begin
                automatic int idx = i;
                fork
                    dsp_forward_loop(idx);
                join_none
            end
        join_none
    endtask

    protected task usp_forward_loop();
        pcie_tl_tlp tlp;
        forever begin
            usp.rx_fifo.get(tlp);
            route_and_forward(tlp, 0);
        end
    endtask

    protected task dsp_forward_loop(int port_idx);
        pcie_tl_tlp tlp;
        forever begin
            dsp[port_idx].rx_fifo.get(tlp);
            route_and_forward(tlp, port_idx + 1);
        end
    endtask

    protected task route_and_forward(pcie_tl_tlp tlp, int ingress_port_id);
        int dst;

        // Skip null or empty TLPs (from monitor polling or uninitialized objects)
        if (tlp == null || (tlp.length == 0 && tlp.payload.size() == 0 &&
            tlp.kind == TLP_MEM_RD && tlp.requester_id == 0))
            return;

        dst = fabric.route(tlp, ingress_port_id);

        // If routed back to ingress, redirect: DSP self-route → USP, USP self-route → drop
        if (dst == ingress_port_id) begin
            if (ingress_port_id > 0)
                dst = SWITCH_ROUTE_USP;  // DSP→self: send upstream
            else
                dst = SWITCH_ROUTE_DROP; // USP→self: nowhere to go
        end

        case (dst)
            SWITCH_ROUTE_LOCAL: begin
                handle_local_config(tlp, ingress_port_id);
            end
            SWITCH_ROUTE_DROP: begin
                total_dropped++;
                all_ports[ingress_port_id].dropped_count++;
                `uvm_info("SWITCH", $sformatf("DROPPED from port %0d: %s",
                    ingress_port_id, tlp.convert2string()), UVM_MEDIUM)
            end
            SWITCH_ROUTE_BCAST: begin
                total_bcast++;
                for (int i = 1; i <= sw_cfg.num_ds_ports; i++) begin
                    if (i != ingress_port_id) begin
                        all_ports[i].tx_fifo.put(tlp);
                        all_ports[i].forwarded_count++;
                    end
                end
            end
            default: begin
                if (dst >= 0 && dst < all_ports.size()) begin
                    all_ports[dst].tx_fifo.put(tlp);
                    all_ports[dst].forwarded_count++;
                    total_routed++;
                    if (ingress_port_id > 0 && dst > 0)
                        total_p2p++;
                end else begin
                    total_dropped++;
                    `uvm_warning("SWITCH", $sformatf("Bad route dst=%0d from port %0d",
                        dst, ingress_port_id))
                end
            end
        endcase
    endtask

    protected task handle_local_config(pcie_tl_tlp tlp, int ingress_port_id);
        pcie_tl_cfg_tlp cfg_tlp;
        pcie_tl_cpl_tlp cpl;

        if (!$cast(cfg_tlp, tlp)) return;

        begin
            int dev_num = cfg_tlp.completer_id[7:3];
            int target_port = (dev_num < all_ports.size()) ? dev_num : 0;

            if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
                bit [31:0] data = all_ports[target_port].cfg_read({cfg_tlp.reg_num, 2'b00});
                cpl = pcie_tl_cpl_tlp::type_id::create("sw_cfg_cpl");
                cpl.kind         = TLP_CPLD;
                cpl.fmt          = FMT_3DW_WITH_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.tc           = tlp.tc;
                cpl.attr         = tlp.attr;
                cpl.length       = 1;
                cpl.requester_id = tlp.requester_id;
                cpl.tag          = tlp.tag;
                cpl.completer_id = sw_cfg.switch_bdf;
                cpl.cpl_status   = CPL_STATUS_SC;
                cpl.byte_count   = 4;
                cpl.lower_addr   = {cfg_tlp.reg_num[0], 2'b00};
                cpl.payload      = new[4];
                cpl.payload[0]   = data[7:0];
                cpl.payload[1]   = data[15:8];
                cpl.payload[2]   = data[23:16];
                cpl.payload[3]   = data[31:24];
                all_ports[ingress_port_id].tx_fifo.put(cpl);
            end else begin
                bit [31:0] data = 0;
                if (tlp.payload.size() >= 4)
                    data = {tlp.payload[3], tlp.payload[2], tlp.payload[1], tlp.payload[0]};
                all_ports[target_port].cfg_write({cfg_tlp.reg_num, 2'b00}, data, cfg_tlp.first_be);
                cpl = pcie_tl_cpl_tlp::type_id::create("sw_cfg_cpl");
                cpl.kind         = TLP_CPL;
                cpl.fmt          = FMT_3DW_NO_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.tc           = tlp.tc;
                cpl.attr         = tlp.attr;
                cpl.length       = 0;
                cpl.requester_id = tlp.requester_id;
                cpl.tag          = tlp.tag;
                cpl.completer_id = sw_cfg.switch_bdf;
                cpl.cpl_status   = CPL_STATUS_SC;
                cpl.byte_count   = 0;
                cpl.lower_addr   = 0;
                all_ports[ingress_port_id].tx_fifo.put(cpl);
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("SWITCH", $sformatf(
            "\n============ Switch Report ============\n  Ports: 1 USP + %0d DSP\n  Total routed:  %0d\n  Total P2P:     %0d\n  Total bcast:   %0d\n  Total dropped: %0d\n=======================================",
            sw_cfg.num_ds_ports, total_routed, total_p2p, total_bcast, total_dropped), UVM_LOW)
    endfunction

endclass
