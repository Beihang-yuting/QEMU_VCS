/* cosim-platform/vcs-tb/cosim_rc_driver.sv
 * Core adaptation layer: replaces sequencer-driven run_phase with a DPI-C
 * polling loop.  Extends pcie_tl_rc_driver so the full VIP pipeline
 * (FC → ordering → tag → codec → adapter) is reused as-is.
 */

`ifndef COSIM_RC_DRIVER_SV
`define COSIM_RC_DRIVER_SV

class cosim_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(cosim_rc_driver)

    // -----------------------------------------------------------------------
    // DPI-C imports are provided by cosim_bridge_pkg (imported by cosim_pkg)
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // DPI-C TLP type constants (kept in sync with bridge_vcs.sv)
    // -----------------------------------------------------------------------
    localparam byte unsigned BV_TLP_MWR    = 8'd0;
    localparam byte unsigned BV_TLP_MRD    = 8'd1;
    localparam byte unsigned BV_TLP_CFGWR0 = 8'd2;
    localparam byte unsigned BV_TLP_CFGRD0 = 8'd3;
    localparam byte unsigned BV_TLP_CPL    = 8'd4;
`ifdef COSIM_VIP_MODE
    localparam byte unsigned BV_TLP_CFGWR1          = 8'd5;
    localparam byte unsigned BV_TLP_CFGRD1          = 8'd6;
    localparam byte unsigned BV_TLP_IORD            = 8'd7;
    localparam byte unsigned BV_TLP_IOWR            = 8'd8;
    localparam byte unsigned BV_TLP_CPLD            = 8'd9;
    localparam byte unsigned BV_TLP_MSG             = 8'd10;
    localparam byte unsigned BV_TLP_ATOMIC_FETCHADD = 8'd11;
    localparam byte unsigned BV_TLP_ATOMIC_SWAP     = 8'd12;
    localparam byte unsigned BV_TLP_ATOMIC_CAS      = 8'd13;
    localparam byte unsigned BV_TLP_VENDOR_MSG      = 8'd14;
    localparam byte unsigned BV_TLP_LTR             = 8'd15;
    localparam byte unsigned BV_TLP_MRD_LK          = 8'd16;
`endif

    // -----------------------------------------------------------------------
    // Tag mapping: QEMU uses 8-bit tags, VIP uses 10-bit tags
    // -----------------------------------------------------------------------
    // vip_tag → qemu_tag  (populated after send_tlp allocates a VIP tag)
    bit [7:0]  vip_tag_to_qemu_tag[int];
    // qemu_tag → vip_tag  (reverse lookup for completion forwarding)
    int        qemu_tag_to_vip_tag[bit [7:0]];

    // -----------------------------------------------------------------------
    // DPI-C scratch arrays — must be class members (static storage) because
    // VCS Q-2020 segfaults when passing automatic-local arrays to DPI-C.
    // -----------------------------------------------------------------------
    byte unsigned    dpi_type;
    longint unsigned dpi_addr;
    int unsigned     dpi_data[16];
    int              dpi_len;
    int              dpi_tag;
    int unsigned     cpl_data_buf[16];

    // -----------------------------------------------------------------------
    // Statistics counters
    // -----------------------------------------------------------------------
    int unsigned total_tlp_count;
    int unsigned total_cpl_count;
    int unsigned unknown_type_count;
    int unsigned tlp_type_count[string];
    int unsigned tlp_type_errors[string];

    // -----------------------------------------------------------------------
    // Shutdown coordination
    // -----------------------------------------------------------------------
    event shutdown_event;

    // -----------------------------------------------------------------------
    // Bridge ready flag — set by cosim_test after bridge_vcs_init succeeds
    // -----------------------------------------------------------------------
    bit bridge_ready = 0;

    // -----------------------------------------------------------------------
    // Polling interval (time between empty polls)
    // -----------------------------------------------------------------------
    int polling_interval_ns = 10;

    // -----------------------------------------------------------------------
    // Completion VIP interface (obtained from config_db)
    // Carries CplD TLPs from glue → driver in 256-bit bus format
    // -----------------------------------------------------------------------
    virtual pcie_tl_if cpl_vif;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    function new(string name = "cosim_rc_driver", uvm_component parent = null);
        super.new(name, parent);
        total_tlp_count    = 0;
        total_cpl_count    = 0;
        unknown_type_count = 0;
    endfunction

    // -----------------------------------------------------------------------
    // build_phase: grab the stub completion interface from config_db
    // -----------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual pcie_tl_if)::get(
                this, "", "cpl_vif", cpl_vif))
            `uvm_fatal(get_name(),
                "Failed to get 'cpl_vif' from config_db. "
                + "Ensure cosim_vip_top sets it.")
    endfunction

    // -----------------------------------------------------------------------
    // run_phase: fork three independent loops; NO super.run_phase call
    // -----------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "cosim_rc_driver running");

        `uvm_info(get_name(), "cosim_rc_driver run_phase started (DPI-C polling mode)",
                  UVM_MEDIUM)

        fork
            request_loop(phase);
            completion_loop(phase);
            dma_msi_loop(phase);
        join

        phase.drop_objection(this, "cosim_rc_driver done");
    endtask

    // -----------------------------------------------------------------------
    // request_loop
    //   Polls bridge_vcs_poll_tlp, builds a VIP TLP object and calls
    //   send_tlp() which traverses the full VIP pipeline.
    // -----------------------------------------------------------------------
    protected task request_loop(uvm_phase phase);
        int              ret;
        pcie_tl_tlp      vip_tlp;

`ifdef COSIM_VIP_MODE
        byte unsigned    ext_msg_code;
        byte unsigned    ext_atomic_op_size;
        shortint unsigned ext_vendor_id;
        byte unsigned    ext_first_be;
        byte unsigned    ext_last_be;
`endif

        /* Wait for bridge initialization before polling */
        wait (bridge_ready);
        `uvm_info(get_name(), "Bridge ready, starting TLP polling", UVM_MEDIUM)

        forever begin
            /* Fully-scalar DPI — VCS Q-2020 segfaults on output params
               from package/class scope. Use getters instead. */
            ret = bridge_vcs_poll_tlp_scalar();
            if (ret < 0) begin
                `uvm_info(get_name(), "bridge_vcs_poll_tlp returned < 0: initiating shutdown",
                          UVM_MEDIUM)
                ->shutdown_event;
                break;
            end

            if (ret > 0) begin
                // No TLP available yet; wait one polling interval
                #(polling_interval_ns * 1ns);
                continue;
            end

            // ret == 0: TLP received — fetch all fields from C-side getters
            dpi_type = bridge_vcs_get_poll_type();
            dpi_addr = bridge_vcs_get_poll_addr();
            dpi_len  = bridge_vcs_get_poll_len();
            dpi_tag  = bridge_vcs_get_poll_tag();
            for (int i = 0; i < 16; i++)
                dpi_data[i] = bridge_vcs_get_poll_data(i);

`ifdef COSIM_VIP_MODE
            // Extended fields — defaults for P1, P2+ scope
            ext_msg_code       = 0;
            ext_atomic_op_size = 0;
            ext_vendor_id      = 0;
            ext_first_be       = 8'hF;
            ext_last_be        = 8'hF;
`endif

`ifdef COSIM_VIP_MODE
            vip_tlp = build_vip_tlp(dpi_type, dpi_addr, dpi_data, dpi_len,
                                     dpi_tag, ext_msg_code, ext_atomic_op_size,
                                     ext_vendor_id, ext_first_be, ext_last_be);
`else
            vip_tlp = build_vip_tlp(dpi_type, dpi_addr, dpi_data, dpi_len,
                                     dpi_tag, 8'h00, 8'h00, 16'h0000, 4'hF, 4'hF);
`endif

            if (vip_tlp == null) begin
                unknown_type_count++;
                `uvm_warning(get_name(),
                    $sformatf("Unknown DPI-C TLP type 0x%02h, discarding", dpi_type))
                continue;
            end

            begin
                bit [7:0] qemu_tag_8 = dpi_tag[7:0];

                // send_tlp allocates the VIP tag internally via tag_mgr.alloc_tag
                send_tlp(vip_tlp);
                /* Ensure at least 2 clock edges pass so glue can sample
                   the TLP beat (avoids delta-cycle race when send_tlp
                   returns on the same posedge it drives valid). */
                repeat (2) @(posedge vif.clk);

                // After send_tlp, vip_tlp.tag holds the VIP-assigned tag
                if (vip_tlp.requires_completion()) begin
                    vip_tag_to_qemu_tag[int'(vip_tlp.tag)] = qemu_tag_8;
                    qemu_tag_to_vip_tag[qemu_tag_8]         = int'(vip_tlp.tag);
                end
            end

            total_tlp_count++;
            begin
                string type_name = $sformatf("type_%0d", dpi_type);
                if (!tlp_type_count.exists(type_name))
                    tlp_type_count[type_name] = 0;
                tlp_type_count[type_name]++;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // completion_loop
    //   Monitors completion pcie_tl_if (cpl_vif) for CplD TLPs from glue.
    //   Parses the 256-bit bus beat, builds a pcie_tl_cpl_tlp, calls the
    //   base handle_completion() for proper VIP tag management, then
    //   forwards the completion to QEMU via DPI-C.
    //
    //   256-bit CplD beat layout (from glue_if_to_stub build_cpld_beat):
    //     bytes[0]  = {Fmt=010, Type=01010} = 0x4A
    //     bytes[6]  = {Status[2:0], BCM, ByteCount[11:8]}
    //     bytes[7]  = ByteCount[7:0]
    //     bytes[10] = Tag[7:0]
    //     bytes[12..15] = Data (PCIe big-endian)
    // -----------------------------------------------------------------------
    protected task completion_loop(uvm_phase phase);
        int          qemu_tag;
        int          vip_tag_int;
        int          ret;
        logic [255:0] beat;
        logic [7:0]  cpl_tag_raw;
        logic [2:0]  cpl_status_bits;
        logic [31:0] cpl_rdata;

        forever begin
            @(posedge cpl_vif.clk);
            if (!cpl_vif.tlp_valid || !cpl_vif.tlp_sop)
                continue;

            // Capture the 256-bit beat
            beat = cpl_vif.tlp_data;

            // Parse CplD fields from bus encoding
            // bytes[10] = data[87:80] = Tag
            cpl_tag_raw = beat[87:80];
            // bytes[6] = data[55:48] = {Status[2:0], BCM, ByteCount[11:8]}
            cpl_status_bits = beat[55:53];
            // bytes[12..15] = data[103:96], [111:104], [119:112], [127:120] = Data (big-endian)
            cpl_rdata = {beat[103:96], beat[111:104], beat[119:112], beat[127:120]};

            vip_tag_int = int'(cpl_tag_raw);

            // Build VIP completion object and call handle_completion()
            begin
                pcie_tl_cpl_tlp cpl_tlp;
                cpl_tlp = pcie_tl_cpl_tlp::type_id::create("rx_cpl");
                cpl_tlp.kind        = TLP_CPLD;
                cpl_tlp.fmt         = FMT_3DW_WITH_DATA;
                cpl_tlp.type_f      = TLP_TYPE_CPL;
                cpl_tlp.tag         = 10'(cpl_tag_raw);
                cpl_tlp.completer_id = 16'h0100;
                cpl_tlp.requester_id = 16'h0000;
                cpl_tlp.cpl_status  = (cpl_status_bits == 3'b000) ? CPL_STATUS_SC : CPL_STATUS_UR;
                cpl_tlp.byte_count  = 4;
                cpl_tlp.lower_addr  = 7'h0;
                cpl_tlp.length      = 1;
                cpl_tlp.payload     = new[4];
                cpl_tlp.payload[0]  = cpl_rdata[31:24];
                cpl_tlp.payload[1]  = cpl_rdata[23:16];
                cpl_tlp.payload[2]  = cpl_rdata[15:8];
                cpl_tlp.payload[3]  = cpl_rdata[7:0];

                // VIP tag management: match & free tag via base class
                void'(handle_completion(cpl_tlp));
            end

            // Translate VIP tag back to QEMU tag
            if (!vip_tag_to_qemu_tag.exists(vip_tag_int)) begin
                `uvm_warning(get_name(),
                    $sformatf("completion_loop: no QEMU tag mapping for VIP tag=0x%03h",
                              cpl_tag_raw))
                continue;
            end
            qemu_tag = int'(vip_tag_to_qemu_tag[vip_tag_int]);

            // Clean up maps
            vip_tag_to_qemu_tag.delete(vip_tag_int);
            qemu_tag_to_vip_tag.delete(qemu_tag[7:0]);

            // Forward completion to QEMU via DPI-C
            for (int i = 0; i < 16; i++)
                bridge_vcs_set_cpl_data(i, 0);
            // Pack data in little-endian word format for QEMU
            bridge_vcs_set_cpl_data(0, cpl_rdata);

            ret = bridge_vcs_send_cpl_scalar(qemu_tag, 1);
            if (ret != 0)
                `uvm_error(get_name(),
                    $sformatf("bridge_vcs_send_completion failed: ret=%0d qemu_tag=0x%02h",
                              ret, qemu_tag))

            total_cpl_count++;

            `uvm_info(get_name(),
                $sformatf("Completion via VIP: vip_tag=0x%03h qemu_tag=0x%02h status=%s data=0x%08h",
                          cpl_tag_raw, qemu_tag,
                          (cpl_status_bits == 3'b000) ? "SC" : "UR", cpl_rdata),
                UVM_HIGH)
        end
    endtask

    // -----------------------------------------------------------------------
    // dma_msi_loop
    //   Placeholder for DMA-initiated requests and MSI handling.
    //   Exits cleanly when shutdown_event fires.
    // -----------------------------------------------------------------------
    protected task dma_msi_loop(uvm_phase phase);
        @(shutdown_event);
        `uvm_info(get_name(), "dma_msi_loop: shutdown received, exiting", UVM_MEDIUM)
    endtask

    // -----------------------------------------------------------------------
    // build_vip_tlp
    //   Maps a DPI-C numeric TLP type (0–16) plus raw fields to the
    //   appropriate VIP TLP subclass.  Types 0–4 are always compiled;
    //   types 5–16 require COSIM_VIP_MODE.
    // -----------------------------------------------------------------------
    protected function pcie_tl_tlp build_vip_tlp(
        input byte unsigned    dpi_type,
        input longint unsigned dpi_addr,
        input int unsigned     dpi_data[16],
        input int              dpi_len,
        input int              dpi_tag,
        input byte unsigned    msg_code_val,
        input byte unsigned    atomic_op_size_val,
        input shortint unsigned vendor_id_val,
        input byte unsigned    first_be_val,
        input byte unsigned    last_be_val
    );
        pcie_tl_tlp       tlp     = null;
        pcie_tl_mem_tlp   mem_tlp;
        pcie_tl_cfg_tlp   cfg_tlp;
        pcie_tl_cpl_tlp   cpl_out;
        int               payload_bytes;

        case (dpi_type)
            // ------------------------------------------------------------------
            // 0: Memory Write (MWr)
            // ------------------------------------------------------------------
            BV_TLP_MWR: begin
                mem_tlp = pcie_tl_mem_tlp::type_id::create("mem_wr_tlp");
                mem_tlp.kind      = TLP_MEM_WR;
                mem_tlp.addr      = dpi_addr;
                mem_tlp.is_64bit  = (dpi_addr[63:32] != 0);
                mem_tlp.fmt       = mem_tlp.is_64bit ? FMT_4DW_WITH_DATA
                                                     : FMT_3DW_WITH_DATA;
                mem_tlp.type_f    = TLP_TYPE_MEM_RD;  // MEM_WR alias shares encoding
                mem_tlp.first_be  = first_be_val[3:0];
                mem_tlp.last_be   = last_be_val[3:0];
                payload_bytes     = (dpi_len > 0) ? dpi_len : 4;
                mem_tlp.length    = (payload_bytes + 3) / 4;
                unpack_dpi_to_payload(dpi_data, payload_bytes, mem_tlp.payload);
                tlp = mem_tlp;
            end

            // ------------------------------------------------------------------
            // 1: Memory Read (MRd)
            // ------------------------------------------------------------------
            BV_TLP_MRD: begin
                mem_tlp = pcie_tl_mem_tlp::type_id::create("mem_rd_tlp");
                mem_tlp.kind      = TLP_MEM_RD;
                mem_tlp.addr      = dpi_addr;
                mem_tlp.is_64bit  = (dpi_addr[63:32] != 0);
                mem_tlp.fmt       = mem_tlp.is_64bit ? FMT_4DW_NO_DATA
                                                     : FMT_3DW_NO_DATA;
                mem_tlp.type_f    = TLP_TYPE_MEM_RD;
                mem_tlp.first_be  = first_be_val[3:0];
                mem_tlp.last_be   = last_be_val[3:0];
                mem_tlp.length    = (dpi_len > 0) ? (dpi_len + 3) / 4 : 1;
                mem_tlp.tag       = 10'(dpi_tag[7:0]);
                tlp = mem_tlp;
            end

            // ------------------------------------------------------------------
            // 2: Config Write Type 0 (CfgWr0)
            // ------------------------------------------------------------------
            BV_TLP_CFGWR0: begin
                cfg_tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr0_tlp");
                cfg_tlp.kind      = TLP_CFG_WR0;
                cfg_tlp.fmt       = FMT_3DW_WITH_DATA;
                cfg_tlp.type_f    = TLP_TYPE_CFG_RD0;  // CFG_WR0 alias
                cfg_tlp.reg_num   = dpi_addr[11:2];
                cfg_tlp.first_be  = first_be_val[3:0];
                cfg_tlp.length    = 1;
                unpack_dpi_to_payload(dpi_data, 4, cfg_tlp.payload);
                tlp = cfg_tlp;
            end

            // ------------------------------------------------------------------
            // 3: Config Read Type 0 (CfgRd0)
            // ------------------------------------------------------------------
            BV_TLP_CFGRD0: begin
                cfg_tlp = pcie_tl_cfg_tlp::type_id::create("cfg_rd0_tlp");
                cfg_tlp.kind      = TLP_CFG_RD0;
                cfg_tlp.fmt       = FMT_3DW_NO_DATA;
                cfg_tlp.type_f    = TLP_TYPE_CFG_RD0;
                cfg_tlp.reg_num   = dpi_addr[11:2];
                cfg_tlp.first_be  = first_be_val[3:0];
                cfg_tlp.length    = 1;
                cfg_tlp.tag       = 10'(dpi_tag[7:0]);
                tlp = cfg_tlp;
            end

            // ------------------------------------------------------------------
            // 4: Completion without data (Cpl)
            // ------------------------------------------------------------------
            BV_TLP_CPL: begin
                cpl_out = pcie_tl_cpl_tlp::type_id::create("cpl_tlp");
                cpl_out.kind        = TLP_CPL;
                cpl_out.fmt         = FMT_3DW_NO_DATA;
                cpl_out.type_f      = TLP_TYPE_CPL;
                cpl_out.cpl_status  = CPL_STATUS_SC;
                cpl_out.byte_count  = 4;
                cpl_out.tag         = 10'(dpi_tag[7:0]);
                tlp = cpl_out;
            end

`ifdef COSIM_VIP_MODE
            // ------------------------------------------------------------------
            // 5: Config Write Type 1 (CfgWr1)
            // ------------------------------------------------------------------
            BV_TLP_CFGWR1: begin
                cfg_tlp = pcie_tl_cfg_tlp::type_id::create("cfg_wr1_tlp");
                cfg_tlp.kind      = TLP_CFG_WR1;
                cfg_tlp.fmt       = FMT_3DW_WITH_DATA;
                cfg_tlp.type_f    = TLP_TYPE_CFG_RD1;  // CFG_WR1 alias
                cfg_tlp.reg_num   = dpi_addr[11:2];
                cfg_tlp.first_be  = first_be_val[3:0];
                cfg_tlp.length    = 1;
                unpack_dpi_to_payload(dpi_data, 4, cfg_tlp.payload);
                tlp = cfg_tlp;
            end

            // ------------------------------------------------------------------
            // 6: Config Read Type 1 (CfgRd1)
            // ------------------------------------------------------------------
            BV_TLP_CFGRD1: begin
                cfg_tlp = pcie_tl_cfg_tlp::type_id::create("cfg_rd1_tlp");
                cfg_tlp.kind      = TLP_CFG_RD1;
                cfg_tlp.fmt       = FMT_3DW_NO_DATA;
                cfg_tlp.type_f    = TLP_TYPE_CFG_RD1;
                cfg_tlp.reg_num   = dpi_addr[11:2];
                cfg_tlp.first_be  = first_be_val[3:0];
                cfg_tlp.length    = 1;
                cfg_tlp.tag       = 10'(dpi_tag[7:0]);
                tlp = cfg_tlp;
            end

            // ------------------------------------------------------------------
            // 7: IO Read (IORd)
            // ------------------------------------------------------------------
            BV_TLP_IORD: begin
                pcie_tl_io_tlp io_tlp;
                io_tlp = pcie_tl_io_tlp::type_id::create("io_rd_tlp");
                io_tlp.kind      = TLP_IO_RD;
                io_tlp.fmt       = FMT_3DW_NO_DATA;
                io_tlp.type_f    = TLP_TYPE_IO_RD;
                io_tlp.addr      = dpi_addr[31:0];
                io_tlp.first_be  = first_be_val[3:0];
                io_tlp.length    = 1;
                io_tlp.tag       = 10'(dpi_tag[7:0]);
                tlp = io_tlp;
            end

            // ------------------------------------------------------------------
            // 8: IO Write (IOWr)
            // ------------------------------------------------------------------
            BV_TLP_IOWR: begin
                pcie_tl_io_tlp io_tlp;
                io_tlp = pcie_tl_io_tlp::type_id::create("io_wr_tlp");
                io_tlp.kind      = TLP_IO_WR;
                io_tlp.fmt       = FMT_3DW_WITH_DATA;
                io_tlp.type_f    = TLP_TYPE_IO_RD;  // IO_WR alias
                io_tlp.addr      = dpi_addr[31:0];
                io_tlp.first_be  = first_be_val[3:0];
                io_tlp.length    = 1;
                unpack_dpi_to_payload(dpi_data, 4, io_tlp.payload);
                tlp = io_tlp;
            end

            // ------------------------------------------------------------------
            // 9: Completion with data (CplD)
            // ------------------------------------------------------------------
            BV_TLP_CPLD: begin
                cpl_out = pcie_tl_cpl_tlp::type_id::create("cpld_tlp");
                cpl_out.kind        = TLP_CPLD;
                cpl_out.fmt         = FMT_3DW_WITH_DATA;
                cpl_out.type_f      = TLP_TYPE_CPL;
                cpl_out.cpl_status  = CPL_STATUS_SC;
                payload_bytes       = (dpi_len > 0) ? dpi_len : 4;
                cpl_out.byte_count  = payload_bytes;
                cpl_out.length      = (payload_bytes + 3) / 4;
                cpl_out.tag         = 10'(dpi_tag[7:0]);
                unpack_dpi_to_payload(dpi_data, payload_bytes, cpl_out.payload);
                tlp = cpl_out;
            end

            // ------------------------------------------------------------------
            // 10: Message TLP (Msg / MsgD)
            // ------------------------------------------------------------------
            BV_TLP_MSG: begin
                pcie_tl_msg_tlp msg_tlp;
                msg_tlp = pcie_tl_msg_tlp::type_id::create("msg_tlp");
                msg_tlp.kind     = (dpi_len > 0) ? TLP_MSGD : TLP_MSG;
                msg_tlp.fmt      = (dpi_len > 0) ? FMT_4DW_WITH_DATA
                                                  : FMT_4DW_NO_DATA;
                msg_tlp.type_f   = TLP_TYPE_MSG_RC;
                msg_tlp.msg_code = msg_code_e'(msg_code_val);
                if (dpi_len > 0) begin
                    msg_tlp.length = (dpi_len + 3) / 4;
                    unpack_dpi_to_payload(dpi_data, dpi_len, msg_tlp.payload);
                end
                tlp = msg_tlp;
            end

            // ------------------------------------------------------------------
            // 11: Atomic FetchAdd
            // ------------------------------------------------------------------
            BV_TLP_ATOMIC_FETCHADD: begin
                pcie_tl_atomic_tlp at_tlp;
                at_tlp = pcie_tl_atomic_tlp::type_id::create("atomic_fetchadd_tlp");
                at_tlp.kind      = TLP_ATOMIC_FETCHADD;
                at_tlp.addr      = dpi_addr;
                at_tlp.is_64bit  = (dpi_addr[63:32] != 0);
                at_tlp.fmt       = at_tlp.is_64bit ? FMT_4DW_WITH_DATA
                                                   : FMT_3DW_WITH_DATA;
                at_tlp.type_f    = TLP_TYPE_ATOMIC_FETCHADD;
                at_tlp.op_size   = (atomic_op_size_val == 8) ? ATOMIC_SIZE_64
                                                              : ATOMIC_SIZE_32;
                at_tlp.length    = (at_tlp.op_size == ATOMIC_SIZE_64) ? 2 : 1;
                at_tlp.tag       = 10'(dpi_tag[7:0]);
                unpack_dpi_to_payload(dpi_data, int'(atomic_op_size_val), at_tlp.payload);
                tlp = at_tlp;
            end

            // ------------------------------------------------------------------
            // 12: Atomic Swap
            // ------------------------------------------------------------------
            BV_TLP_ATOMIC_SWAP: begin
                pcie_tl_atomic_tlp at_tlp;
                at_tlp = pcie_tl_atomic_tlp::type_id::create("atomic_swap_tlp");
                at_tlp.kind      = TLP_ATOMIC_SWAP;
                at_tlp.addr      = dpi_addr;
                at_tlp.is_64bit  = (dpi_addr[63:32] != 0);
                at_tlp.fmt       = at_tlp.is_64bit ? FMT_4DW_WITH_DATA
                                                   : FMT_3DW_WITH_DATA;
                at_tlp.type_f    = TLP_TYPE_ATOMIC_SWAP;
                at_tlp.op_size   = (atomic_op_size_val == 8) ? ATOMIC_SIZE_64
                                                              : ATOMIC_SIZE_32;
                at_tlp.length    = (at_tlp.op_size == ATOMIC_SIZE_64) ? 2 : 1;
                at_tlp.tag       = 10'(dpi_tag[7:0]);
                unpack_dpi_to_payload(dpi_data, int'(atomic_op_size_val), at_tlp.payload);
                tlp = at_tlp;
            end

            // ------------------------------------------------------------------
            // 13: Atomic CAS
            // ------------------------------------------------------------------
            BV_TLP_ATOMIC_CAS: begin
                pcie_tl_atomic_tlp at_tlp;
                at_tlp = pcie_tl_atomic_tlp::type_id::create("atomic_cas_tlp");
                at_tlp.kind      = TLP_ATOMIC_CAS;
                at_tlp.addr      = dpi_addr;
                at_tlp.is_64bit  = (dpi_addr[63:32] != 0);
                at_tlp.fmt       = at_tlp.is_64bit ? FMT_4DW_WITH_DATA
                                                   : FMT_3DW_WITH_DATA;
                at_tlp.type_f    = TLP_TYPE_ATOMIC_CAS;
                at_tlp.op_size   = (atomic_op_size_val == 8) ? ATOMIC_SIZE_64
                                                              : ATOMIC_SIZE_32;
                // CAS carries compare + swap operands = 2 × op_size
                at_tlp.length    = (at_tlp.op_size == ATOMIC_SIZE_64) ? 4 : 2;
                at_tlp.tag       = 10'(dpi_tag[7:0]);
                unpack_dpi_to_payload(dpi_data, int'(atomic_op_size_val) * 2,
                                      at_tlp.payload);
                tlp = at_tlp;
            end

            // ------------------------------------------------------------------
            // 14: Vendor Defined Message (VendorMsg / VendorMsgD)
            // ------------------------------------------------------------------
            BV_TLP_VENDOR_MSG: begin
                pcie_tl_vendor_tlp v_tlp;
                v_tlp = pcie_tl_vendor_tlp::type_id::create("vendor_msg_tlp");
                v_tlp.kind      = (dpi_len > 0) ? TLP_VENDOR_MSGD : TLP_VENDOR_MSG;
                v_tlp.fmt       = (dpi_len > 0) ? FMT_4DW_WITH_DATA
                                                : FMT_4DW_NO_DATA;
                v_tlp.type_f    = TLP_TYPE_VENDOR_MSG;
                v_tlp.vendor_id = vendor_id_val;
                if (dpi_len > 0) begin
                    v_tlp.length = (dpi_len + 3) / 4;
                    unpack_dpi_to_payload(dpi_data, dpi_len, v_tlp.payload);
                end
                tlp = v_tlp;
            end

            // ------------------------------------------------------------------
            // 15: LTR (Latency Tolerance Reporting)
            // ------------------------------------------------------------------
            BV_TLP_LTR: begin
                pcie_tl_ltr_tlp ltr_tlp;
                ltr_tlp = pcie_tl_ltr_tlp::type_id::create("ltr_tlp");
                ltr_tlp.kind   = TLP_LTR;
                ltr_tlp.fmt    = FMT_4DW_WITH_DATA;
                ltr_tlp.type_f = TLP_TYPE_MSG_RC;
                ltr_tlp.length = 1;
                // LTR payload encoded in dpi_data[0] per PCIe LTR message format
                ltr_tlp.snoop_latency_value    = dpi_data[0][9:0];
                ltr_tlp.snoop_latency_scale    = dpi_data[0][12:10];
                ltr_tlp.snoop_requirement      = dpi_data[0][15];
                ltr_tlp.no_snoop_latency_value = dpi_data[0][25:16];
                ltr_tlp.no_snoop_latency_scale = dpi_data[0][28:26];
                ltr_tlp.no_snoop_requirement   = dpi_data[0][31];
                tlp = ltr_tlp;
            end

            // ------------------------------------------------------------------
            // 16: Memory Read Lock (MRdLk)
            // ------------------------------------------------------------------
            BV_TLP_MRD_LK: begin
                mem_tlp = pcie_tl_mem_tlp::type_id::create("mem_rd_lk_tlp");
                mem_tlp.kind      = TLP_MEM_RD_LK;
                mem_tlp.addr      = dpi_addr;
                mem_tlp.is_64bit  = (dpi_addr[63:32] != 0);
                mem_tlp.fmt       = mem_tlp.is_64bit ? FMT_4DW_NO_DATA
                                                     : FMT_3DW_NO_DATA;
                mem_tlp.type_f    = TLP_TYPE_MEM_RD_LK;
                mem_tlp.first_be  = first_be_val[3:0];
                mem_tlp.last_be   = last_be_val[3:0];
                mem_tlp.length    = (dpi_len > 0) ? (dpi_len + 3) / 4 : 1;
                mem_tlp.tag       = 10'(dpi_tag[7:0]);
                tlp = mem_tlp;
            end
`endif // COSIM_VIP_MODE

            default: tlp = null;
        endcase

        return tlp;
    endfunction

    // -----------------------------------------------------------------------
    // unpack_dpi_to_payload
    //   Converts the DPI-C int[16] word array into a VIP byte array.
    //   Uses little-endian byte order within each 32-bit word.
    // -----------------------------------------------------------------------
    protected function void unpack_dpi_to_payload(
        input  int unsigned dpi_data[16],
        input  int          byte_count,
        output bit [7:0]    payload[]
    );
        int words, i, b, idx;

        if (byte_count <= 0) begin
            payload = new[0];
            return;
        end

        payload = new[byte_count];
        words = (byte_count + 3) / 4;
        for (i = 0; i < words && i < 16; i++) begin
            for (b = 0; b < 4; b++) begin
                idx = i * 4 + b;
                if (idx < byte_count)
                    payload[idx] = dpi_data[i][(b * 8) +: 8];
            end
        end
    endfunction

    // -----------------------------------------------------------------------
    // pack_payload_to_dpi
    //   Converts a VIP byte array payload into the DPI-C int[16] word array.
    //   Uses little-endian byte order within each 32-bit word.
    //   Unused words are zeroed.
    // -----------------------------------------------------------------------
    protected function void pack_payload_to_dpi(
        input  bit [7:0]    payload[],
        output int unsigned dpi_data[16]
    );
        int words, i, b, idx;

        for (i = 0; i < 16; i++) dpi_data[i] = 0;

        words = (payload.size() + 3) / 4;
        for (i = 0; i < words && i < 16; i++) begin
            for (b = 0; b < 4; b++) begin
                idx = i * 4 + b;
                if (idx < payload.size())
                    dpi_data[i][(b * 8) +: 8] = payload[idx];
            end
        end
    endfunction

    // -----------------------------------------------------------------------
    // report_phase: print TLP type coverage table
    // -----------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        string type_name;
        super.report_phase(phase);

        `uvm_info(get_name(), "=== cosim_rc_driver TLP Coverage Summary ===", UVM_NONE)
        `uvm_info(get_name(),
            $sformatf("  Total TLPs processed : %0d", total_tlp_count), UVM_NONE)
        `uvm_info(get_name(),
            $sformatf("  Total completions    : %0d", total_cpl_count),  UVM_NONE)
        `uvm_info(get_name(),
            $sformatf("  Unknown type drops   : %0d", unknown_type_count), UVM_NONE)

        if (tlp_type_count.first(type_name)) begin
            do begin
                `uvm_info(get_name(),
                    $sformatf("  %-30s : %0d", type_name,
                              tlp_type_count[type_name]), UVM_NONE)
            end while (tlp_type_count.next(type_name));
        end

        if (tlp_type_errors.first(type_name)) begin
            do begin
                `uvm_info(get_name(),
                    $sformatf("  [ERRORS] %-24s : %0d", type_name,
                              tlp_type_errors[type_name]), UVM_NONE)
            end while (tlp_type_errors.next(type_name));
        end

        `uvm_info(get_name(), "============================================", UVM_NONE)
    endfunction

endclass

`endif // COSIM_RC_DRIVER_SV
