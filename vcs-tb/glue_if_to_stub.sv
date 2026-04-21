/* cosim-platform/vcs-tb/glue_if_to_stub.sv
 *
 * Glue layer: converts the VIP pcie_tl_if 256-bit bus to the simple
 * pcie_ep_stub TLP/completion signals.
 *
 * Bus encoding (from pcie_tl_if_adapter.sv pack_beat):
 *   bytes[n] is stored at data[n*8 +: 8], i.e. little-endian byte lane order.
 *   The bytes themselves follow the PCIe big-endian DW layout, so:
 *
 *   data[7:0]    = bytes[0]  = {Fmt[2:0], Type[4:0]}        (DW0 MSByte)
 *   data[15:8]   = bytes[1]  = {R, TC[2:0], R, Attr[2], R, TH}
 *   data[23:16]  = bytes[2]  = {TD, EP, Attr[1:0], AT[1:0], Length[9:8]}
 *   data[31:24]  = bytes[3]  = Length[7:0]                   (DW0 LSByte)
 *   data[39:32]  = bytes[4]  = RequesterID[15:8]
 *   data[47:40]  = bytes[5]  = RequesterID[7:0]
 *   data[55:48]  = bytes[6]  = Tag[7:0]
 *   data[63:56]  = bytes[7]  = {LastBE[3:0], FirstBE[3:0]}
 *   -- 3DW header: bytes[8..11] = Addr[31:0] big-endian, bytes[12..15] = Data
 *   -- 4DW header: bytes[8..11] = AddrHi, bytes[12..15] = AddrLo, bytes[16..19] = Data
 */

`timescale 1ns/1ps

module glue_if_to_stub (
    input  logic        clk,
    input  logic        rst_n,

    // VIP side - request channel (from RC driver)
    input  logic [255:0] vip_tlp_data,
    input  logic [3:0]   vip_tlp_strb,
    input  logic         vip_tlp_valid,
    output logic         vip_tlp_ready,
    input  logic         vip_tlp_sop,
    input  logic         vip_tlp_eop,
    output logic         vip_tlp_error,

    // FC credit to VIP
    output logic [7:0]   vip_ph_credit,
    output logic [11:0]  vip_pd_credit,
    output logic [7:0]   vip_nph_credit,
    output logic [11:0]  vip_npd_credit,
    output logic [7:0]   vip_cplh_credit,
    output logic [11:0]  vip_cpld_credit,
    output logic         vip_fc_update,

    // VIP side - completion return channel
    output logic [255:0] vip_cpl_data,
    output logic [3:0]   vip_cpl_strb,
    output logic         vip_cpl_valid,
    input  logic         vip_cpl_ready,
    output logic         vip_cpl_sop,
    output logic         vip_cpl_eop,

    // Stub side - same as pcie_ep_stub ports
    output logic         stub_tlp_valid,
    output logic [2:0]   stub_tlp_type,
    output logic [63:0]  stub_tlp_addr,
    output logic [31:0]  stub_tlp_wdata,
    output logic [15:0]  stub_tlp_len,
    output logic [7:0]   stub_tlp_tag,
    input  logic         stub_cpl_valid,
    input  logic [7:0]   stub_cpl_tag,
    input  logic [31:0]  stub_cpl_rdata,
    input  logic         stub_cpl_status,

    // Stub pass-through
    input  logic         stub_notify_valid,
    input  logic [15:0]  stub_notify_queue,
    output logic         stub_isr_set
);

    // =========================================================================
    // PCIe TLP format constants
    // =========================================================================
    // Fmt field encoding (Fmt[2:0] = data[7:5] in first bus byte)
    // Fmt[0]: 0=3DW header, 1=4DW header
    // Fmt[1]: 0=no data,    1=has data
    localparam logic [2:0] FMT_3DW_NO_DATA   = 3'b000;
    localparam logic [2:0] FMT_3DW_WITH_DATA = 3'b010;
    localparam logic [2:0] FMT_4DW_NO_DATA   = 3'b001;
    localparam logic [2:0] FMT_4DW_WITH_DATA = 3'b011;

    // Type field encoding (Type[4:0] = data[4:0] in first bus byte)
    localparam logic [4:0] TYPE_MEM     = 5'b0_0000;
    localparam logic [4:0] TYPE_MEM_LK  = 5'b0_0001;
    localparam logic [4:0] TYPE_CFG0    = 5'b0_0100;
    localparam logic [4:0] TYPE_CFG1    = 5'b0_0101;

    // stub_tlp_type encoding (matches pcie_ep_stub case statement)
    localparam logic [2:0] STUB_MWR   = 3'd0;
    localparam logic [2:0] STUB_MRD   = 3'd1;
    localparam logic [2:0] STUB_CFGWR = 3'd2;
    localparam logic [2:0] STUB_CFGRD = 3'd3;

    // PCIe completion status values
    localparam logic [2:0] CPL_STATUS_SC = 3'b000;
    localparam logic [2:0] CPL_STATUS_UR = 3'b001;

    // Completion TLP DW0 byte[0]: Fmt=010 (3DW+data), Type=01010 (Cpl)
    localparam logic [7:0] CPL_DW0_BYTE0 = 8'h4A;  // {3'b010, 5'b01010}

    // =========================================================================
    // State machine
    // =========================================================================
    typedef enum logic [1:0] {
        ST_IDLE    = 2'd0,
        ST_COLLECT = 2'd1,
        ST_DECODE  = 2'd2
    } state_t;

    state_t state;

    // =========================================================================
    // Beat accumulation: capture first 256-bit beat which contains the full
    // 3DW or 4DW header plus one data DW (all fit within 256 bits).
    // =========================================================================
    logic [255:0] beat0_q;

    // =========================================================================
    // Decoded header fields (combinational from beat0_q)
    // =========================================================================
    logic [2:0]  hdr_fmt;
    logic [4:0]  hdr_type;
    logic [9:0]  hdr_length;
    logic [7:0]  hdr_tag;
    logic        hdr_is_4dw;
    logic        hdr_has_data;
    logic [63:0] hdr_addr;
    logic [31:0] hdr_wdata;

    always_comb begin
        // bytes[0] = data[7:0] = {Fmt[2:0], Type[4:0]}
        hdr_fmt  = beat0_q[7:5];
        hdr_type = beat0_q[4:0];

        // bytes[2..3] carry Length:
        //   bytes[2] = data[23:16]: bit[1:0] = Length[9:8]
        //   bytes[3] = data[31:24]: Length[7:0]
        hdr_length = {beat0_q[17:16], beat0_q[31:24]};

        // bytes[6] = data[55:48] = Tag[7:0]
        hdr_tag = beat0_q[55:48];

        // Fmt bit[0] selects 3DW vs 4DW; Fmt bit[1] indicates data present
        hdr_is_4dw   = hdr_fmt[0];
        hdr_has_data = hdr_fmt[1];

        // Address extraction (PCIe big-endian byte order within each DW):
        //   3DW: bytes[8..11] = Addr[31:0]
        //     bytes[8]  = data[71:64]  = Addr[31:24]
        //     bytes[9]  = data[79:72]  = Addr[23:16]
        //     bytes[10] = data[87:80]  = Addr[15:8]
        //     bytes[11] = data[95:88]  = Addr[7:0]
        //   4DW: bytes[8..11] = AddrHi[31:0], bytes[12..15] = AddrLo[31:0]
        if (!hdr_is_4dw) begin
            hdr_addr = {32'h0,
                        beat0_q[71:64],    // Addr[31:24]
                        beat0_q[79:72],    // Addr[23:16]
                        beat0_q[87:80],    // Addr[15:8]
                        beat0_q[95:88]};   // Addr[7:0]
        end else begin
            hdr_addr = {beat0_q[71:64],    // AddrHi[31:24]
                        beat0_q[79:72],    // AddrHi[23:16]
                        beat0_q[87:80],    // AddrHi[15:8]
                        beat0_q[95:88],    // AddrHi[7:0]
                        beat0_q[103:96],   // AddrLo[31:24]
                        beat0_q[111:104],  // AddrLo[23:16]
                        beat0_q[119:112],  // AddrLo[15:8]
                        beat0_q[127:120]}; // AddrLo[7:0]
        end

        // Write data (first payload DW, PCIe big-endian byte order):
        //   3DW: bytes[12..15] = Data
        //     bytes[12] = data[103:96]  = Data[31:24]
        //     bytes[13] = data[111:104] = Data[23:16]
        //     bytes[14] = data[119:112] = Data[15:8]
        //     bytes[15] = data[127:120] = Data[7:0]
        //   4DW: bytes[16..19] = Data
        //     bytes[16] = data[135:128] = Data[31:24]
        //     bytes[17] = data[143:136] = Data[23:16]
        //     bytes[18] = data[151:144] = Data[15:8]
        //     bytes[19] = data[159:152] = Data[7:0]
        if (!hdr_is_4dw) begin
            hdr_wdata = {beat0_q[103:96],
                         beat0_q[111:104],
                         beat0_q[119:112],
                         beat0_q[127:120]};
        end else begin
            hdr_wdata = {beat0_q[135:128],
                         beat0_q[143:136],
                         beat0_q[151:144],
                         beat0_q[159:152]};
        end
    end

    // =========================================================================
    // TLP type decode: map PCIe Fmt+Type to stub 3-bit type
    // =========================================================================
    logic [2:0] decoded_stub_type;
    logic       decoded_unsupported;

    always_comb begin
        decoded_unsupported = 1'b0;
        decoded_stub_type   = STUB_MRD;

        case (hdr_type)
            TYPE_MEM: begin
                decoded_stub_type = hdr_has_data ? STUB_MWR : STUB_MRD;
            end
            TYPE_MEM_LK: begin
                // Locked read → treat as MRd (no data)
                decoded_stub_type = STUB_MRD;
            end
            TYPE_CFG0, TYPE_CFG1: begin
                decoded_stub_type = hdr_has_data ? STUB_CFGWR : STUB_CFGRD;
            end
            default: begin
                decoded_unsupported = 1'b1;
                decoded_stub_type   = STUB_MRD;
            end
        endcase
    end

    // =========================================================================
    // UR completion pending register
    // Non-posted unsupported TLPs (no data, i.e. reads) require a UR completion.
    // Posted unsupported TLPs (writes) are silently dropped per PCIe spec.
    // =========================================================================
    logic       ur_pending_q;
    logic [7:0] ur_tag_q;

    // =========================================================================
    // State machine transitions and beat capture
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            beat0_q      <= '0;
            ur_pending_q <= 1'b0;
            ur_tag_q     <= 8'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (vip_tlp_valid && vip_tlp_sop) begin
                        beat0_q <= vip_tlp_data;
                        if (vip_tlp_eop)
                            state <= ST_DECODE;
                        else
                            state <= ST_COLLECT;
                    end
                end

                ST_COLLECT: begin
                    // Wait for EOP (additional beats don't affect header decode)
                    if (vip_tlp_valid && vip_tlp_eop)
                        state <= ST_DECODE;
                end

                ST_DECODE: begin
                    // Issue stub TLP or record UR pending; return to IDLE next cycle
                    state <= ST_IDLE;

                    // Non-posted unsupported → queue UR completion
                    if (decoded_unsupported && !hdr_has_data) begin
                        ur_pending_q <= 1'b1;
                        ur_tag_q     <= hdr_tag;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            // Clear UR pending once completion has been accepted by VIP
            if (ur_pending_q && vip_cpl_valid && vip_cpl_ready)
                ur_pending_q <= 1'b0;
        end
    end

    // =========================================================================
    // Stub request outputs (pulsed for one cycle during ST_DECODE)
    // stub_tlp_len: pass as byte count (DW count * 4), matching tb_top usage
    // =========================================================================
    logic [15:0] decoded_len_bytes;
    assign decoded_len_bytes = (hdr_length == 10'd0) ? 16'd4096 :
                               {{6{1'b0}}, hdr_length} << 2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stub_tlp_valid <= 1'b0;
            stub_tlp_type  <= 3'd0;
            stub_tlp_addr  <= 64'd0;
            stub_tlp_wdata <= 32'd0;
            stub_tlp_len   <= 16'd0;
            stub_tlp_tag   <= 8'd0;
        end else begin
            stub_tlp_valid <= 1'b0;  // default: deassert each cycle

            if (state == ST_DECODE && !decoded_unsupported) begin
                stub_tlp_valid <= 1'b1;
                stub_tlp_type  <= decoded_stub_type;
                stub_tlp_addr  <= hdr_addr;
                stub_tlp_wdata <= hdr_wdata;
                stub_tlp_len   <= decoded_len_bytes;
                stub_tlp_tag   <= hdr_tag;
            end
        end
    end

    // =========================================================================
    // VIP request channel back-pressure and error
    // =========================================================================
    assign vip_tlp_ready = (state == ST_IDLE || state == ST_COLLECT);
    assign vip_tlp_error = 1'b0;

    // =========================================================================
    // Completion channel to VIP
    //
    // PCIe CplD TLP (3DW header + 1 DW data), in 256-bit bus encoding:
    //
    //   Beat byte layout (pack_beat: bytes[n] → data[n*8+:8]):
    //   DW0 (bytes[0..3]):
    //     bytes[0]  = {Fmt=010, Type=01010}  = 8'h4A
    //     bytes[1]  = 8'h00  (TC=0, no Attr)
    //     bytes[2]  = 8'h00  (TD=0, EP=0, Length[9:8]=0)
    //     bytes[3]  = 8'h01  (Length=1 DW)
    //   DW1 (bytes[4..7]): CompleterID | Status|BCM|ByteCount
    //     bytes[4]  = CompleterID[15:8]
    //     bytes[5]  = CompleterID[7:0]
    //     bytes[6]  = {Status[2:0], BCM=0, ByteCount[11:8]=0}
    //     bytes[7]  = ByteCount[7:0] = 4
    //   DW2 (bytes[8..11]): RequesterID | Tag | LowerAddr
    //     bytes[8]  = RequesterID[15:8] = 8'h00
    //     bytes[9]  = RequesterID[7:0]  = 8'h00
    //     bytes[10] = Tag[7:0]
    //     bytes[11] = {R, LowerAddr[6:0]} = 8'h00
    //   DW3 (bytes[12..15]): Data (PCIe big-endian)
    //     bytes[12] = rdata[31:24]
    //     bytes[13] = rdata[23:16]
    //     bytes[14] = rdata[15:8]
    //     bytes[15] = rdata[7:0]
    //
    // strb=4'h1 → 8 valid byte lanes (bytes[0..7]), but we have 16 bytes of
    // header+data; using strb=4'h3 for 16 bytes (per calc_strb: ≥16 → 4'h3).
    // =========================================================================

    // Mux: UR pending takes priority over stub completion
    logic        any_cpl_valid;
    logic [7:0]  cpl_tag_mux;
    logic [31:0] cpl_rdata_mux;
    logic [2:0]  cpl_status_mux;

    assign any_cpl_valid  = stub_cpl_valid || ur_pending_q;
    assign cpl_tag_mux    = ur_pending_q ? ur_tag_q      : stub_cpl_tag;
    assign cpl_rdata_mux  = ur_pending_q ? 32'hFFFF_FFFF : stub_cpl_rdata;
    assign cpl_status_mux = ur_pending_q ? CPL_STATUS_UR :
                            (stub_cpl_status ? CPL_STATUS_UR : CPL_STATUS_SC);

    // Build 256-bit beat for a CplD TLP
    function automatic logic [255:0] build_cpld_beat(
        input logic [7:0]  tag,
        input logic [31:0] rdata,
        input logic [2:0]  status
    );
        logic [255:0] d;
        d = '0;
        // DW0
        d[7:0]    = CPL_DW0_BYTE0;          // {Fmt=010, Type=01010}
        d[15:8]   = 8'h00;
        d[23:16]  = 8'h00;
        d[31:24]  = 8'h01;                  // Length = 1 DW
        // DW1: CompleterID=0x0100, Status, ByteCount=4
        d[39:32]  = 8'h01;                  // CompleterID[15:8]
        d[47:40]  = 8'h00;                  // CompleterID[7:0]
        d[55:48]  = {status, 1'b0, 4'h0};   // Status[2:0], BCM=0, BC[11:8]=0
        d[63:56]  = 8'h04;                  // ByteCount = 4
        // DW2: RequesterID=0x0000, Tag, LowerAddr=0
        d[71:64]  = 8'h00;
        d[79:72]  = 8'h00;
        d[87:80]  = tag;
        d[95:88]  = 8'h00;
        // DW3: Data (big-endian byte order per PCIe)
        d[103:96]  = rdata[31:24];
        d[111:104] = rdata[23:16];
        d[119:112] = rdata[15:8];
        d[127:120] = rdata[7:0];
        return d;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vip_cpl_valid <= 1'b0;
            vip_cpl_data  <= '0;
            vip_cpl_strb  <= 4'h0;
            vip_cpl_sop   <= 1'b0;
            vip_cpl_eop   <= 1'b0;
        end else begin
            if (any_cpl_valid && (!vip_cpl_valid || vip_cpl_ready)) begin
                vip_cpl_valid <= 1'b1;
                vip_cpl_sop   <= 1'b1;
                vip_cpl_eop   <= 1'b1;
                vip_cpl_strb  <= 4'h3;   // 16 valid bytes (3DW hdr + 1DW data)
                vip_cpl_data  <= build_cpld_beat(cpl_tag_mux,
                                                  cpl_rdata_mux,
                                                  cpl_status_mux);
            end else if (vip_cpl_valid && vip_cpl_ready) begin
                vip_cpl_valid <= 1'b0;
                vip_cpl_sop   <= 1'b0;
                vip_cpl_eop   <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Flow control credits: advertise infinite (maximum) credits
    // =========================================================================
    assign vip_ph_credit   = 8'hFF;
    assign vip_pd_credit   = 12'hFFF;
    assign vip_nph_credit  = 8'hFF;
    assign vip_npd_credit  = 12'hFFF;
    assign vip_cplh_credit = 8'hFF;
    assign vip_cpld_credit = 12'hFFF;

    // Pulse fc_update for one cycle each time we dispatch a TLP to the stub
    // (registered from ST_DECODE so it appears one cycle after the decode)
    logic fc_update_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fc_update_q <= 1'b0;
        else
            fc_update_q <= (state == ST_DECODE);
    end
    assign vip_fc_update = fc_update_q;

    // =========================================================================
    // Stub pass-through
    // stub_notify_valid / stub_notify_queue are outputs from pcie_ep_stub and
    // are passed straight through this module's ports for tb_top wiring.
    // stub_isr_set is driven by tb_top directly; this glue layer does not
    // originate ISR set requests, so tie to 0.
    // =========================================================================
    assign stub_isr_set = 1'b0;

    // =========================================================================
    // Debug display (simulation only)
    // =========================================================================
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (state == ST_DECODE) begin
            if (decoded_unsupported)
                $display("[GLUE] Unsupported TLP: Fmt=%0h Type=%0h Tag=%0h has_data=%0b -> %s",
                         hdr_fmt, hdr_type, hdr_tag, hdr_has_data,
                         hdr_has_data ? "drop (posted)" : "UR completion");
            else
                $display("[GLUE] TLP -> stub: type=%0d addr=0x%016h wdata=0x%08h len=%0d tag=0x%02h",
                         decoded_stub_type, hdr_addr, hdr_wdata,
                         decoded_len_bytes, hdr_tag);
        end
        if (stub_cpl_valid)
            $display("[GLUE] stub cpl: tag=0x%02h rdata=0x%08h status=%0d",
                     stub_cpl_tag, stub_cpl_rdata, stub_cpl_status);
        if (ur_pending_q && vip_cpl_valid && vip_cpl_ready)
            $display("[GLUE] UR completion sent: tag=0x%02h", ur_tag_q);
    end
`endif

endmodule
