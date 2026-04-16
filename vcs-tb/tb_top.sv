/* cosim-platform/vcs-tb/tb_top.sv
 * 顶层 testbench：
 * 1. 时钟生成
 * 2. 初始化 DPI-C bridge
 * 3. 循环：poll TLP → 驱动 EP 桩 → 读取 completion → 回写 bridge
 */
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

    /* PCIe EP 桩实例 */
    pcie_ep_stub ep (
        .clk       (clk),
        .rst_n     (rst_n),
        .tlp_valid (tlp_valid),
        .tlp_type  (tlp_type),
        .tlp_addr  (tlp_addr),
        .tlp_wdata (tlp_wdata),
        .tlp_len   (tlp_len),
        .tlp_tag   (tlp_tag),
        .cpl_valid (cpl_valid),
        .cpl_tag   (cpl_tag),
        .cpl_rdata (cpl_rdata),
        .cpl_status(cpl_status)
    );

    /* DPI-C 变量 */
    byte unsigned  dpi_tlp_type;
    longint unsigned dpi_addr;
    int unsigned   dpi_data[16];
    int            dpi_len;
    int unsigned   cpl_data[16];

    /* SHM 和 Socket 路径（通过 plusargs 传入） */
    string shm_name;
    string sock_path;

    initial begin
        if (!$value$plusargs("SHM_NAME=%s", shm_name))
            shm_name = "/cosim0";
        if (!$value$plusargs("SOCK_PATH=%s", sock_path))
            sock_path = "/tmp/cosim.sock";

        /* 复位 */
        tlp_valid = 0;
        #100;
        rst_n = 1;
        #20;

        /* 初始化 Bridge */
        if (bridge_vcs_init(shm_name, sock_path) != 0) begin
            $display("[TB] ERROR: bridge_vcs_init failed");
            $finish;
        end
        $display("[TB] Bridge initialized, waiting for TLPs...");

        /* 主循环：轮询 TLP 并处理 */
        forever begin
            int ret;
            ret = bridge_vcs_poll_tlp(dpi_tlp_type, dpi_addr, dpi_data, dpi_len);

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
                tlp_tag   <= dpi_data[0][7:0]; /* tag 从 bridge 层管理 */

                @(posedge clk);
                tlp_valid <= 0;

                /* 等待 EP 响应（MRd 需要 completion） */
                if (dpi_tlp_type == TLP_MRD) begin
                    @(posedge clk);  /* 等一个周期让 EP 输出 */
                    if (cpl_valid) begin
                        cpl_data[0] = cpl_rdata;
                        for (int i = 1; i < 16; i++) cpl_data[i] = 0;
                        ret = bridge_vcs_send_completion(
                            int'(cpl_tag), cpl_data, 4);
                        if (ret < 0)
                            $display("[TB] ERROR: send_completion failed");
                    end
                end

                $display("[TB] Processed TLP: type=%0d addr=0x%016h data=0x%08h",
                         dpi_tlp_type, dpi_addr, dpi_data[0]);
            end
        end

        bridge_vcs_cleanup();
        $finish;
    end

    /* 超时保护 */
    initial begin
        #10_000_000;  /* 10ms 超时 */
        $display("[TB] TIMEOUT");
        $finish;
    end

endmodule
