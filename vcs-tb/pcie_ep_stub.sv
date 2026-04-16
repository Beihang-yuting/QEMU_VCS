/* cosim-platform/vcs-tb/pcie_ep_stub.sv
 * 简单的 PCIe EP 桩：接收 TLP 请求，返回寄存器数据
 * P1 阶段用于验证 BAR 读写通路
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
    output logic        cpl_status  /* 0=成功 */
);

    /* 内部寄存器文件：16 个 32-bit 寄存器 */
    logic [31:0] regs [0:15];

    /* 寄存器地址解码：使用 addr[5:2] 索引 */
    wire [3:0] reg_idx = tlp_addr[5:2];

    /* 初始化寄存器 */
    initial begin
        for (int i = 0; i < 16; i++) begin
            regs[i] = 32'hDEAD_0000 + i;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpl_valid  <= 1'b0;
            cpl_tag    <= 8'd0;
            cpl_rdata  <= 32'd0;
            cpl_status <= 1'b0;
        end else begin
            cpl_valid <= 1'b0;  /* 默认无输出 */

            if (tlp_valid) begin
                case (tlp_type)
                    3'd0: begin  /* MWr: 写寄存器 */
                        regs[reg_idx] <= tlp_wdata;
                    end
                    3'd1: begin  /* MRd: 读寄存器 */
                        cpl_valid  <= 1'b1;
                        cpl_tag    <= tlp_tag;
                        cpl_rdata  <= regs[reg_idx];
                        cpl_status <= 1'b0;
                    end
                    default: begin
                        cpl_valid  <= 1'b1;
                        cpl_tag    <= tlp_tag;
                        cpl_rdata  <= 32'hFFFF_FFFF;
                        cpl_status <= 1'b1;  /* 不支持的类型 */
                    end
                endcase
            end
        end
    end

endmodule
