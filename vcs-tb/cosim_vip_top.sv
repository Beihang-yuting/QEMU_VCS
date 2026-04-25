/* cosim-platform/vcs-tb/cosim_vip_top.sv
 * VIP 模式顶层模块
 * - 例化 pcie_tl_if (RC 侧)
 * - 例化 glue_if_to_stub
 * - 例化 pcie_ep_stub (复用)
 * - 时钟/复位生成
 * - DPI-C bridge 初始化
 * - uvm_config_db 设置 virtual interface
 * - 启动 UVM test
 */
`timescale 1ns/1ps

module cosim_vip_top;
    import uvm_pkg::*;
    import pcie_tl_pkg::*;
    import cosim_bridge_pkg::*;
    import cosim_pkg::*;

    /* === 时钟与复位 === */
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;  /* 100MHz */

    /* === pcie_tl_if: RC 侧请求接口 === */
    pcie_tl_if rc_if(.clk(clk), .rst_n(rst_n));

    /* === pcie_tl_if: completion 回传接口 (glue → driver) === */
    pcie_tl_if cpl_if(.clk(clk), .rst_n(rst_n));

    /* === EP stub 信号 === */
    logic        stub_tlp_valid;
    logic [2:0]  stub_tlp_type;
    logic [63:0] stub_tlp_addr;
    logic [31:0] stub_tlp_wdata;
    logic [15:0] stub_tlp_len;
    logic [7:0]  stub_tlp_tag;
    logic [3:0]  stub_first_be;
    logic [2:0]  stub_bar_index;
    logic        stub_cpl_valid;
    logic [7:0]  stub_cpl_tag;
    logic [31:0] stub_cpl_rdata;
    logic        stub_cpl_status;
    logic        stub_cpl_ack;
    logic        stub_notify_valid;
    logic [15:0] stub_notify_queue;
    logic        stub_isr_set;

    /* === BAR base addresses (from DPI-C, updated by cosim_rc_driver bypass) === */
    logic [63:0] bar_base_regs [0:5];
    always_ff @(posedge clk) begin
        for (int i = 0; i < 6; i++)
            bar_base_regs[i] <= bridge_vcs_get_bar_base(i);
    end

    /* === Glue 层 === */
    glue_if_to_stub glue (
        .clk             (clk),
        .rst_n           (rst_n),
        /* VIP 侧 - 请求通道 */
        .vip_tlp_data    (rc_if.tlp_data),
        .vip_tlp_strb    (rc_if.tlp_strb),
        .vip_tlp_valid   (rc_if.tlp_valid),
        .vip_tlp_ready   (rc_if.tlp_ready),
        .vip_tlp_sop     (rc_if.tlp_sop),
        .vip_tlp_eop     (rc_if.tlp_eop),
        .vip_tlp_error   (rc_if.tlp_error),
        /* VIP 侧 - FC credit */
        .vip_ph_credit   (rc_if.ph_credit),
        .vip_pd_credit   (rc_if.pd_credit),
        .vip_nph_credit  (rc_if.nph_credit),
        .vip_npd_credit  (rc_if.npd_credit),
        .vip_cplh_credit (rc_if.cplh_credit),
        .vip_cpld_credit (rc_if.cpld_credit),
        .vip_fc_update   (rc_if.fc_update),
        /* VIP 侧 - completion 回传 */
        .vip_cpl_data    (cpl_if.tlp_data),
        .vip_cpl_strb    (cpl_if.tlp_strb),
        .vip_cpl_valid   (cpl_if.tlp_valid),
        .vip_cpl_ready   (cpl_if.tlp_ready),
        .vip_cpl_sop     (cpl_if.tlp_sop),
        .vip_cpl_eop     (cpl_if.tlp_eop),
        /* BAR base 输入 */
        .bar_base        (bar_base_regs),
        /* Stub 侧 */
        .stub_tlp_valid  (stub_tlp_valid),
        .stub_tlp_type   (stub_tlp_type),
        .stub_tlp_addr   (stub_tlp_addr),
        .stub_tlp_wdata  (stub_tlp_wdata),
        .stub_tlp_len    (stub_tlp_len),
        .stub_tlp_tag    (stub_tlp_tag),
        .stub_first_be   (stub_first_be),
        .stub_bar_index  (stub_bar_index),
        .stub_cpl_valid  (stub_cpl_valid),
        .stub_cpl_tag    (stub_cpl_tag),
        .stub_cpl_rdata  (stub_cpl_rdata),
        .stub_cpl_status (stub_cpl_status),
        .stub_cpl_ack    (stub_cpl_ack),
        .stub_notify_valid (stub_notify_valid),
        .stub_notify_queue (stub_notify_queue),
        .stub_isr_set    (stub_isr_set)
    );

    /* === EP stub 实例 === */
    pcie_ep_stub ep (
        .clk          (clk),
        .rst_n        (rst_n),
        .tlp_valid    (stub_tlp_valid),
        .tlp_type     (stub_tlp_type),
        .tlp_addr     (stub_tlp_addr),
        .tlp_wdata    (stub_tlp_wdata),
        .tlp_len      (stub_tlp_len),
        .tlp_tag      (stub_tlp_tag),
        .first_be     (stub_first_be),
        .bar_index    (stub_bar_index),
        .cpl_valid    (stub_cpl_valid),
        .cpl_tag      (stub_cpl_tag),
        .cpl_rdata    (stub_cpl_rdata),
        .cpl_status   (stub_cpl_status),
        .notify_valid (stub_notify_valid),
        .notify_queue (stub_notify_queue),
        .isr_set      (stub_isr_set),
        .cpl_ack      (stub_cpl_ack)
    );

    /* === cpl_if slave-side defaults (driver controls ready via VIF) === */
    assign cpl_if.tlp_ready = 1'b1;
    assign cpl_if.tlp_error = 1'b0;
    /* cpl_if credit/error signals unused for completion direction */
    assign cpl_if.ph_credit   = 8'h0;
    assign cpl_if.pd_credit   = 12'h0;
    assign cpl_if.nph_credit  = 8'h0;
    assign cpl_if.npd_credit  = 12'h0;
    assign cpl_if.cplh_credit = 8'h0;
    assign cpl_if.cpld_credit = 12'h0;
    assign cpl_if.fc_update   = 1'b0;

    /* === DPI-C bridge 初始化 + UVM 启动 === */
    string shm_name;
    string sock_path;

    /* Reset release */
    initial begin
        #100;
        rst_n = 1;
    end

    /* === 波形 dump（默认开启，+NO_WAVE 关闭）===
     * 输出 FSDB 格式（Verdi 可直接打开），包含完整 TLP 信号 */
    initial begin
        string wave_file;
        if (!$test$plusargs("NO_WAVE")) begin
            if (!$value$plusargs("WAVE_FILE=%s", wave_file))
                wave_file = "cosim_wave.fsdb";
            $fsdbDumpfile(wave_file);
            $fsdbDumpvars(0, cosim_vip_top);
            $fsdbDumpvars(0, cosim_vip_top.ep);
            $fsdbDumpvars(0, cosim_vip_top.glue);
            $display("[WAVE] Dumping waveform to %s (use +NO_WAVE to disable)", wave_file);
        end
    end

    /* UVM must start at time 0 — config_db::set + run_test in a zero-delay block.
     * Bridge init is deferred to cosim_test::run_phase (after reset). */
    initial begin
        if (!$value$plusargs("SHM_NAME=%s", shm_name))
            shm_name = "/cosim0";
        if (!$value$plusargs("SOCK_PATH=%s", sock_path))
            sock_path = "/tmp/cosim.sock";

        uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top.env.rc_adapter", "vif", rc_if);
        uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top.env.rc_agent*", "vif", rc_if);
        uvm_config_db#(virtual pcie_tl_if)::set(null, "uvm_test_top.env.rc_agent*", "cpl_vif", cpl_if);
        uvm_config_db#(string)::set(null, "uvm_test_top", "shm_name", shm_name);
        uvm_config_db#(string)::set(null, "uvm_test_top", "sock_path", sock_path);

        run_test("cosim_test");
    end

    /* === 超时保护 === */
    initial begin
        int timeout_ms;
        if (!$value$plusargs("SIM_TIMEOUT_MS=%d", timeout_ms))
            timeout_ms = 200;
        repeat (timeout_ms) #1_000_000;
        $display("[VIP-TOP] TIMEOUT after %0d ms", timeout_ms);
        $finish;
    end

    /* ============================================================
     * 软件模拟 virtio → ETH SHM 数据面（默认）
     * ------------------------------------------------------------
     * Guest virtio-net driver 通过 common_cfg 配置好 queue 地址并写
     * device_status=DRIVER_OK 后，会对 BAR0+0x2000 发 NOTIFY。stub
     * 拉起 notify_valid，此处 edge-detect → 调 DPI-C virtqueue_dma.c
     * 的真实 TX/RX 处理，配合 eth_mac_dpi.c 把数据搬到 ETH SHM；RX
     * 侧周期 poll ETH SHM → DMA-write guest buffer → raise MSI。
     *
     * 真实 virtio IP 上板后 +define+COSIM_VIRTIO_REAL_IP 绕过整段。
     * ============================================================ */
`ifndef COSIM_VIRTIO_REAL_IP
    string eth_shm_name;
    int    eth_role;
    int    eth_create;
    logic  vq_configured_q = 1'b0;
    logic  stub_notify_valid_q = 1'b0;

    task automatic configure_vq_rings();
        for (int q = 0; q < 2; q++) begin
            longint unsigned desc_gpa, avail_gpa, used_gpa;
            int qsize;
            desc_gpa  = {ep.vio_q_desc_hi[q], ep.vio_q_desc_lo[q]};
            avail_gpa = {ep.vio_q_drv_hi[q],  ep.vio_q_drv_lo[q]};
            used_gpa  = {ep.vio_q_dev_hi[q],  ep.vio_q_dev_lo[q]};
            qsize     = ep.vio_q_size[q];
            $display("[VIP-VQ] Configuring queue %0d: desc=0x%016h avail=0x%016h used=0x%016h size=%0d",
                     q, desc_gpa, avail_gpa, used_gpa, qsize);
            vcs_vq_configure(q, desc_gpa, avail_gpa, used_gpa, qsize);
        end
        vq_configured_q <= 1'b1;
        $display("[VIP-VQ] Virtqueue rings configured");
    endtask

    task automatic handle_vio_notify(input [15:0] queue_idx);
        int rc;
        /* Guest 可能在 soft-reset 后重新配 vring 到新地址，因此每次 notify 都
         * 重读 ep 里的 vio_q_*_hi/lo 调 vcs_vq_configure。C 侧 vcs_vq_configure
         * 已幂等化——若 GPA 不变则是 no-op，不会清 ring 位置。 */
        configure_vq_rings();
        if (queue_idx == 16'd1) begin
            rc = vcs_vq_process_tx();
            if (rc > 0)
                $display("[VIP-VQ] TX notify: processed %0d packets (total=%0d)",
                         rc, vcs_vq_get_tx_count());
            else if (rc < 0)
                $display("[VIP-VQ] TX notify: ERROR");
        end else if (queue_idx == 16'd0) begin
            $display("[VIP-VQ] RX queue notify (new buffers posted)");
        end else begin
            $display("[VIP-VQ] Unknown queue notify: %0d", queue_idx);
        end
    endtask

    /* ETH SHM 初始化 */
    initial begin
        if (!$value$plusargs("ETH_SHM=%s", eth_shm_name))
            eth_shm_name = "/cosim_eth0";
        if (!$value$plusargs("ETH_ROLE=%d", eth_role))
            eth_role = 0;  /* Role A (vs eth_tap_bridge Role B) */
        if (!$value$plusargs("ETH_CREATE=%d", eth_create))
            eth_create = 1;
        @(posedge rst_n);
        #20;
        if (vcs_eth_mac_init_dpi(eth_shm_name, eth_role, eth_create) != 0) begin
            $display("[VIP-TOP] WARNING: ETH MAC init failed (shm=%s role=%0d) — TX/RX disabled",
                     eth_shm_name, eth_role);
        end else begin
            $display("[VIP-TOP] ETH MAC initialized (shm=%s role=%0d create=%0d)",
                     eth_shm_name, eth_role, eth_create);
        end
    end

    /* NOTIFY 事件传递：always_ff 检测边沿并触发 event，
     * initial 块等待 event 并处理（可安全阻塞 DPI-C）。
     * 用 event + 独立变量避免 always_ff/initial 多驱动冲突。 */
    event        notify_event;
    logic [15:0] notify_event_queue;

    /* NOTE: notify_event_queue 必须用 blocking assignment（=），确保
     * -> notify_event 触发时 initial 块读到的是当前值而非上一拍的旧值。
     * 原 always_ff + NBA(<=) 导致 queue_idx 滞后一拍：第一次读到 X，
     * 后续每次读到上一次的 queue index，TX notify 被误判为 RX。 */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stub_notify_valid_q <= 1'b0;
        end else begin
            stub_notify_valid_q <= stub_notify_valid;
            if (stub_notify_valid && !stub_notify_valid_q) begin
                notify_event_queue = stub_notify_queue;  /* blocking: 先赋值 */
                -> notify_event;                         /* 再触发 event */
            end
        end
    end

    /* NOTIFY 处理循环：在 initial 块中等待 event，可安全调用阻塞 DPI-C */
    initial begin
        @(posedge rst_n);
        forever begin
            @(notify_event);
            handle_vio_notify(notify_event_queue);
        end
    end

    /* 周期性 RX poll：每 2us 从 ETH SHM 拿一帧注入 Guest RX vring */
    initial begin
        int rx_rc;
        @(posedge rst_n);
        #200;
        forever begin
            #2000;  /* 2us @ 1ns/1ps */
            if (vq_configured_q) begin
                rx_rc = vcs_vq_process_rx();
                if (rx_rc > 0) begin
                    $display("[VIP-VQ] RX injected %0d packets (total=%0d)",
                             rx_rc, vcs_vq_get_rx_count());
                    /* 先设 ISR bit，再发 MSI（顺序关键：Guest 读 ISR 必须非零） */
                    stub_isr_set <= 1;
                    @(posedge clk);
                    stub_isr_set <= 0;
                    @(posedge clk);
                    begin
                        int msi_rc;
                        msi_rc = bridge_vcs_raise_msi(0);
                        if (msi_rc < 0)
                            $display("[VIP-VQ] WARNING: raise_msi failed rc=%0d", msi_rc);
                    end
                end
            end
        end
    end
`endif  /* !COSIM_VIRTIO_REAL_IP */

    /* === INTx 去断言：Guest 读 ISR(0x3000) 后自动 deassert ===
     * INTx 是电平触发。VCS 注入 RX 后 pci_set_irq(1) 拉高中断线，
     * Guest 中断处理读 ISR → EP stub 清零 ISR → 中断条件消除。
     * 此时必须发 0xFFFE 去断言中断线，否则线持续高电平，后续
     * pci_set_irq(1) 无边沿变化，Guest 不再收到中断。
     * legacy 模式 (tb_top.sv) 已有此逻辑，VIP 模式此前遗漏。 */
    wire is_isr_read = stub_tlp_valid && (stub_tlp_type == 3'd1) &&
                       (stub_tlp_addr[15:0] >= 16'h3000) &&
                       (stub_tlp_addr[15:0] <  16'h3004);
    event isr_read_event;

    always @(posedge clk) begin
        if (rst_n && is_isr_read)
            -> isr_read_event;
    end

    initial begin
        @(posedge rst_n);
        forever begin
            @(isr_read_event);
            @(posedge clk);  /* 等 completion 传播 */
            @(posedge clk);
            begin
                int msi_rc;
                msi_rc = bridge_vcs_raise_msi(16'hFFFE);
            end
        end
    end

    /* === Virtio 数据面 TLP 计数提前终止 ===
     * 真正的 "virtio 发包" = Guest 驱动和 device 在 virtqueue 层交换数据时触
     * 发的 MMIO：
     *   0x2000-0x2003  NOTIFY     — Guest 按 vring 索引通知 device 有新描述符
     *   0x3000-0x3003  ISR_CFG    — Guest 读 ISR 处理 device 中断（被 deliver
     *                                的 RX/TX 完成事件）
     * common_cfg (0x1000..0x103F) 和 device_cfg (0x4000..) 是配置层，不算数据面。
     * STOP_AFTER_TLPS=0 时不启用，依赖 SIM_TIMEOUT_MS 兜底。 */
    int unsigned virtio_tlp_count = 0;
    int unsigned stop_after_tlps  = 0;

    wire is_mem_access      = (stub_tlp_type == 3'd0) || (stub_tlp_type == 3'd1);
    wire is_virtio_notify   = (stub_tlp_addr[15:0] >= 16'h2000) &&
                              (stub_tlp_addr[15:0] <  16'h2004);
    wire is_virtio_isr      = (stub_tlp_addr[15:0] >= 16'h3000) &&
                              (stub_tlp_addr[15:0] <  16'h3004);
    wire is_virtio_tlp      = stub_tlp_valid && is_mem_access &&
                              (is_virtio_notify || is_virtio_isr);

    initial begin
        if (!$value$plusargs("STOP_AFTER_TLPS=%d", stop_after_tlps))
            stop_after_tlps = 0;
        if (stop_after_tlps > 0)
            $display("[VIP-TOP] Early-stop enabled: $finish after %0d virtio TLPs (BAR0 0x1000-0x400F)",
                     stop_after_tlps);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            virtio_tlp_count <= 0;
        end else if (is_virtio_tlp) begin
            virtio_tlp_count <= virtio_tlp_count + 1;
            $display("[VIP-TOP] virtio-data TLP #%0d: kind=%s type=%0d addr=0x%04h t=%0t",
                     virtio_tlp_count + 1,
                     is_virtio_notify ? "NOTIFY" : "ISR",
                     stub_tlp_type, stub_tlp_addr[15:0], $time);
            if (stop_after_tlps > 0 && (virtio_tlp_count + 1) >= stop_after_tlps) begin
                $display("[VIP-TOP] Reached STOP_AFTER_TLPS=%0d virtio data-plane TLPs — $finish at time %0t",
                         stop_after_tlps, $time);
                $finish;
            end
        end
    end

endmodule
