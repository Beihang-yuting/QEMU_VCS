// =============================================================================
// 文件名: xilinx_pcie_cfg_sva.sv
// 描述: cfg_interrupt 边带的 PG213 时序 SVA checker
//
// 以 bind 方式挂到 xilinx_pcie_cfg_if:
//   bind xilinx_pcie_cfg_if xilinx_pcie_cfg_sva u_cfg_sva (.*);
// 端口名与接口内信号同名, .* 自动连接。
//
// 断言 (参考 PG213 cfg_interrupt 时序):
//   A_MSI_HANDSHAKE  : msi_int 断言后有限周期内必须收到 msi_sent 或 msi_fail
//   A_MSI_PENDING_STABLE : msi_int 在握手完成前保持稳定 (向量不变)
//   A_MSI_SENT_PULSE : msi_sent 为单拍脉冲
//   A_INTX_HANDSHAKE : cfg_interrupt_int 断言后有限周期内必须收到 sent
//   A_SENT_PULSE     : cfg_interrupt_sent 为单拍脉冲
//   A_MSIX_PULSE     : msix_int 为单拍脉冲 (PG213 要求)
//   A_MSIX_DATA_KNOWN: msix_int 有效当拍 address/data 必须已知 (非 X)
// =============================================================================
module xilinx_pcie_cfg_sva (
    input logic        clk,
    input logic        rst_n,
    // Legacy INTx
    input logic [3:0]  cfg_interrupt_int,
    input logic        cfg_interrupt_sent,
    // MSI
    input logic [31:0] cfg_interrupt_msi_int,
    input logic        cfg_interrupt_msi_sent,
    input logic        cfg_interrupt_msi_fail,
    input logic [31:0] cfg_interrupt_msi_data,
    // MSI-X
    input logic        cfg_interrupt_msix_int,
    input logic [63:0] cfg_interrupt_msix_address,
    input logic [31:0] cfg_interrupt_msix_data
);

    // 握手完成窗口上限 (响应模型 2 拍延迟, 留足裕量)
    localparam int HANDSHAKE_MAX = 64;

    // -------- MSI --------
    // msi_int 上升后, HANDSHAKE_MAX 周期内必须 sent 或 fail
    property p_msi_handshake;
        @(posedge clk) disable iff (!rst_n)
        $rose(|cfg_interrupt_msi_int) |->
            ##[1:HANDSHAKE_MAX] (cfg_interrupt_msi_sent || cfg_interrupt_msi_fail);
    endproperty
    A_MSI_HANDSHAKE: assert property (p_msi_handshake)
        else $error("[PG213-SVA] MSI: msi_int 断言后 %0d 周期内未收到 msi_sent/msi_fail", HANDSHAKE_MAX);

    // msi_int 向量从断言到首个 sent/fail 之间保持稳定 (握手后允许撤销)
    property p_msi_stable_until_sent;
        bit [31:0] v;
        @(posedge clk) disable iff (!rst_n)
        ($rose(|cfg_interrupt_msi_int), v = cfg_interrupt_msi_int) |->
            (cfg_interrupt_msi_int == v)
                throughout (cfg_interrupt_msi_sent || cfg_interrupt_msi_fail)[->1];
    endproperty
    A_MSI_STABLE_UNTIL_SENT: assert property (p_msi_stable_until_sent)
        else $error("[PG213-SVA] MSI: 握手完成前 msi_int 向量发生变化");

    // msi_sent 单拍脉冲
    property p_msi_sent_pulse;
        @(posedge clk) disable iff (!rst_n)
        cfg_interrupt_msi_sent |=> !cfg_interrupt_msi_sent;
    endproperty
    A_MSI_SENT_PULSE: assert property (p_msi_sent_pulse)
        else $error("[PG213-SVA] MSI: msi_sent 不是单拍脉冲");

    // -------- Legacy INTx --------
    property p_intx_handshake;
        @(posedge clk) disable iff (!rst_n)
        $rose(|cfg_interrupt_int) |-> ##[1:HANDSHAKE_MAX] cfg_interrupt_sent;
    endproperty
    A_INTX_HANDSHAKE: assert property (p_intx_handshake)
        else $error("[PG213-SVA] INTx: cfg_interrupt_int 断言后 %0d 周期内未收到 sent", HANDSHAKE_MAX);

    property p_sent_pulse;
        @(posedge clk) disable iff (!rst_n)
        cfg_interrupt_sent |=> !cfg_interrupt_sent;
    endproperty
    A_SENT_PULSE: assert property (p_sent_pulse)
        else $error("[PG213-SVA] INTx: cfg_interrupt_sent 不是单拍脉冲");

    // -------- MSI-X --------
    // msix_int 单拍脉冲
    property p_msix_pulse;
        @(posedge clk) disable iff (!rst_n)
        cfg_interrupt_msix_int |=> !cfg_interrupt_msix_int;
    endproperty
    A_MSIX_PULSE: assert property (p_msix_pulse)
        else $error("[PG213-SVA] MSI-X: msix_int 不是单拍脉冲");

    // msix_int 有效当拍 address/data 已知
    property p_msix_data_known;
        @(posedge clk) disable iff (!rst_n)
        cfg_interrupt_msix_int |->
            (!$isunknown(cfg_interrupt_msix_address) && !$isunknown(cfg_interrupt_msix_data));
    endproperty
    A_MSIX_DATA_KNOWN: assert property (p_msix_data_known)
        else $error("[PG213-SVA] MSI-X: msix_int 有效时 address/data 为 X");

endmodule : xilinx_pcie_cfg_sva
