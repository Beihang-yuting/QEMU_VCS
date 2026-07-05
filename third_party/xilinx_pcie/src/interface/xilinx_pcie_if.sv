// =============================================================================
// 文件名: xilinx_pcie_if.sv
// 描述: Xilinx PCIe AXI4-Stream 4通道接口定义 (参考 PG213)
//
// 4个通道:
//   RQ  - Requester Request  : EP发送请求到PCIe核心
//   RC  - Requester Completion: PCIe核心返回完成给EP
//   CQ  - Completer Request  : PCIe核心转发请求给EP
//   CC  - Completer Completion: EP发送完成给PCIe核心
//
// KEEP_WIDTH = DATA_WIDTH / 32 (per-DW粒度, 非per-byte, 符合PG213规范)
// =============================================================================

interface xilinx_pcie_if #(
  parameter int DATA_WIDTH      = 256,   // AXI数据位宽, 典型值: 64/128/256/512
  parameter int RQ_TUSER_WIDTH  = 137,   // RQ通道tuser位宽 (PG213 Table 2-35)
  parameter int RC_TUSER_WIDTH  = 161,   // RC通道tuser位宽 (PG213 Table 2-48)
  parameter int CQ_TUSER_WIDTH  = 183,   // CQ通道tuser位宽 (PG213 Table 2-52)
  parameter int CC_TUSER_WIDTH  = 81     // CC通道tuser位宽 (PG213 Table 2-42)
)(
  input logic clk,   // PCIe用户时钟 (user_clk)
  input logic rst_n  // 低电平有效复位
);

  // ---------------------------------------------------------------------------
  // 局部参数: 每DW一个keep位 (PG213规范, 非标准AXI per-byte)
  // ---------------------------------------------------------------------------
  localparam int KEEP_WIDTH = DATA_WIDTH / 32;

  // ===========================================================================
  // RQ通道 - Requester Request
  // EP -> PCIe IP: EP发起读/写请求
  // ===========================================================================
  logic [DATA_WIDTH-1:0]     rq_tdata;   // RQ请求数据
  logic [KEEP_WIDTH-1:0]     rq_tkeep;   // RQ数据有效字节(per-DW)
  logic                      rq_tlast;   // RQ包末尾指示
  logic                      rq_tvalid;  // RQ数据有效
  logic                      rq_tready;  // RQ接收就绪 (来自PCIe IP)
  logic [RQ_TUSER_WIDTH-1:0] rq_tuser;   // RQ用户信号 (地址偏移/字节使能等)

  // ===========================================================================
  // RC通道 - Requester Completion
  // PCIe IP -> EP: PCIe核心返回读完成/写完成给EP
  // ===========================================================================
  logic [DATA_WIDTH-1:0]     rc_tdata;   // RC完成数据
  logic [KEEP_WIDTH-1:0]     rc_tkeep;   // RC数据有效字节(per-DW)
  logic                      rc_tlast;   // RC包末尾指示
  logic                      rc_tvalid;  // RC数据有效
  logic                      rc_tready;  // RC接收就绪 (来自EP)
  logic [RC_TUSER_WIDTH-1:0] rc_tuser;   // RC用户信号 (完成状态/BE等)

  // ===========================================================================
  // CQ通道 - Completer Request
  // PCIe IP -> EP: PCIe核心转发外部主机请求给EP处理
  // ===========================================================================
  logic [DATA_WIDTH-1:0]     cq_tdata;   // CQ请求数据
  logic [KEEP_WIDTH-1:0]     cq_tkeep;   // CQ数据有效字节(per-DW)
  logic                      cq_tlast;   // CQ包末尾指示
  logic                      cq_tvalid;  // CQ数据有效
  logic                      cq_tready;  // CQ接收就绪 (来自EP用户逻辑)
  logic [CQ_TUSER_WIDTH-1:0] cq_tuser;   // CQ用户信号 (TPH/BE/pasid等)

  // ===========================================================================
  // CC通道 - Completer Completion
  // EP -> PCIe IP: EP向外部主机返回读完成/写完成
  // ===========================================================================
  logic [DATA_WIDTH-1:0]     cc_tdata;   // CC完成数据
  logic [KEEP_WIDTH-1:0]     cc_tkeep;   // CC数据有效字节(per-DW)
  logic                      cc_tlast;   // CC包末尾指示
  logic                      cc_tvalid;  // CC数据有效
  logic                      cc_tready;  // CC接收就绪 (来自PCIe IP)
  logic [CC_TUSER_WIDTH-1:0] cc_tuser;   // CC用户信号 (DWBEpresent等)

  // ===========================================================================
  // Clocking Block: ep_drv_cb
  // 用途: EP用户逻辑驱动/采样视角
  //   - 驱动 RQ 通道 (EP发起请求)
  //   - 采样 RC 通道 (EP接收完成)
  //   - 采样 CQ 通道 tdata/tkeep/tlast/tvalid/tuser (EP接收请求)
  //   - 驱动 CQ tready (EP反压控制)
  //   - 驱动 CC 通道 (EP返回完成)
  // ===========================================================================
  clocking ep_drv_cb @(posedge clk);
    // RQ: EP输出方向 — EP驱动请求到PCIe核心
    output rq_tdata;    // 输出: RQ请求数据
    output rq_tkeep;    // 输出: RQ数据有效(per-DW)
    output rq_tlast;    // 输出: RQ包末尾
    output rq_tvalid;   // 输出: RQ数据有效
    input  rq_tready;   // 输入: PCIe IP的RQ反压信号
    output rq_tuser;    // 输出: RQ用户边带信号

    // RC: EP输入方向 — EP接收PCIe核心返回的完成
    input  rc_tdata;    // 输入: RC完成数据
    input  rc_tkeep;    // 输入: RC数据有效(per-DW)
    input  rc_tlast;    // 输入: RC包末尾
    input  rc_tvalid;   // 输入: RC数据有效
    output rc_tready;   // 输出: EP对RC的反压(EP控制接收速率)
    input  rc_tuser;    // 输入: RC用户边带信号

    // CQ: EP输入方向 — EP接收外部主机请求
    input  cq_tdata;    // 输入: CQ请求数据
    input  cq_tkeep;    // 输入: CQ数据有效(per-DW)
    input  cq_tlast;    // 输入: CQ包末尾
    input  cq_tvalid;   // 输入: CQ数据有效
    output cq_tready;   // 输出: EP对CQ的反压
    input  cq_tuser;    // 输入: CQ用户边带信号

    // CC: EP输出方向 — EP向外部主机返回完成
    output cc_tdata;    // 输出: CC完成数据
    output cc_tkeep;    // 输出: CC数据有效(per-DW)
    output cc_tlast;    // 输出: CC包末尾
    output cc_tvalid;   // 输出: CC数据有效
    input  cc_tready;   // 输入: PCIe IP的CC反压信号
    output cc_tuser;    // 输出: CC用户边带信号
  endclocking

  // ===========================================================================
  // Clocking Block: rc_drv_cb
  // 用途: RC/PCIe IP仿真驱动视角 (BFM作为PCIe根复合体时使用)
  //   - 驱动 RC 通道 (模拟PCIe IP向EP返回完成)
  //   - 驱动 CQ 通道 (模拟PCIe IP向EP转发外部请求)
  //   - 采样 RQ 通道 (接收EP发出的请求)
  //   - 采样 CC 通道 (接收EP返回的完成)
  // ===========================================================================
  clocking rc_drv_cb @(posedge clk);
    // RC: PCIe IP输出方向 — 模拟PCIe IP向EP发送完成
    output rc_tdata;    // 输出: RC完成数据
    output rc_tkeep;    // 输出: RC数据有效(per-DW)
    output rc_tlast;    // 输出: RC包末尾
    output rc_tvalid;   // 输出: RC数据有效
    input  rc_tready;   // 输入: EP对RC的反压
    output rc_tuser;    // 输出: RC用户边带信号

    // CQ: PCIe IP输出方向 — 模拟PCIe IP向EP转发外部主机请求
    output cq_tdata;    // 输出: CQ请求数据
    output cq_tkeep;    // 输出: CQ数据有效(per-DW)
    output cq_tlast;    // 输出: CQ包末尾
    output cq_tvalid;   // 输出: CQ数据有效
    input  cq_tready;   // 输入: EP对CQ的反压
    output cq_tuser;    // 输出: CQ用户边带信号

    // RQ: PCIe IP输入方向 — 采样EP发出的请求
    input  rq_tdata;    // 输入: RQ请求数据
    input  rq_tkeep;    // 输入: RQ数据有效(per-DW)
    input  rq_tlast;    // 输入: RQ包末尾
    input  rq_tvalid;   // 输入: RQ数据有效
    output rq_tready;   // 输出: PCIe IP对RQ的反压
    input  rq_tuser;    // 输入: RQ用户边带信号

    // CC: PCIe IP输入方向 — 采样EP返回的完成
    input  cc_tdata;    // 输入: CC完成数据
    input  cc_tkeep;    // 输入: CC数据有效(per-DW)
    input  cc_tlast;    // 输入: CC包末尾
    input  cc_tvalid;   // 输入: CC数据有效
    output cc_tready;   // 输出: PCIe IP对CC的反压
    input  cc_tuser;    // 输入: CC用户边带信号
  endclocking

  // ===========================================================================
  // Clocking Block: mon_cb
  // 用途: 纯监测视角 — 所有信号均为输入, 用于被动监测/覆盖率收集
  // ===========================================================================
  clocking mon_cb @(posedge clk);
    // RQ通道全部采样
    input rq_tdata;     // 采样: RQ数据
    input rq_tkeep;     // 采样: RQ数据有效
    input rq_tlast;     // 采样: RQ包末尾
    input rq_tvalid;    // 采样: RQ有效
    input rq_tready;    // 采样: RQ就绪
    input rq_tuser;     // 采样: RQ用户信号

    // RC通道全部采样
    input rc_tdata;     // 采样: RC数据
    input rc_tkeep;     // 采样: RC数据有效
    input rc_tlast;     // 采样: RC包末尾
    input rc_tvalid;    // 采样: RC有效
    input rc_tready;    // 采样: RC就绪
    input rc_tuser;     // 采样: RC用户信号

    // CQ通道全部采样
    input cq_tdata;     // 采样: CQ数据
    input cq_tkeep;     // 采样: CQ数据有效
    input cq_tlast;     // 采样: CQ包末尾
    input cq_tvalid;    // 采样: CQ有效
    input cq_tready;    // 采样: CQ就绪
    input cq_tuser;     // 采样: CQ用户信号

    // CC通道全部采样
    input cc_tdata;     // 采样: CC数据
    input cc_tkeep;     // 采样: CC数据有效
    input cc_tlast;     // 采样: CC包末尾
    input cc_tvalid;    // 采样: CC有效
    input cc_tready;    // 采样: CC就绪
    input cc_tuser;     // 采样: CC用户信号
  endclocking

  // ===========================================================================
  // Modport 定义
  // ===========================================================================

  // ep_mp: EP用户逻辑使用, 通过ep_drv_cb clocking block访问接口
  modport ep_mp  (clocking ep_drv_cb,  input clk, rst_n);

  // rc_mp: RC/PCIe IP BFM使用, 通过rc_drv_cb clocking block访问接口
  modport rc_mp  (clocking rc_drv_cb,  input clk, rst_n);

  // mon_mp: 监测器使用, 通过mon_cb clocking block进行纯采样
  modport mon_mp (clocking mon_cb,     input clk, rst_n);

endinterface : xilinx_pcie_if
