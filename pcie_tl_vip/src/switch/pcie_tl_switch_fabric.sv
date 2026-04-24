//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Switch Routing Fabric
//-----------------------------------------------------------------------------

class pcie_tl_switch_fabric extends uvm_object;
    `uvm_object_utils(pcie_tl_switch_fabric)

    //--- Port references (set by pcie_tl_switch) ---
    pcie_tl_switch_port ports[];   // [0]=USP, [1..N]=DSP
    int num_ports;                 // 1 + num_ds_ports

    //--- Config ---
    bit p2p_enable = 1;

    function new(string name = "pcie_tl_switch_fabric");
        super.new(name);
    endfunction

    //=========================================================================
    // Main routing function: returns egress port_id
    // Returns: 0=USP, 1..N=DSP, or SWITCH_ROUTE_LOCAL/DROP/BCAST
    //=========================================================================
    function int route(pcie_tl_tlp tlp, int ingress_port_id);
        // 1. Completion routing (ID-based)
        if (tlp.get_category() == TLP_CAT_COMPLETION) begin
            pcie_tl_cpl_tlp cpl;
            if ($cast(cpl, tlp))
                return route_by_id(cpl.requester_id[15:8], ingress_port_id);
        end

        // 2. Config routing (ID-based)
        if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1}) begin
            pcie_tl_cfg_tlp cfg_tlp;
            if ($cast(cfg_tlp, tlp)) begin
                bit [7:0] target_bus = cfg_tlp.completer_id[15:8];
                // Check if targeting the switch itself
                if (target_bus == ports[0].route_entry.secondary_bus)
                    return SWITCH_ROUTE_LOCAL;
                return route_by_id(target_bus, ingress_port_id);
            end
        end

        // 3. Memory/IO routing (address-based)
        if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                             TLP_IO_RD, TLP_IO_WR}) begin
            pcie_tl_mem_tlp mem_tlp;
            pcie_tl_io_tlp  io_tlp;
            bit [63:0] addr;

            if ($cast(mem_tlp, tlp))
                addr = mem_tlp.addr;
            else if ($cast(io_tlp, tlp))
                addr = {32'h0, io_tlp.addr};
            else
                addr = 0;

            return route_by_address(addr, ingress_port_id);
        end

        // 4. Message routing (implicit)
        if (tlp.kind inside {TLP_MSG, TLP_MSGD}) begin
            return route_message(tlp, ingress_port_id);
        end

        // 5. Default: upstream if from DSP, drop if from USP
        if (ingress_port_id > 0)
            return SWITCH_ROUTE_USP;
        return SWITCH_ROUTE_DROP;
    endfunction

    //=========================================================================
    // ID-based routing: find port whose secondary-subordinate range contains bus
    //=========================================================================
    protected function int route_by_id(bit [7:0] target_bus, int ingress_port_id);
        for (int i = 1; i < num_ports; i++) begin
            if (target_bus >= ports[i].route_entry.secondary_bus &&
                target_bus <= ports[i].route_entry.subordinate_bus) begin
                if (ingress_port_id > 0 && i != ingress_port_id && !p2p_enable)
                    return SWITCH_ROUTE_USP;
                return i;
            end
        end
        if (ingress_port_id > 0)
            return SWITCH_ROUTE_USP;
        return SWITCH_ROUTE_DROP;
    endfunction

    //=========================================================================
    // Address-based routing: find port whose memory window contains addr
    //=========================================================================
    protected function int route_by_address(bit [63:0] addr, int ingress_port_id);
        for (int i = 1; i < num_ports; i++) begin
            if (addr >= {32'h0, ports[i].route_entry.mem_base} &&
                addr <= {32'h0, ports[i].route_entry.mem_limit}) begin
                if (ingress_port_id > 0 && i != ingress_port_id && !p2p_enable)
                    return SWITCH_ROUTE_USP;
                return i;
            end
        end
        if (ingress_port_id > 0)
            return SWITCH_ROUTE_USP;
        return SWITCH_ROUTE_DROP;
    endfunction

    //=========================================================================
    // Message routing
    //=========================================================================
    protected function int route_message(pcie_tl_tlp tlp, int ingress_port_id);
        case (tlp.type_f)
            TLP_TYPE_MSG_BCAST:  return SWITCH_ROUTE_BCAST;
            TLP_TYPE_MSG_LOCAL:  return SWITCH_ROUTE_LOCAL;
            TLP_TYPE_MSG_RC:     return SWITCH_ROUTE_USP;
            TLP_TYPE_MSG_ADDR: begin
                pcie_tl_msg_tlp msg;
                if ($cast(msg, tlp))
                    return route_by_address(msg.msg_addr, ingress_port_id);
            end
            TLP_TYPE_MSG_ID: begin
                pcie_tl_msg_tlp msg;
                if ($cast(msg, tlp))
                    return route_by_id(msg.target_id[15:8], ingress_port_id);
            end
            default: begin
                if (ingress_port_id > 0) return SWITCH_ROUTE_USP;
                return SWITCH_ROUTE_BCAST;
            end
        endcase
        return SWITCH_ROUTE_USP;
    endfunction

endclass
