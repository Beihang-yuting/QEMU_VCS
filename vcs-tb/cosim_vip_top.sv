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
    logic        stub_cpl_valid;
    logic [7:0]  stub_cpl_tag;
    logic [31:0] stub_cpl_rdata;
    logic        stub_cpl_status;
    logic        stub_cpl_ack;
    logic        stub_notify_valid;
    logic [15:0] stub_notify_queue;
    logic        stub_isr_set;

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
        /* VIP 侧 - completion 回传 (通过 cpl_if 走 VIP 链路) */
        .vip_cpl_data    (cpl_if.tlp_data),
        .vip_cpl_strb    (cpl_if.tlp_strb),
        .vip_cpl_valid   (cpl_if.tlp_valid),
        .vip_cpl_ready   (cpl_if.tlp_ready),
        .vip_cpl_sop     (cpl_if.tlp_sop),
        .vip_cpl_eop     (cpl_if.tlp_eop),
        /* Stub 侧 */
        .stub_tlp_valid  (stub_tlp_valid),
        .stub_tlp_type   (stub_tlp_type),
        .stub_tlp_addr   (stub_tlp_addr),
        .stub_tlp_wdata  (stub_tlp_wdata),
        .stub_tlp_len    (stub_tlp_len),
        .stub_tlp_tag    (stub_tlp_tag),
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
