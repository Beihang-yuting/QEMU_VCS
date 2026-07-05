// =============================================================================
// 文件名: xilinx_pcie_cfg_if.sv
// 描述: Xilinx PCIe 配置管理与中断边带信号接口 (参考 PG213)
//
// 涵盖以下功能模块:
//   cfg_mgmt       - 配置空间读写管理接口
//   cfg_interrupt  - Legacy/MSI/MSI-X 中断接口
// =============================================================================

interface xilinx_pcie_cfg_if(
  input logic clk,   // PCIe用户时钟 (user_clk)
  input logic rst_n  // 低电平有效复位
);

  // ===========================================================================
  // cfg_mgmt — 配置管理接口
  // 用于EP用户逻辑读写PCIe配置空间寄存器
  // ===========================================================================

  // 控制信号 (EP用户逻辑 -> PCIe IP)
  logic [9:0]  cfg_mgmt_addr;              // 配置空间地址 (DWORD寻址, 10bit)
  logic [3:0]  cfg_mgmt_byte_enable;       // 字节使能 (4bit, 对应32bit数据的4字节)
  logic        cfg_mgmt_read;              // 配置读请求脉冲
  logic        cfg_mgmt_write;             // 配置写请求脉冲
  logic [31:0] cfg_mgmt_write_data;        // 配置写数据 (32bit)

  // 状态信号 (PCIe IP -> EP用户逻辑)
  logic [31:0] cfg_mgmt_read_data;         // 配置读返回数据 (32bit)
  logic        cfg_mgmt_read_write_done;   // 读/写操作完成指示
  logic        cfg_mgmt_debug_access;      // 调试访问模式指示

  // ===========================================================================
  // cfg_interrupt Legacy — 传统INTx中断接口
  // ===========================================================================

  // 控制信号 (EP用户逻辑 -> PCIe IP)
  logic [3:0]  cfg_interrupt_int;          // INTx中断请求 [3:0] = INTD/C/B/A
  logic [3:0]  cfg_interrupt_pending;      // INTx中断挂起状态 [3:0]

  // 状态信号 (PCIe IP -> EP用户逻辑)
  logic        cfg_interrupt_sent;         // 中断已发送确认脉冲

  // ===========================================================================
  // cfg_interrupt MSI — 消息信号中断接口
  // ===========================================================================

  // 状态信号 (PCIe IP -> EP用户逻辑)
  logic        cfg_interrupt_msi_enable;                    // MSI已使能 (PCIe配置空间状态)
  logic [2:0]  cfg_interrupt_msi_mmenable;                  // MSI多消息使能位数 [2:0]
  logic        cfg_interrupt_msi_mask_update;               // MSI mask寄存器更新指示

  // 控制信号 (EP用户逻辑 -> PCIe IP)
  logic [31:0] cfg_interrupt_msi_data;                      // MSI中断数据负载 (32bit)
  logic [3:0]  cfg_interrupt_msi_select;                    // MSI功能选择 [3:0]
  logic [31:0] cfg_interrupt_msi_int;                       // MSI中断请求向量 (32bit)
  logic [31:0] cfg_interrupt_msi_pending_status;            // MSI挂起状态向量 (32bit)
  logic        cfg_interrupt_msi_pending_status_data_enable;// MSI挂起状态数据使能
  logic [3:0]  cfg_interrupt_msi_pending_status_function_num; // MSI挂起状态功能号 [3:0]

  // 状态信号 (PCIe IP -> EP用户逻辑)
  logic        cfg_interrupt_msi_sent;                      // MSI中断已发送确认
  logic        cfg_interrupt_msi_fail;                      // MSI中断发送失败指示

  // ===========================================================================
  // cfg_interrupt MSI-X — 扩展消息信号中断接口
  // ===========================================================================

  // 状态信号 (PCIe IP -> EP用户逻辑)
  logic        cfg_interrupt_msix_enable;                   // MSI-X已使能 (配置空间状态)
  logic        cfg_interrupt_msix_mask;                     // MSI-X全局mask状态

  // 控制信号 (EP用户逻辑 -> PCIe IP)
  logic [31:0] cfg_interrupt_msix_data;                     // MSI-X中断数据 (32bit)
  logic [63:0] cfg_interrupt_msix_address;                  // MSI-X中断目标地址 (64bit)
  logic        cfg_interrupt_msix_int;                      // MSI-X中断请求脉冲

  // 状态信号 (PCIe IP -> EP用户逻辑)
  logic [1:0]  cfg_interrupt_msix_vec_pending;              // MSI-X向量挂起状态 [1:0]
  logic        cfg_interrupt_msix_vec_pending_status;       // MSI-X向量挂起状态有效指示

  // ===========================================================================
  // Clocking Block: user_cb
  // 用途: EP用户逻辑视角
  //   - 输出: 所有控制/请求信号 (用户逻辑驱动到PCIe IP)
  //   - 输入: 所有状态/响应信号 (PCIe IP返回给用户逻辑)
  // ===========================================================================
  clocking user_cb @(posedge clk);
    // ---- cfg_mgmt 控制输出 ----
    output cfg_mgmt_addr;                            // 输出: 配置空间地址
    output cfg_mgmt_byte_enable;                     // 输出: 字节使能
    output cfg_mgmt_read;                            // 输出: 读请求
    output cfg_mgmt_write;                           // 输出: 写请求
    output cfg_mgmt_write_data;                      // 输出: 写数据

    // ---- cfg_mgmt 状态输入 ----
    input  cfg_mgmt_read_data;                       // 输入: 读返回数据
    input  cfg_mgmt_read_write_done;                 // 输入: 操作完成
    input  cfg_mgmt_debug_access;                    // 输入: 调试访问指示

    // ---- cfg_interrupt Legacy 控制输出 ----
    output cfg_interrupt_int;                        // 输出: INTx中断请求
    output cfg_interrupt_pending;                    // 输出: INTx挂起状态

    // ---- cfg_interrupt Legacy 状态输入 ----
    input  cfg_interrupt_sent;                       // 输入: 中断发送确认

    // ---- cfg_interrupt MSI 状态输入 ----
    input  cfg_interrupt_msi_enable;                 // 输入: MSI使能状态
    input  cfg_interrupt_msi_mmenable;               // 输入: MSI多消息使能
    input  cfg_interrupt_msi_mask_update;            // 输入: MSI mask更新指示
    input  cfg_interrupt_msi_sent;                   // 输入: MSI发送确认
    input  cfg_interrupt_msi_fail;                   // 输入: MSI发送失败

    // ---- cfg_interrupt MSI 控制输出 ----
    output cfg_interrupt_msi_data;                              // 输出: MSI数据
    output cfg_interrupt_msi_select;                            // 输出: MSI功能选择
    output cfg_interrupt_msi_int;                               // 输出: MSI中断向量
    output cfg_interrupt_msi_pending_status;                    // 输出: MSI挂起状态
    output cfg_interrupt_msi_pending_status_data_enable;        // 输出: MSI挂起数据使能
    output cfg_interrupt_msi_pending_status_function_num;       // 输出: MSI挂起功能号

    // ---- cfg_interrupt MSI-X 状态输入 ----
    input  cfg_interrupt_msix_enable;                // 输入: MSI-X使能状态
    input  cfg_interrupt_msix_mask;                  // 输入: MSI-X全局mask
    input  cfg_interrupt_msix_vec_pending;           // 输入: MSI-X向量挂起状态
    input  cfg_interrupt_msix_vec_pending_status;    // 输入: MSI-X挂起状态有效

    // ---- cfg_interrupt MSI-X 控制输出 ----
    output cfg_interrupt_msix_data;                  // 输出: MSI-X中断数据
    output cfg_interrupt_msix_address;               // 输出: MSI-X目标地址
    output cfg_interrupt_msix_int;                   // 输出: MSI-X中断请求
  endclocking

  // ===========================================================================
  // Clocking Block: pcie_ip_cb
  // 用途: PCIe IP / RC BFM视角 — 方向与user_cb完全相反
  //   - 输入: 所有控制/请求信号 (采样用户逻辑发出的控制)
  //   - 输出: 所有状态/响应信号 (模拟PCIe IP向用户逻辑返回状态)
  // ===========================================================================
  clocking pcie_ip_cb @(posedge clk);
    // ---- cfg_mgmt 控制输入 (采样用户逻辑请求) ----
    input  cfg_mgmt_addr;                            // 采样: 配置地址
    input  cfg_mgmt_byte_enable;                     // 采样: 字节使能
    input  cfg_mgmt_read;                            // 采样: 读请求
    input  cfg_mgmt_write;                           // 采样: 写请求
    input  cfg_mgmt_write_data;                      // 采样: 写数据

    // ---- cfg_mgmt 状态输出 (模拟PCIe IP响应) ----
    output cfg_mgmt_read_data;                       // 输出: 读返回数据
    output cfg_mgmt_read_write_done;                 // 输出: 操作完成脉冲
    output cfg_mgmt_debug_access;                    // 输出: 调试访问指示

    // ---- cfg_interrupt Legacy 控制输入 ----
    input  cfg_interrupt_int;                        // 采样: INTx中断请求
    input  cfg_interrupt_pending;                    // 采样: INTx挂起状态

    // ---- cfg_interrupt Legacy 状态输出 ----
    output cfg_interrupt_sent;                       // 输出: 中断发送确认

    // ---- cfg_interrupt MSI 状态输出 (模拟配置空间状态) ----
    output cfg_interrupt_msi_enable;                 // 输出: MSI使能状态
    output cfg_interrupt_msi_mmenable;               // 输出: MSI多消息使能
    output cfg_interrupt_msi_mask_update;            // 输出: MSI mask更新
    output cfg_interrupt_msi_sent;                   // 输出: MSI发送确认
    output cfg_interrupt_msi_fail;                   // 输出: MSI发送失败

    // ---- cfg_interrupt MSI 控制输入 (采样用户逻辑请求) ----
    input  cfg_interrupt_msi_data;                              // 采样: MSI数据
    input  cfg_interrupt_msi_select;                            // 采样: MSI功能选择
    input  cfg_interrupt_msi_int;                               // 采样: MSI中断向量
    input  cfg_interrupt_msi_pending_status;                    // 采样: MSI挂起状态
    input  cfg_interrupt_msi_pending_status_data_enable;        // 采样: MSI挂起数据使能
    input  cfg_interrupt_msi_pending_status_function_num;       // 采样: MSI挂起功能号

    // ---- cfg_interrupt MSI-X 状态输出 (模拟配置空间状态) ----
    output cfg_interrupt_msix_enable;                // 输出: MSI-X使能状态
    output cfg_interrupt_msix_mask;                  // 输出: MSI-X全局mask
    output cfg_interrupt_msix_vec_pending;           // 输出: MSI-X向量挂起
    output cfg_interrupt_msix_vec_pending_status;    // 输出: MSI-X挂起状态有效

    // ---- cfg_interrupt MSI-X 控制输入 (采样用户逻辑请求) ----
    input  cfg_interrupt_msix_data;                  // 采样: MSI-X中断数据
    input  cfg_interrupt_msix_address;               // 采样: MSI-X目标地址
    input  cfg_interrupt_msix_int;                   // 采样: MSI-X中断请求
  endclocking

  // ===========================================================================
  // Modport 定义
  // ===========================================================================

  // user_mp: EP用户逻辑使用, 通过user_cb clocking block访问接口
  modport user_mp    (clocking user_cb,    input clk, rst_n);

  // pcie_ip_mp: PCIe IP BFM使用, 通过pcie_ip_cb clocking block访问接口
  modport pcie_ip_mp (clocking pcie_ip_cb, input clk, rst_n);

endinterface : xilinx_pcie_cfg_if
