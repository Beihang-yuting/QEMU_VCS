/* cosim-platform/vcs-tb/tb_top.sv
 * 顶层 testbench：
 * 1. 时钟生成
 * 2. 初始化 DPI-C bridge (PCIe TLP) + ETH MAC
 * 3. 循环：poll TLP → 驱动 EP 桩 → 读取 completion → 回写 bridge
 * 4. TX doorbell → 转发 packet 到 ETH SHM
 */
`ifndef COSIM_VIP_MODE
`timescale 1ns/1ps

module tb_top;
    import cosim_bridge_pkg::*;

    /* 时钟与复位 */
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;  /* 100MHz, 10ns 周期 */

    /* TLP 接口信号 */
    logic        tlp_valid;
    logic [2:0]  tlp_type;
    logic [63:0] tlp_addr;
    logic [31:0] tlp_wdata;
    logic [15:0] tlp_len;
    logic [7:0]  tlp_tag;
    logic        cpl_valid;
    logic [7:0]  cpl_tag;
    logic [31:0] cpl_rdata;
    logic        cpl_status;
    /* Virtio notify event (Phase 3) */
    logic        notify_valid;
    logic [15:0] notify_queue;
    /* VQ configuration tracking */
    logic        vq_configured;
    /* Phase 4: ISR set request to EP stub */
    logic        isr_set;

    /* PCIe EP 桩实例 */
    pcie_ep_stub ep (
        .clk          (clk),
        .rst_n        (rst_n),
        .tlp_valid    (tlp_valid),
        .tlp_type     (tlp_type),
        .tlp_addr     (tlp_addr),
        .tlp_wdata    (tlp_wdata),
        .tlp_len      (tlp_len),
        .tlp_tag      (tlp_tag),
        .cpl_valid    (cpl_valid),
        .cpl_tag      (cpl_tag),
        .cpl_rdata    (cpl_rdata),
        .cpl_status   (cpl_status),
        .notify_valid (notify_valid),
        .notify_queue (notify_queue),
        .isr_set      (isr_set)
    );

    /* DPI-C 变量 */
    byte unsigned  dpi_tlp_type;
    longint unsigned dpi_addr;
    int unsigned   dpi_data[16];
    int            dpi_len;
    int            dpi_tag;
    int unsigned   cpl_data[16];

    /* SHM 和 Socket 路径（通过 plusargs 传入） */
    string shm_name;
    string sock_path;
    string eth_shm_name;
    int    eth_role;    /* 0=A (default), 1=B */
    int    eth_create;  /* 1=create SHM (default), 0=open existing */
    int    sim_timeout_ms; /* 仿真超时 (ms), 默认 200 */
    /* MAC 地址通过 EP stub 内部 plusargs (+MAC_LAST=N) 配置 */

    /* ETH 帧转发：doorbell 触发后，读 EP stub 的 tx_buf/tx_len 并发到 ETH SHM */
    task automatic forward_tx_to_eth();
        int pkt_len;
        int pkt_words;
        byte unsigned eth_buf[];

        /* 等一个时钟让 EP stub 完成 doorbell 处理 */
        @(posedge clk);

        pkt_len = ep.tx_len;
        if (pkt_len <= 0 || pkt_len > 256) begin
            $display("[TB-ETH] WARNING: invalid tx_len=%0d, skip ETH forward", pkt_len);
            return;
        end

        /* 从 EP stub tx_buf 拷贝到 DPI-C byte 数组 */
        eth_buf = new[pkt_len];
        pkt_words = (pkt_len + 3) / 4;
        for (int w = 0; w < pkt_words; w++) begin
            for (int b = 0; b < 4; b++) begin
                int idx = w * 4 + b;
                if (idx < pkt_len)
                    eth_buf[idx] = ep.tx_buf[w][(b*8) +: 8];
            end
        end

        /* 通过 DPI-C 发到 ETH SHM */
        begin
            int rc;
            rc = vcs_eth_mac_send_frame_dpi(eth_buf, pkt_len);
            if (rc == 0)
                $display("[TB-ETH] Forwarded %0d bytes to ETH SHM", pkt_len);
            else
                $display("[TB-ETH] ETH send failed (rc=%0d)", rc);
        end
    endtask

    /* DMA 测试：doorbell 触发后，执行同步 DMA 读/写 */
    task automatic handle_dma_doorbell();
        longint unsigned host_addr;
        int unsigned dma_data[16];
        int dma_bytes;
        int rc;

        /* 等一个时钟让 EP stub 完成寄存器写入 */
        @(posedge clk);

        host_addr = {ep.dma_addr_hi, ep.dma_addr_lo};
        dma_bytes = ep.dma_len;

        if (dma_bytes <= 0 || dma_bytes > 64) begin
            $display("[TB-DMA] WARNING: invalid dma_len=%0d", dma_bytes);
            ep.dma_status = 32'd2;  /* fail */
            return;
        end

        if (ep.dma_doorbell == 32'd1) begin
            /* DMA Read Test: read from guest memory, verify pattern */
            $display("[TB-DMA] DMA Read Test: addr=0x%016h len=%0d", host_addr, dma_bytes);

            rc = bridge_vcs_dma_read_sync(host_addr, dma_data, dma_bytes);
            if (rc != 0) begin
                $display("[TB-DMA]   DMA read FAILED (rc=%0d)", rc);
                ep.dma_status = 32'd2;
                return;
            end

            /* Verify pattern: byte[i] = 0xA0 + (i & 0x3F) */
            begin
                int errors;
                int words;
                errors = 0;
                words = (dma_bytes + 3) / 4;
                for (int w = 0; w < words && w < 16; w++) begin
                    for (int b = 0; b < 4; b++) begin
                        int idx;
                        logic [7:0] got, expect_val;
                        idx = w * 4 + b;
                        if (idx < dma_bytes) begin
                            got = dma_data[w][(b*8) +: 8];
                            expect_val = 8'hA0 + (idx & 8'h3F);
                            if (got !== expect_val) begin
                                if (errors < 5)
                                    $display("[TB-DMA]   MISMATCH byte[%0d]: got=0x%02h expect=0x%02h",
                                             idx, got, expect_val);
                                errors++;
                            end
                        end
                    end
                end
                if (errors == 0) begin
                    $display("[TB-DMA]   DMA Read: PASS (%0d bytes verified)", dma_bytes);
                    ep.dma_status = 32'd1;
                end else begin
                    $display("[TB-DMA]   DMA Read: FAIL (%0d mismatches)", errors);
                    ep.dma_status = 32'd2;
                end
            end

        end else if (ep.dma_doorbell == 32'd2) begin
            /* DMA Write Test: write pattern to guest memory */
            $display("[TB-DMA] DMA Write Test: addr=0x%016h len=%0d", host_addr, dma_bytes);

            /* Fill data with pattern: byte[i] = 0xB0 + (i & 0x3F) */
            begin
                int words;
                words = (dma_bytes + 3) / 4;
                for (int w = 0; w < words && w < 16; w++) begin
                    dma_data[w] = 0;
                    for (int b = 0; b < 4; b++) begin
                        int idx;
                        idx = w * 4 + b;
                        if (idx < dma_bytes)
                            dma_data[w][(b*8) +: 8] = 8'hB0 + (idx & 8'h3F);
                    end
                end
            end

            rc = bridge_vcs_dma_write_sync(host_addr, dma_data, dma_bytes);
            if (rc == 0) begin
                $display("[TB-DMA]   DMA Write: PASS (%0d bytes written)", dma_bytes);
                ep.dma_status = 32'd1;
            end else begin
                $display("[TB-DMA]   DMA Write: FAIL (rc=%0d)", rc);
                ep.dma_status = 32'd2;
            end

        end else begin
            $display("[TB-DMA] Unknown DMA doorbell value: %0d", ep.dma_doorbell);
            ep.dma_status = 32'd2;
        end
    endtask

    /* Phase 3: Configure virtqueue ring addresses from EP stub state */
    task automatic configure_vq_rings();
        for (int q = 0; q < 2; q++) begin
            longint unsigned desc_gpa, avail_gpa, used_gpa;
            int qsize;
            desc_gpa  = {ep.vio_q_desc_hi[q], ep.vio_q_desc_lo[q]};
            avail_gpa = {ep.vio_q_drv_hi[q],  ep.vio_q_drv_lo[q]};
            used_gpa  = {ep.vio_q_dev_hi[q],  ep.vio_q_dev_lo[q]};
            qsize     = ep.vio_q_size[q];
            $display("[TB-VQ] Configuring queue %0d: desc=0x%016h avail=0x%016h used=0x%016h size=%0d",
                     q, desc_gpa, avail_gpa, used_gpa, qsize);
            vcs_vq_configure(q, desc_gpa, avail_gpa, used_gpa, qsize);
        end
        vq_configured = 1;
        $display("[TB-VQ] Virtqueue rings configured");
    endtask

    /* Phase 3: Handle notify doorbell — process TX or RX queue */
    task automatic handle_vio_notify(input [15:0] queue_idx);
        int rc;
        if (!vq_configured) begin
            $display("[TB-VQ] WARNING: notify before VQ configured, configuring now");
            configure_vq_rings();
        end
        if (queue_idx == 16'd1) begin
            /* TX queue notify */
            rc = vcs_vq_process_tx();
            if (rc > 0)
                $display("[TB-VQ] TX notify: processed %0d packets", rc);
            else if (rc < 0)
                $display("[TB-VQ] TX notify: ERROR");
        end else if (queue_idx == 16'd0) begin
            /* RX queue notify — driver posted new RX buffers */
            $display("[TB-VQ] RX queue notify (new buffers available)");
        end else begin
            $display("[TB-VQ] Unknown queue notify: %0d", queue_idx);
        end
    endtask

    initial begin
        if (!$value$plusargs("SHM_NAME=%s", shm_name))
            shm_name = "/cosim0";
        if (!$value$plusargs("SOCK_PATH=%s", sock_path))
            sock_path = "/tmp/cosim.sock";
        if (!$value$plusargs("ETH_SHM=%s", eth_shm_name))
            eth_shm_name = "/cosim_eth0";
        if (!$value$plusargs("ETH_ROLE=%d", eth_role))
            eth_role = 0;    /* default: Role A */
        if (!$value$plusargs("ETH_CREATE=%d", eth_create))
            eth_create = 1;  /* default: create SHM */
        if (!$value$plusargs("SIM_TIMEOUT_MS=%d", sim_timeout_ms))
            sim_timeout_ms = 200;
        /* 复位 */
        tlp_valid = 0;
        ep.dma_status = 32'd0;
        vq_configured = 0;
        isr_set = 0;
        #100;
        rst_n = 1;
        #20;

        /* 初始化 PCIe Bridge */
        if (bridge_vcs_init(shm_name, sock_path) != 0) begin
            $display("[TB] ERROR: bridge_vcs_init failed");
            $finish;
        end
        $display("[TB] PCIe Bridge initialized");

        /* 初始化 ETH MAC (role 和 create 通过 plusargs 配置) */
        if (vcs_eth_mac_init_dpi(eth_shm_name, eth_role, eth_create) != 0) begin
            $display("[TB] ERROR: vcs_eth_mac_init_dpi failed");
            $finish;
        end
        $display("[TB] ETH MAC initialized (shm=%s, role=%s, create=%0d)",
                 eth_shm_name, (eth_role == 0) ? "A" : "B", eth_create);
        $display("[TB] Waiting for TLPs...");

        /* 主循环：轮询 TLP 并处理 */
        forever begin
            int ret;
            ret = bridge_vcs_poll_tlp(dpi_tlp_type, dpi_addr, dpi_data, dpi_len, dpi_tag);

            if (ret < 0) begin
                $display("[TB] Bridge error or shutdown, exiting");
                break;
            end

            if (ret == 0) begin
                /* 收到 TLP，驱动 EP */
                @(posedge clk);
                tlp_valid <= 1;
                tlp_type  <= dpi_tlp_type[2:0];
                tlp_addr  <= dpi_addr;
                tlp_wdata <= dpi_data[0];
                tlp_len   <= dpi_len[15:0];
                tlp_tag   <= dpi_tag[7:0];

                @(posedge clk);
                tlp_valid <= 0;

                /* MRd / CfgRd: 等待 EP 响应 completion */
                if (dpi_tlp_type == TLP_MRD || dpi_tlp_type == TLP_CFGRD) begin
                    @(posedge clk);
                    if (cpl_valid) begin
                        cpl_data[0] = cpl_rdata;
                        for (int i = 1; i < 16; i++) cpl_data[i] = 0;
                        ret = bridge_vcs_send_completion(
                            int'(cpl_tag), cpl_data, 4);
                        if (ret < 0)
                            $display("[TB] ERROR: send_completion failed");
                    end

                    /* Phase 4: ISR read-clear -> deassert INTx on QEMU side */
                    if (dpi_tlp_type == TLP_MRD && dpi_addr[15:0] == 16'h3000) begin
                        $display("[TB-ISR] ISR read completion: cpl_valid=%0d cpl_rdata=0x%08h",
                                 cpl_valid, cpl_rdata);
                        begin
                            int msi_rc;
                            msi_rc = bridge_vcs_raise_msi(16'hFFFE);
                        end
                    end
                end

                /* MWr to TX_DOORBELL (0x44): 转发 packet 到 ETH SHM */
                if (dpi_tlp_type == TLP_MWR && dpi_addr[11:0] == 12'h044) begin
                    forward_tx_to_eth();
                end

                /* MWr to DMA_STATUS (0x60): guest resets status */
                if (dpi_tlp_type == TLP_MWR && dpi_addr[11:0] == 12'h060) begin
                    ep.dma_status = dpi_data[0];
                end

                /* MWr to DMA_DOORBELL (0x5C): 执行 DMA 测试 */
                if (dpi_tlp_type == TLP_MWR && dpi_addr[11:0] == 12'h05C) begin
                    handle_dma_doorbell();
                end

                /* Phase 3: Detect DRIVER_OK (status bit 2 set) → configure VQ rings */
                if (dpi_tlp_type == TLP_MWR && dpi_addr[15:0] == 16'h1014) begin
                    /* common_cfg offset 0x14 = device_status (byte write) */
                    if ((dpi_data[0] & 8'h04) && !vq_configured) begin
                        $display("[TB-VQ] DRIVER_OK detected, configuring VQ rings");
                        configure_vq_rings();
                    end
                end

                /* Phase 3: Handle virtio notify doorbell
                 * Wait one extra clock for NBA to propagate notify_valid */
                @(posedge clk);
                if (notify_valid) begin
                    handle_vio_notify(notify_queue);
                end

                $display("[TB] Processed TLP: type=%0d addr=0x%016h data=0x%08h",
                         dpi_tlp_type, dpi_addr, dpi_data[0]);
            end

            /* Phase 3/4: Poll ETH SHM for incoming RX frames (non-blocking) */
            if (vq_configured) begin
                int rx_rc;
                rx_rc = vcs_vq_process_rx();
                /* rx_rc > 0 means a frame was injected — set ISR bit for interrupt */
                if (rx_rc > 0) begin
                    /* Step 1: Set ISR bit in EP stub FIRST */
                    isr_set <= 1;
                    @(posedge clk);
                    isr_set <= 0;
                    @(posedge clk);  /* ensure ISR is latched */

                    /* Step 2: NOW raise interrupt to QEMU (ISR is already set) */
                    begin
                        int msi_rc;
                        msi_rc = bridge_vcs_raise_msi(0);
                    end
                end
            end
        end

        vcs_eth_mac_close_dpi();
        bridge_vcs_cleanup();
        $finish;
    end

    /* 超时保护 (通过 +SIM_TIMEOUT_MS=N 配置) */
    initial begin
        int timeout_ns;
        if (!$value$plusargs("SIM_TIMEOUT_MS=%d", timeout_ns))
            timeout_ns = 200;
        /* 将 ms 转换为 ns 并等待 */
        repeat (timeout_ns) #1_000_000;
        $display("[TB] TIMEOUT after %0d ms", timeout_ns);
        $finish;
    end

endmodule
`endif /* !COSIM_VIP_MODE */
