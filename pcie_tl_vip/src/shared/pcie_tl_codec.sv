//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - TLP Codec
// Bidirectional TLP object <-> byte stream conversion with error injection
//-----------------------------------------------------------------------------

class pcie_tl_codec extends uvm_object;
    `uvm_object_utils(pcie_tl_codec)

    function new(string name = "pcie_tl_codec");
        super.new(name);
    endfunction

    //=========================================================================
    // Encode: TLP object -> byte stream
    //=========================================================================
    function void encode(pcie_tl_tlp tlp, output bit [7:0] bytes[]);
        bit [31:0] header[];
        bit [31:0] ecrc;
        int idx = 0;

        // Build header DWords
        build_header(tlp, header);

        // Total bytes = header + payload + optional ECRC(4 bytes)
        bytes = new[(header.size() * 4) + tlp.payload.size() + (tlp.td ? 4 : 0)];

        // Pack header into byte stream (big-endian per PCIe spec)
        foreach (header[i]) begin
            bytes[idx++] = header[i][31:24];
            bytes[idx++] = header[i][23:16];
            bytes[idx++] = header[i][15:8];
            bytes[idx++] = header[i][7:0];
        end

        // Append payload
        foreach (tlp.payload[i]) begin
            bytes[idx++] = tlp.payload[i];
        end

        // Apply field_bitmask bit flips on header portion
        if (tlp.field_bitmask != 0) begin
            apply_bitmask(bytes, tlp.field_bitmask);
        end

        // Calculate and append ECRC
        if (tlp.td) begin
            ecrc = calc_ecrc(bytes, idx);
            if (tlp.inject_ecrc_err)
                ecrc = ecrc ^ 32'hDEADBEEF;  // corrupt ECRC
            bytes[idx++] = ecrc[31:24];
            bytes[idx++] = ecrc[23:16];
            bytes[idx++] = ecrc[15:8];
            bytes[idx++] = ecrc[7:0];
        end

        // Apply poisoned bit
        if (tlp.inject_poisoned)
            bytes[1] = bytes[1] | 8'h40;  // Set EP bit in Byte 1
    endfunction

    //=========================================================================
    // Decode: byte stream -> TLP object
    //=========================================================================
    function pcie_tl_tlp decode(bit [7:0] bytes[]);
        pcie_tl_tlp tlp;
        bit [31:0] dw0, dw1, dw2, dw3;
        tlp_fmt_e  fmt;
        tlp_type_e type_f;
        int hdr_len;
        int payload_start;
        int payload_len;

        // Parse first DW
        dw0 = {bytes[0], bytes[1], bytes[2], bytes[3]};
        dw1 = {bytes[4], bytes[5], bytes[6], bytes[7]};
        dw2 = {bytes[8], bytes[9], bytes[10], bytes[11]};

        fmt    = tlp_fmt_e'(dw0[31:29]);
        type_f = tlp_type_e'(dw0[28:24]);

        hdr_len = (fmt == FMT_4DW_NO_DATA || fmt == FMT_4DW_WITH_DATA) ? 16 : 12;
        if (hdr_len == 16)
            dw3 = {bytes[12], bytes[13], bytes[14], bytes[15]};

        // Determine TLP kind and create appropriate derived class
        tlp = create_tlp_by_type(fmt, type_f);

        // Fill common fields
        tlp.fmt          = fmt;
        tlp.type_f       = type_f;
        tlp.tc           = dw0[22:20];
        tlp.th           = dw0[16];
        tlp.td           = dw0[15];
        tlp.ep_bit       = dw0[14];
        tlp.attr         = {dw0[18], dw0[13:12]};
        tlp.length       = dw0[9:0];
        tlp.requester_id = dw1[31:16];
        tlp.tag[7:0]     = dw1[15:8];

        // Payload
        payload_start = hdr_len;
        if (fmt == FMT_3DW_WITH_DATA || fmt == FMT_4DW_WITH_DATA) begin
            bit [9:0] len_dw = (tlp.length == 0) ? 10'd1024 : tlp.length;
            payload_len = len_dw * 4;
            // Account for ECRC at end
            if (tlp.td && (bytes.size() >= payload_start + payload_len + 4))
                payload_len = bytes.size() - payload_start - 4;
            else if (!tlp.td)
                payload_len = bytes.size() - payload_start;

            /* CoSim 本地补丁（对应已合入上游前的 233595b）：
               short TLP beat (如 CfgWr 的 header+4B) 下 payload_len 可能算出
               负数，new[] 传负值会触发 VCS DT-NV fatal。钳为 0 防止崩溃。 */
            if (payload_len < 0) payload_len = 0;

            tlp.payload = new[payload_len];
            for (int i = 0; i < payload_len; i++)
                tlp.payload[i] = bytes[payload_start + i];
        end

        // Fill type-specific fields
        fill_type_specific(tlp, dw1, dw2, dw3, hdr_len);

        return tlp;
    endfunction

    //=========================================================================
    // ECRC calculation (CRC-32 over TLP, variant C per PCIe spec)
    //=========================================================================
    function bit [31:0] calc_ecrc(bit [7:0] bytes[], int len);
        bit [31:0] crc = 32'hFFFFFFFF;
        bit [31:0] poly = 32'h04C11DB7;

        for (int i = 0; i < len; i++) begin
            // Skip Type/EP/TD bits in byte 0 and 1 for ECRC
            crc = crc ^ ({bytes[i], 24'h0});
            for (int j = 0; j < 8; j++) begin
                if (crc[31])
                    crc = (crc << 1) ^ poly;
                else
                    crc = crc << 1;
            end
        end
        return ~crc;
    endfunction

    function bit verify_ecrc(bit [7:0] bytes[]);
        int payload_end = bytes.size() - 4;
        bit [31:0] expected = calc_ecrc(bytes, payload_end);
        bit [31:0] actual = {bytes[payload_end], bytes[payload_end+1],
                             bytes[payload_end+2], bytes[payload_end+3]};
        return (expected == actual);
    endfunction

    //=========================================================================
    // Internal: Build header DWords from TLP object
    //=========================================================================
    protected function void build_header(pcie_tl_tlp tlp, output bit [31:0] hdr[]);
        bit [31:0] dw0, dw1, dw2, dw3;
        int num_dw;

        num_dw = tlp.is_4dw() ? 4 : 3;
        hdr = new[num_dw];

        // DW0: Fmt[2:0] | Type[4:0] | R | TC[2:0] | R | Attr[2] | R | TH | TD | EP | Attr[1:0] | AT[1:0] | Length[9:0]
        dw0 = {tlp.fmt, tlp.type_f, 1'b0, tlp.tc, 1'b0, tlp.attr[2], 1'b0,
                tlp.th, tlp.td, tlp.ep_bit, tlp.attr[1:0], 2'b00, tlp.length};
        hdr[0] = dw0;

        // DW1: Requester ID[15:0] | Tag[7:0] | (Last BE / First BE or other)
        // Type-specific DW1 handling
        if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR}) begin
            pcie_tl_mem_tlp mem;
            $cast(mem, tlp);
            dw1 = {tlp.requester_id, tlp.tag[7:0], mem.last_be, mem.first_be};
            hdr[1] = dw1;
            if (num_dw == 4) begin
                hdr[2] = mem.addr[63:32];
                hdr[3] = {mem.addr[31:2], 2'b00};
            end else begin
                hdr[2] = {mem.addr[31:2], 2'b00};
            end
        end
        else if (tlp.kind inside {TLP_IO_RD, TLP_IO_WR}) begin
            pcie_tl_io_tlp io;
            $cast(io, tlp);
            dw1 = {tlp.requester_id, tlp.tag[7:0], 4'h0, io.first_be};
            hdr[1] = dw1;
            hdr[2] = {io.addr[31:2], 2'b00};
        end
        else if (tlp.kind inside {TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1}) begin
            pcie_tl_cfg_tlp cfg;
            $cast(cfg, tlp);
            dw1 = {tlp.requester_id, tlp.tag[7:0], 4'h0, cfg.first_be};
            hdr[1] = dw1;
            hdr[2] = {cfg.completer_id, 4'h0, cfg.reg_num, 2'b00};
        end
        else if (tlp.kind inside {TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK}) begin
            pcie_tl_cpl_tlp cpl;
            $cast(cpl, tlp);
            dw1 = {cpl.completer_id, cpl.cpl_status, cpl.bcm, cpl.byte_count};
            hdr[1] = dw1;
            dw2 = {tlp.requester_id, tlp.tag[7:0], 1'b0, cpl.lower_addr};
            hdr[2] = dw2;
        end
        else if (tlp.kind inside {TLP_MSG, TLP_MSGD}) begin
            pcie_tl_msg_tlp msg;
            $cast(msg, tlp);
            dw1 = {tlp.requester_id, tlp.tag[7:0], msg.msg_code};
            hdr[1] = dw1;
            hdr[2] = msg.msg_addr[63:32];
            hdr[3] = msg.msg_addr[31:0];
        end
        else if (tlp.kind inside {TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS}) begin
            pcie_tl_atomic_tlp atm;
            $cast(atm, tlp);
            dw1 = {tlp.requester_id, tlp.tag[7:0], 8'h0F};
            hdr[1] = dw1;
            if (num_dw == 4) begin
                hdr[2] = atm.addr[63:32];
                hdr[3] = {atm.addr[31:2], 2'b00};
            end else begin
                hdr[2] = {atm.addr[31:2], 2'b00};
            end
        end
        else begin
            // Default: generic header
            dw1 = {tlp.requester_id, tlp.tag[7:0], 8'h00};
            hdr[1] = dw1;
            hdr[2] = 32'h0;
            if (num_dw == 4) hdr[3] = 32'h0;
        end

    endfunction

    //=========================================================================
    // Internal: Apply bitmask for error injection
    //=========================================================================
    protected function void apply_bitmask(ref bit [7:0] bytes[], bit [31:0] mask);
        // Apply bitmask to first 4 bytes (DW0) of header
        for (int i = 0; i < 4 && i < bytes.size(); i++) begin
            bytes[i] = bytes[i] ^ mask[(3-i)*8 +: 8];
        end
    endfunction

    //=========================================================================
    // Internal: Create correct TLP subclass by Fmt+Type
    //=========================================================================
    protected function pcie_tl_tlp create_tlp_by_type(tlp_fmt_e fmt, tlp_type_e type_f);
        bit has_data = (fmt == FMT_3DW_WITH_DATA || fmt == FMT_4DW_WITH_DATA);

        case (type_f)
            TLP_TYPE_MEM_RD, TLP_TYPE_MEM_RD_LK: begin
                pcie_tl_mem_tlp t = pcie_tl_mem_tlp::type_id::create("mem_tlp");
                if (type_f == TLP_TYPE_MEM_RD_LK) t.kind = TLP_MEM_RD_LK;
                else if (has_data) t.kind = TLP_MEM_WR;
                else t.kind = TLP_MEM_RD;
                return t;
            end
            TLP_TYPE_IO_RD: begin
                pcie_tl_io_tlp t = pcie_tl_io_tlp::type_id::create("io_tlp");
                t.kind = has_data ? TLP_IO_WR : TLP_IO_RD;
                return t;
            end
            TLP_TYPE_CFG_RD0: begin
                pcie_tl_cfg_tlp t = pcie_tl_cfg_tlp::type_id::create("cfg_tlp");
                t.kind = has_data ? TLP_CFG_WR0 : TLP_CFG_RD0;
                return t;
            end
            TLP_TYPE_CFG_RD1: begin
                pcie_tl_cfg_tlp t = pcie_tl_cfg_tlp::type_id::create("cfg_tlp");
                t.kind = has_data ? TLP_CFG_WR1 : TLP_CFG_RD1;
                return t;
            end
            TLP_TYPE_CPL: begin
                pcie_tl_cpl_tlp t = pcie_tl_cpl_tlp::type_id::create("cpl_tlp");
                t.kind = has_data ? TLP_CPLD : TLP_CPL;
                return t;
            end
            TLP_TYPE_CPL_LK: begin
                pcie_tl_cpl_tlp t = pcie_tl_cpl_tlp::type_id::create("cpl_tlp");
                t.kind = has_data ? TLP_CPLD_LK : TLP_CPL_LK;
                return t;
            end
            TLP_TYPE_MSG_RC, TLP_TYPE_MSG_ADDR, TLP_TYPE_MSG_ID,
            TLP_TYPE_MSG_BCAST, TLP_TYPE_MSG_LOCAL, TLP_TYPE_MSG_PME_TO_ACK: begin
                pcie_tl_msg_tlp t = pcie_tl_msg_tlp::type_id::create("msg_tlp");
                t.kind = has_data ? TLP_MSGD : TLP_MSG;
                return t;
            end
            TLP_TYPE_ATOMIC_FETCHADD: begin
                pcie_tl_atomic_tlp t = pcie_tl_atomic_tlp::type_id::create("atomic_tlp");
                t.kind = TLP_ATOMIC_FETCHADD;
                return t;
            end
            TLP_TYPE_ATOMIC_SWAP: begin
                pcie_tl_atomic_tlp t = pcie_tl_atomic_tlp::type_id::create("atomic_tlp");
                t.kind = TLP_ATOMIC_SWAP;
                return t;
            end
            TLP_TYPE_ATOMIC_CAS: begin
                pcie_tl_atomic_tlp t = pcie_tl_atomic_tlp::type_id::create("atomic_tlp");
                t.kind = TLP_ATOMIC_CAS;
                return t;
            end
            TLP_TYPE_VENDOR_MSG: begin
                pcie_tl_vendor_tlp t = pcie_tl_vendor_tlp::type_id::create("vendor_tlp");
                t.kind = has_data ? TLP_VENDOR_MSGD : TLP_VENDOR_MSG;
                return t;
            end
            default: begin
                pcie_tl_tlp t = pcie_tl_tlp::type_id::create("generic_tlp");
                return t;
            end
        endcase
    endfunction

    //=========================================================================
    // Internal: Fill type-specific fields from header DWords
    //=========================================================================
    protected function void fill_type_specific(pcie_tl_tlp tlp,
                                                bit [31:0] dw1, bit [31:0] dw2,
                                                bit [31:0] dw3, int hdr_len);
        case (tlp.kind)
            TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR: begin
                pcie_tl_mem_tlp mem;
                $cast(mem, tlp);
                mem.last_be  = dw1[7:4];
                mem.first_be = dw1[3:0];
                if (hdr_len == 16) begin
                    mem.is_64bit = 1;
                    mem.addr = {dw2, dw3[31:2], 2'b00};
                end else begin
                    mem.is_64bit = 0;
                    mem.addr = {32'h0, dw2[31:2], 2'b00};
                end
            end
            TLP_IO_RD, TLP_IO_WR: begin
                pcie_tl_io_tlp io;
                $cast(io, tlp);
                io.first_be = dw1[3:0];
                io.addr = {dw2[31:2], 2'b00};
            end
            TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1: begin
                pcie_tl_cfg_tlp cfg;
                $cast(cfg, tlp);
                cfg.first_be     = dw1[3:0];
                cfg.completer_id = dw2[31:16];
                cfg.reg_num      = dw2[11:2];
            end
            TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK: begin
                pcie_tl_cpl_tlp cpl;
                $cast(cpl, tlp);
                cpl.completer_id = dw1[31:16];
                cpl.cpl_status   = cpl_status_e'(dw1[15:13]);
                cpl.bcm          = dw1[12];
                cpl.byte_count   = dw1[11:0];
                cpl.lower_addr   = dw2[6:0];
            end
            TLP_MSG, TLP_MSGD: begin
                pcie_tl_msg_tlp msg;
                $cast(msg, tlp);
                msg.msg_code = msg_code_e'(dw1[7:0]);
                if (hdr_len == 16)
                    msg.msg_addr = {dw2, dw3};
            end
            TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS: begin
                pcie_tl_atomic_tlp atm;
                $cast(atm, tlp);
                if (hdr_len == 16) begin
                    atm.is_64bit = 1;
                    atm.addr = {dw2, dw3[31:2], 2'b00};
                end else begin
                    atm.is_64bit = 0;
                    atm.addr = {32'h0, dw2[31:2], 2'b00};
                end
            end
        endcase
    endfunction

endclass
