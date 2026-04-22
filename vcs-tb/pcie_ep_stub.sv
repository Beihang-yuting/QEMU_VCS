/* cosim-platform/vcs-tb/pcie_ep_stub.sv
 * PCIe EP 桩：通用寄存器 + NIC TX + DMA + Virtio-PCI
 *
 * BAR0 寄存器映射 (64KB):
 *   0x000-0x03C  reg[0]-reg[15]  通用寄存器 (reset: 0xDEAD_0000+i)
 *   0x040       TX_LEN          写入待发包长度(字节), 读返回当前值
 *   0x044       TX_DOORBELL     写入触发发包, 读返回已发包计数
 *   0x048       TX_STATUS       读: 0=idle, 1=last TX done
 *   0x050       DMA_ADDR_LO     DMA guest physical address low 32b
 *   0x054       DMA_ADDR_HI     DMA guest physical address high 32b
 *   0x058       DMA_LEN         DMA transfer length (bytes)
 *   0x05C       DMA_DOORBELL    write 1=DMA read test, 2=DMA write test
 *   0x060       DMA_STATUS      0=idle, 1=pass, 2=fail
 *   0x100-0x1FC TX_BUF[0..63]   256字节 TX buffer (64 x 32-bit)
 *
 * Virtio-PCI 区域 (BAR0):
 *   0x1000-0x1037  common_cfg     virtio common configuration (56 bytes)
 *   0x2000-0x2003  notify         virtio notification (4 bytes)
 *   0x3000-0x3003  isr            virtio ISR status (4 bytes)
 *   0x4000-0x400B  device_cfg     virtio-net device config (12 bytes)
 *
 * Config Space Capabilities (offset 0x40-0x87):
 *   0x40  VIRTIO_PCI_CAP_COMMON_CFG  → BAR0+0x1000
 *   0x54  VIRTIO_PCI_CAP_NOTIFY_CFG  → BAR0+0x2000
 *   0x68  VIRTIO_PCI_CAP_ISR_CFG     → BAR0+0x3000
 *   0x78  VIRTIO_PCI_CAP_DEVICE_CFG  → BAR0+0x4000
 */
module pcie_ep_stub (
    input  logic        clk,
    input  logic        rst_n,
    /* TLP 请求接口 */
    input  logic        tlp_valid,
    input  logic [2:0]  tlp_type,
    input  logic [63:0] tlp_addr,
    input  logic [31:0] tlp_wdata,
    input  logic [15:0] tlp_len,
    input  logic [7:0]  tlp_tag,
    /* TLP 完成接口 */
    output logic        cpl_valid,
    output logic [7:0]  cpl_tag,
    output logic [31:0] cpl_rdata,
    output logic        cpl_status,  /* 0=成功 */
    /* Virtio notify event (Phase 3) */
    output logic        notify_valid,
    output logic [15:0] notify_queue,
    /* Phase 4: ISR set request from tb_top (RX injection) */
    input  logic        isr_set,
    /* Completion ack: deassert cpl_valid when consumer has latched it */
    input  logic        cpl_ack
);
    /* MAC 地址最后一字节 (通过 plusargs 配置, 区分不同实例) */
    int mac_last_byte_param;
    logic [7:0] mac_byte;

    /* ========== 通用寄存器文件 ========== */
    logic [31:0] regs [0:15];

    /* ========== TX NIC 模拟 ========== */
    logic [31:0] tx_buf [0:63];
    logic [31:0] tx_len;
    logic [31:0] tx_count;
    logic [31:0] tx_status;
    logic [31:0] tx_total_bytes;

    /* ========== DMA 测试寄存器 ========== */
    logic [31:0] dma_addr_lo;
    logic [31:0] dma_addr_hi;
    logic [31:0] dma_len;
    logic [31:0] dma_doorbell;
    logic [31:0] dma_status /* verilator public */;

    /* ========== PCI Config Space ========== */
    logic [31:0] cfg_space [0:63];
    wire [5:0] cfg_idx = tlp_addr[7:2];
    localparam [31:0] BAR0_SIZE_MASK = 32'hFFFF_0000;  /* 64KB */

    /* ========== Virtio-PCI 寄存器 ========== */
    /* Virtio 特性位 (设备支持) */
    localparam [31:0] VIRTIO_DEV_FEAT_LO = 32'h0001_0020;  /* MAC(5) + STATUS(16) */
    localparam [31:0] VIRTIO_DEV_FEAT_HI = 32'h0000_0001;  /* VERSION_1(bit 0 = feature bit 32) */

    /* common_cfg 寄存器 */
    logic [31:0] vio_dev_feat_sel;
    logic [31:0] vio_drv_feat_sel;
    logic [31:0] vio_drv_feat [0:1];
    logic [15:0] vio_msix_config;
    logic [7:0]  vio_dev_status;
    logic [7:0]  vio_config_gen;
    logic [15:0] vio_queue_sel;
    /* Per-queue state (2 queues: 0=RX, 1=TX) */
    logic [15:0] vio_q_size   [0:1];
    logic [15:0] vio_q_msix   [0:1];
    logic [15:0] vio_q_enable [0:1];
    logic [31:0] vio_q_desc_lo[0:1];
    logic [31:0] vio_q_desc_hi[0:1];
    logic [31:0] vio_q_drv_lo [0:1];
    logic [31:0] vio_q_drv_hi [0:1];
    logic [31:0] vio_q_dev_lo [0:1];
    logic [31:0] vio_q_dev_hi [0:1];

    /* ISR 寄存器 */
    logic [31:0] vio_isr;

    /* Virtio-net device config */
    logic [47:0] vio_mac;
    logic [15:0] vio_net_status;
    logic [15:0] vio_max_vq_pairs;

    /* 当前选中的 queue 索引 (截断到 0 或 1) */
    wire [0:0] qsel = vio_queue_sel[0];

    /* ========== 地址解码 ========== */
    wire [15:0] addr_offset = tlp_addr[15:0];
    wire [3:0]  reg_idx     = tlp_addr[5:2];
    wire [5:0]  txbuf_idx   = tlp_addr[7:2];
    wire [1:0]  byte_off    = tlp_addr[1:0];

    /* 旧测试寄存器区域 */
    wire is_gen_reg    = (addr_offset < 16'h040);
    wire is_tx_len     = (addr_offset == 16'h040);
    wire is_tx_door    = (addr_offset == 16'h044);
    wire is_tx_status  = (addr_offset == 16'h048);
    wire is_dma_addrlo = (addr_offset == 16'h050);
    wire is_dma_addrhi = (addr_offset == 16'h054);
    wire is_dma_len    = (addr_offset == 16'h058);
    wire is_dma_door   = (addr_offset == 16'h05C);
    wire is_dma_status = (addr_offset == 16'h060);
    wire is_tx_buf     = (addr_offset >= 16'h100) && (addr_offset < 16'h200);

    /* Virtio 区域 */
    wire is_vio_common = (addr_offset >= 16'h1000) && (addr_offset < 16'h1038);
    wire is_vio_notify = (addr_offset >= 16'h2000) && (addr_offset < 16'h2004);
    wire is_vio_isr    = (addr_offset >= 16'h3000) && (addr_offset < 16'h3004);
    wire is_vio_devcfg = (addr_offset >= 16'h4000) && (addr_offset < 16'h4010);
    wire [3:0] vio_common_dwoff = tlp_addr[5:2]; /* dword offset within common_cfg */
    wire [3:0] vio_devcfg_dwoff = tlp_addr[5:2]; /* dword offset within device_cfg */

    /* ========== Virtio common_cfg 读取辅助 ========== */
    /* 将 common_cfg dword 偏移映射到寄存器值 */
    function automatic logic [31:0] vio_common_read(input [3:0] dwoff, input [0:0] qs);
        case (dwoff)
            4'd0:  return vio_dev_feat_sel;
            4'd1:  return (vio_dev_feat_sel == 0) ? VIRTIO_DEV_FEAT_LO : VIRTIO_DEV_FEAT_HI;
            4'd2:  return vio_drv_feat_sel;
            4'd3:  return vio_drv_feat[vio_drv_feat_sel[0]];
            4'd4:  return {16'd2, vio_msix_config};           /* num_queues | msix_config */
            4'd5:  return {vio_queue_sel, vio_config_gen, vio_dev_status};
            4'd6:  return {vio_q_msix[qs], vio_q_size[qs]};
            4'd7:  return {qs, 15'd0, vio_q_enable[qs]};     /* notify_off | enable */
            4'd8:  return vio_q_desc_lo[qs];
            4'd9:  return vio_q_desc_hi[qs];
            4'd10: return vio_q_drv_lo[qs];
            4'd11: return vio_q_drv_hi[qs];
            4'd12: return vio_q_dev_lo[qs];
            4'd13: return vio_q_dev_hi[qs];
            default: return 32'h0;
        endcase
    endfunction

    /* ========== Virtio device_cfg 读取辅助 ========== */
    /* MMIO 小端序：byte[0] = dword[7:0], byte[1] = dword[15:8], ... */
    function automatic logic [31:0] vio_devcfg_read(input [3:0] dwoff);
        case (dwoff)
            4'd0: return {vio_mac[23:16], vio_mac[31:24], vio_mac[39:32], vio_mac[47:40]};
            4'd1: return {vio_net_status[15:8], vio_net_status[7:0], vio_mac[7:0], vio_mac[15:8]};
            4'd2: return {16'd0, vio_max_vq_pairs[7:0], vio_max_vq_pairs[15:8]};
            default: return 32'h0;
        endcase
    endfunction

    /* ========== TX 验证任务 ========== */
    task automatic verify_tx_packet;
        int pkt_words, errors, byte_count;
        logic [7:0] byte_val;

        pkt_words = (tx_len + 3) / 4;
        errors = 0;
        byte_count = tx_len;

        $display("[EP-NIC] ===== TX Packet #%0d =====", tx_count + 1);
        $display("[EP-NIC]   Length: %0d bytes (%0d words)", tx_len, pkt_words);
        $display("[EP-NIC]   Hex dump:");

        for (int i = 0; i < pkt_words && i < 64; i++) begin
            if (i < 8 || i == pkt_words - 1)
                $display("[EP-NIC]     [%02d] 0x%08h", i, tx_buf[i]);
            else if (i == 8)
                $display("[EP-NIC]     ... (%0d words total)", pkt_words);
        end

        for (int i = 0; i < pkt_words && i < 64; i++) begin
            for (int b = 0; b < 4; b++) begin
                if (i * 4 + b < byte_count) begin
                    byte_val = tx_buf[i][(b*8) +: 8];
                    if (byte_val != ((i * 4 + b) & 8'hFF)) begin
                        if (errors < 5)
                            $display("[EP-NIC]   MISMATCH at byte %0d: got 0x%02h, expect 0x%02h",
                                     i * 4 + b, byte_val, (i * 4 + b) & 8'hFF);
                        errors++;
                    end
                end
            end
        end

        if (errors == 0)
            $display("[EP-NIC]   Pattern verify: PASS (all %0d bytes correct)", byte_count);
        else
            $display("[EP-NIC]   Pattern verify: FAIL (%0d mismatches)", errors);
        $display("[EP-NIC] ==========================");
    endtask

    /* ========== 主逻辑 ========== */
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            /* --- 输出复位 --- */
            cpl_valid      <= 1'b0;
            cpl_tag        <= 8'd0;
            cpl_rdata      <= 32'd0;
            cpl_status     <= 1'b0;
            notify_valid   <= 1'b0;
            notify_queue   <= 16'd0;

            /* --- 旧测试寄存器复位 --- */
            tx_len         <= 32'd0;
            tx_count       <= 32'd0;
            tx_status      <= 32'd0;
            tx_total_bytes <= 32'd0;
            dma_addr_lo    <= 32'd0;
            dma_addr_hi    <= 32'd0;
            dma_len        <= 32'd0;
            dma_doorbell   <= 32'd0;
            for (int i = 0; i < 16; i++) regs[i]   <= 32'hDEAD_0000 + i;
            for (int i = 0; i < 64; i++) tx_buf[i]  <= 32'd0;

            /* --- Virtio 寄存器复位 --- */
            vio_dev_feat_sel <= 32'd0;
            vio_drv_feat_sel <= 32'd0;
            vio_drv_feat[0]  <= 32'd0;
            vio_drv_feat[1]  <= 32'd0;
            vio_msix_config  <= 16'hFFFF;
            vio_dev_status   <= 8'd0;
            vio_config_gen   <= 8'd0;
            vio_queue_sel    <= 16'd0;
            vio_isr          <= 32'd0;
            if (!$value$plusargs("MAC_LAST=%d", mac_last_byte_param))
                mac_last_byte_param = 1;
            mac_byte <= mac_last_byte_param[7:0];
            vio_mac  <= {8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h00, mac_last_byte_param[7:0]};
            vio_net_status   <= 16'h0001;   /* VIRTIO_NET_S_LINK_UP */
            vio_max_vq_pairs <= 16'd1;
            for (int q = 0; q < 2; q++) begin
                vio_q_size[q]    <= 16'd256;  /* 默认队列大小 */
                vio_q_msix[q]    <= 16'hFFFF;
                vio_q_enable[q]  <= 16'd0;
                vio_q_desc_lo[q] <= 32'd0;
                vio_q_desc_hi[q] <= 32'd0;
                vio_q_drv_lo[q]  <= 32'd0;
                vio_q_drv_hi[q]  <= 32'd0;
                vio_q_dev_lo[q]  <= 32'd0;
                vio_q_dev_hi[q]  <= 32'd0;
            end

            /* --- Config Space 初始化 --- */
            for (int i = 0; i < 64; i++) cfg_space[i] <= 32'd0;

            /* PCI Header */
            cfg_space[0]  <= {16'h1041, 16'h1AF4};     /* Device ID(virtio-net) | Vendor ID(virtio) */
            cfg_space[1]  <= {16'h0010, 16'h0007};     /* Status(cap_list=1) | Command */
            cfg_space[2]  <= {8'h02, 8'h00, 8'h00, 8'h01}; /* Class=0x020000 | Rev=0x01 */
            cfg_space[3]  <= 32'h0000_0010;             /* BIST|HdrType=0|LatTimer|CacheLine */
            cfg_space[11] <= {16'h0001, 16'h1AF4};     /* Subsystem ID(net) | Subsystem Vendor ID(virtio) */
            cfg_space[13] <= 32'h0000_0040;             /* Capabilities Pointer = 0x40 */
            cfg_space[15] <= 32'h0000_0100;             /* INT_PIN=INTA(1), INT_LINE=0(TBD by BIOS) */

            /* Virtio PCI Capability: COMMON_CFG at config offset 0x40 (16 bytes) */
            /* cfg_space[16]: {cfg_type=1, cap_len=0x10, cap_next=0x54, cap_vndr=0x09} */
            cfg_space[16] <= 32'h01_10_54_09;
            cfg_space[17] <= 32'h00_00_00_00;           /* bar=0 */
            cfg_space[18] <= 32'h0000_1000;             /* offset in BAR */
            cfg_space[19] <= 32'h0000_0038;             /* length = 56 */

            /* Virtio PCI Capability: NOTIFY_CFG at config offset 0x54 (20 bytes) */
            cfg_space[21] <= 32'h02_14_68_09;           /* cfg_type=2, len=0x14, next=0x68 */
            cfg_space[22] <= 32'h00_00_00_00;           /* bar=0 */
            cfg_space[23] <= 32'h0000_2000;             /* offset */
            cfg_space[24] <= 32'h0000_0004;             /* length */
            cfg_space[25] <= 32'h0000_0000;             /* notify_off_multiplier = 0 */

            /* Virtio PCI Capability: ISR_CFG at config offset 0x68 (16 bytes) */
            cfg_space[26] <= 32'h03_10_78_09;           /* cfg_type=3, len=0x10, next=0x78 */
            cfg_space[27] <= 32'h00_00_00_00;           /* bar=0 */
            cfg_space[28] <= 32'h0000_3000;             /* offset */
            cfg_space[29] <= 32'h0000_0004;             /* length */

            /* Virtio PCI Capability: DEVICE_CFG at config offset 0x78 (16 bytes) */
            cfg_space[30] <= 32'h04_10_00_09;           /* cfg_type=4, len=0x10, next=0 (end) */
            cfg_space[31] <= 32'h00_00_00_00;           /* bar=0 */
            cfg_space[32] <= 32'h0000_4000;             /* offset */
            cfg_space[33] <= 32'h0000_0010;             /* length = 16 */

        end else begin
            /* cpl_valid: hold until consumer acks (cpl_ack) or a new TLP
               arrives. This gives the glue's CPL FSM time to capture a
               completion without losing it to a single-cycle pulse race,
               while the ack handshake prevents re-latching duplicates. */
            if (tlp_valid || cpl_ack)
                cpl_valid <= 1'b0;
            notify_valid <= 1'b0;

            /* Phase 4: ISR set from tb_top RX injection */
            if (isr_set)
                vio_isr <= vio_isr | 32'd1;

            if (tlp_valid) begin
                case (tlp_type)
                    /* ===== MWr ===== */
                    3'd0: begin
                        if (is_gen_reg)
                            regs[reg_idx] <= tlp_wdata;
                        else if (is_tx_len)
                            tx_len <= tlp_wdata;
                        else if (is_tx_door) begin
                            verify_tx_packet();
                            tx_count      <= tx_count + 1;
                            tx_total_bytes <= tx_total_bytes + tx_len;
                            tx_status     <= 32'd1;
                        end
                        else if (is_dma_addrlo) dma_addr_lo  <= tlp_wdata;
                        else if (is_dma_addrhi) dma_addr_hi  <= tlp_wdata;
                        else if (is_dma_len)    dma_len      <= tlp_wdata;
                        else if (is_dma_door)   dma_doorbell <= tlp_wdata;
                        else if (is_tx_buf)     tx_buf[txbuf_idx] <= tlp_wdata;
                        /* --- Virtio common_cfg MWr --- */
                        else if (is_vio_common) begin
                            case (vio_common_dwoff)
                                4'd0: vio_dev_feat_sel <= tlp_wdata;
                                /* 4'd1: device_feature 只读 */
                                4'd2: vio_drv_feat_sel <= tlp_wdata;
                                4'd3: vio_drv_feat[vio_drv_feat_sel[0]] <= tlp_wdata;
                                4'd4: vio_msix_config <= tlp_wdata[15:0];
                                4'd5: begin
                                    /* Virtio common_cfg dword 5 布局：
                                     *   byte 0 = device_status (writeb)
                                     *   byte 1 = config_generation (driver 只读)
                                     *   byte 2-3 = queue_select (writew)
                                     * Linux virtio-pci modern 用 writeb/writew，但
                                     * 我们的 bridge+VIP codec 在 sub-DW 写时把 addr
                                     * 强制 DW 对齐 + payload pad 成 4 字节，bus 上
                                     * undefined bytes 导致 byte_off 和 BE 信息丢失。
                                     *
                                     * 启发式解码：
                                     *   writeb(status, 0x1014): tlp_wdata[7:0]=status
                                     *   writew(qsel,  0x1016): Linux 只把 qsel 放在
                                     *     bytes 2-3，但桥 codec 也可能放低 16 位或
                                     *     跨 byte_off 重组；因此：
                                     *     - byte_off==0 & tlp_wdata[31:16]!=0 认为是
                                     *       full-DW writel 里的 qsel 高 16 位
                                     *     - byte_off==2 时直接用 tlp_wdata[15:0]
                                     *   status write 时 tlp_wdata[31:16] 为 0 不更新
                                     *   qsel（Linux 初始化后 qsel 不会再置 0）。 */
                                    if (byte_off == 0) vio_dev_status <= tlp_wdata[7:0];
                                    if (byte_off == 2) vio_queue_sel  <= tlp_wdata[15:0];
                                    if (byte_off == 0 && tlp_wdata[31:16] != 16'h0)
                                        vio_queue_sel <= tlp_wdata[31:16];
                                end
                                4'd6: begin
                                    if (byte_off == 0) vio_q_size[qsel] <= tlp_wdata[15:0];
                                    if (byte_off == 2 || (byte_off == 0 && tlp_len >= 4))
                                        vio_q_msix[qsel] <= (byte_off == 2) ? tlp_wdata[15:0] : tlp_wdata[31:16];
                                end
                                4'd7: begin
                                    if (byte_off == 0) vio_q_enable[qsel] <= tlp_wdata[15:0];
                                end
                                4'd8:  vio_q_desc_lo[qsel] <= tlp_wdata;
                                4'd9:  vio_q_desc_hi[qsel] <= tlp_wdata;
                                4'd10: vio_q_drv_lo[qsel]  <= tlp_wdata;
                                4'd11: vio_q_drv_hi[qsel]  <= tlp_wdata;
                                4'd12: vio_q_dev_lo[qsel]  <= tlp_wdata;
                                4'd13: vio_q_dev_hi[qsel]  <= tlp_wdata;
                                default: ;
                            endcase
                            $display("[EP-VIO] common_cfg WR dwoff=%0d byte_off=%0d data=0x%08h status=0x%02h",
                                     vio_common_dwoff, byte_off, tlp_wdata, vio_dev_status);
                        end
                        /* --- Virtio notify MWr --- */
                        else if (is_vio_notify) begin
                            $display("[EP-VIO] NOTIFY queue=%0d", tlp_wdata[15:0]);
                            notify_valid <= 1'b1;
                            notify_queue <= tlp_wdata[15:0];
                        end
                    end

                    /* ===== MRd ===== */
                    3'd1: begin
                        cpl_valid  <= 1'b1;
                        cpl_tag    <= tlp_tag;
                        cpl_status <= 1'b0;

                        if (is_gen_reg)          cpl_rdata <= regs[reg_idx];
                        else if (is_tx_len)      cpl_rdata <= tx_len;
                        else if (is_tx_door)     cpl_rdata <= tx_count;
                        else if (is_tx_status)   cpl_rdata <= tx_status;
                        else if (is_dma_addrlo)  cpl_rdata <= dma_addr_lo;
                        else if (is_dma_addrhi)  cpl_rdata <= dma_addr_hi;
                        else if (is_dma_len)     cpl_rdata <= dma_len;
                        else if (is_dma_door)    cpl_rdata <= dma_doorbell;
                        else if (is_dma_status)  cpl_rdata <= dma_status;
                        else if (is_tx_buf)      cpl_rdata <= tx_buf[txbuf_idx];
                        /* --- Virtio common_cfg MRd (带字节偏移) --- */
                        else if (is_vio_common) begin
                            logic [31:0] raw;
                            raw = vio_common_read(vio_common_dwoff, qsel);
                            cpl_rdata <= raw >> ({3'b0, byte_off} * 8);
                        end
                        /* --- Virtio ISR MRd (read-clear) --- */
                        else if (is_vio_isr) begin
                            $display("[EP-ISR] ISR read: value=0x%08h (returning to guest)", vio_isr);
                            cpl_rdata <= vio_isr;
                            vio_isr   <= 32'd0;
                        end
                        /* --- Virtio device_cfg MRd --- */
                        else if (is_vio_devcfg) begin
                            logic [31:0] raw;
                            raw = vio_devcfg_read(vio_devcfg_dwoff);
                            cpl_rdata <= raw >> ({3'b0, byte_off} * 8);
                        end
                        else cpl_rdata <= 32'hBAD_ACC55;
                    end

                    /* ===== CfgWr ===== */
                    /* PCIe CfgWr is non-posted; must return a Cpl (no data).
                       The glue layer always emits CplD format; cpl_rdata is
                       ignored by the requester for config writes. */
                    3'd2: begin
                        if (tlp_addr[7:0] < 8'hFF) begin
                            logic [31:0] old_val, new_val, final_val;
                            logic [1:0] boff;
                            old_val = cfg_space[cfg_idx];
                            boff = tlp_addr[1:0];
                            new_val = old_val;
                            for (int b = 0; b < 4; b++) begin
                                if (b >= boff && b < boff + tlp_len[2:0])
                                    new_val[(b*8) +: 8] = tlp_wdata[((b - boff)*8) +: 8];
                            end
                            if (cfg_idx == 6'd4)
                                final_val = new_val & BAR0_SIZE_MASK;
                            else if (cfg_idx >= 6'd5 && cfg_idx <= 6'd9)
                                final_val = 32'd0;  /* BAR1-5 不使用，返回 0 */
                            else
                                final_val = new_val;
                            cfg_space[cfg_idx] <= final_val;
                            $display("[EP-CFG] CfgWr reg[0x%02h] byte_off=%0d len=%0d: 0x%08h -> 0x%08h",
                                     tlp_addr[7:0], boff, tlp_len, old_val, final_val);
                        end
                        cpl_valid  <= 1'b1;
                        cpl_tag    <= tlp_tag;
                        cpl_rdata  <= 32'd0;
                        cpl_status <= 1'b0;
                    end

                    /* ===== CfgRd ===== */
                    3'd3: begin
                        cpl_valid  <= 1'b1;
                        cpl_tag    <= tlp_tag;
                        cpl_status <= 1'b0;
                        if (tlp_addr[7:0] < 8'hFF)
                            cpl_rdata <= cfg_space[cfg_idx];
                        else
                            cpl_rdata <= 32'hFFFF_FFFF;
                        $display("[EP-CFG] CfgRd reg[0x%02h]=0x%08h",
                                 tlp_addr[7:0], cfg_space[cfg_idx]);
                    end

                    default: begin
                        cpl_valid  <= 1'b1;
                        cpl_tag    <= tlp_tag;
                        cpl_rdata  <= 32'hFFFF_FFFF;
                        cpl_status <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule
