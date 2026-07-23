//=============================================================================
// Xilinx PCIe TL-Layer BFM - 类型定义文件
// 基于 Xilinx PG213 PCIe IP 接口规范
//=============================================================================

//-----------------------------------------------------------------------------
// 角色枚举：定义 BFM 在系统中扮演的角色
//-----------------------------------------------------------------------------
typedef enum bit {
    XILINX_PCIE_RC = 1'b0,   // Root Complex（根复合体），发起事务请求
    XILINX_PCIE_EP = 1'b1    // Endpoint（端点），响应事务请求
} xilinx_pcie_role_e;

//-----------------------------------------------------------------------------
// 通道枚举：PG213 定义的四个 AXI-Stream 通道
// RQ: Requester Request  - RC->EP 方向的请求通道
// RC: Requester Completion - EP->RC 方向的完成通道
// CQ: Completer Request  - RC->EP 方向，EP 侧接收请求
// CC: Completer Completion - EP->RC 方向，EP 侧发送完成
//-----------------------------------------------------------------------------
typedef enum bit [1:0] {
    XILINX_CH_RQ = 2'b00,   // Requester Request 通道（RC 发请求到 EP）
    XILINX_CH_RC = 2'b01,   // Requester Completion 通道（EP 返回完成到 RC）
    XILINX_CH_CQ = 2'b10,   // Completer Request 通道（EP 接收请求）
    XILINX_CH_CC = 2'b11    // Completer Completion 通道（EP 发送完成）
} xilinx_channel_e;

//-----------------------------------------------------------------------------
// PCIe 链路速度枚举
//-----------------------------------------------------------------------------
typedef enum bit [2:0] {
    XILINX_PCIE_GEN1 = 3'b001,   // Gen1: 2.5 GT/s
    XILINX_PCIE_GEN2 = 3'b010,   // Gen2: 5.0 GT/s
    XILINX_PCIE_GEN3 = 3'b011,   // Gen3: 8.0 GT/s
    XILINX_PCIE_GEN4 = 3'b100    // Gen4: 16.0 GT/s
} xilinx_pcie_speed_e;

//-----------------------------------------------------------------------------
// 中断模式枚举：支持三种 PCIe 中断机制
//-----------------------------------------------------------------------------
typedef enum bit [1:0] {
    XILINX_INT_LEGACY = 2'b00,   // Legacy INTx 中断（兼容旧设备）
    XILINX_INT_MSI    = 2'b01,   // MSI 中断（消息信号中断）
    XILINX_INT_MSIX   = 2'b10    // MSI-X 中断（扩展消息信号中断）
} xilinx_interrupt_mode_e;

//-----------------------------------------------------------------------------
// 请求类型枚举：对应 PG213 RQ/CQ 描述符中的 req_type 字段
// 编码与 Xilinx PG213 Table 2-22 定义对齐
//-----------------------------------------------------------------------------
typedef enum bit [3:0] {
    XILINX_REQ_MRD       = 4'b0000,   // Memory Read 请求
    XILINX_REQ_MWR       = 4'b0001,   // Memory Write 请求
    XILINX_REQ_IORD      = 4'b0010,   // I/O Read 请求
    XILINX_REQ_IOWR      = 4'b0011,   // I/O Write 请求
    XILINX_REQ_MRD_LK    = 4'b0100,   // Memory Read Locked 请求
    XILINX_REQ_FETCH_ADD = 4'b1000,   // AtomicOp FetchAdd 原子操作
    XILINX_REQ_SWAP      = 4'b1001,   // AtomicOp Swap 原子操作
    XILINX_REQ_CAS       = 4'b1010,   // AtomicOp Compare-and-Swap 原子操作
    XILINX_REQ_CFGRD0    = 4'b1100,   // Type 0 Configuration Read 请求
    XILINX_REQ_CFGWR0    = 4'b1101,   // Type 0 Configuration Write 请求
    XILINX_REQ_CFGRD1    = 4'b1110,   // Type 1 Configuration Read 请求
    XILINX_REQ_CFGWR1    = 4'b1111    // Type 1 Configuration Write 请求
} xilinx_req_type_e;

//-----------------------------------------------------------------------------
// 完成状态枚举：对应 PG213 RC/CC 描述符中的 cpl_status 字段
// 编码与 PCIe Spec 及 Xilinx PG213 Table 2-26 对齐
//-----------------------------------------------------------------------------
typedef enum bit [2:0] {
    XILINX_CPL_SC  = 3'b000,   // Successful Completion（成功完成）
    XILINX_CPL_UR  = 3'b001,   // Unsupported Request（不支持的请求）
    XILINX_CPL_CRS = 3'b010,   // Configuration Request Retry Status
    XILINX_CPL_CA  = 3'b100    // Completer Abort（完成方中止）
} xilinx_cpl_status_e;

//-----------------------------------------------------------------------------
// 地址类型枚举：对应 RQ 描述符中的 addr_type 字段（ATS 相关）
//-----------------------------------------------------------------------------
typedef enum bit [1:0] {
    XILINX_ADDR_UNTRANSLATED = 2'b00,   // 未翻译地址（普通内存访问）
    XILINX_ADDR_TRANS_REQ    = 2'b01,   // 翻译请求（ATS 翻译请求）
    XILINX_ADDR_TRANSLATED   = 2'b10    // 已翻译地址（ATS 已翻译地址）
} xilinx_addr_type_e;

//-----------------------------------------------------------------------------
// BAR 配置结构体：描述单个 BAR 的属性和映射
//-----------------------------------------------------------------------------
typedef struct {
    bit         enable;          // BAR 是否使能
    bit         is_64bit;        // 是否为 64 位 BAR
    bit         is_prefetch;     // 是否为可预取（Prefetchable）BAR
    bit         is_io;           // 是否为 I/O 空间 BAR（否则为内存空间）
    bit [63:0]  size;            // BAR 大小（字节数，必须为 2 的幂）
    bit [63:0]  base_addr;       // BAR 基地址（由 RC 枚举后配置）
} xilinx_bar_config_t;

//-----------------------------------------------------------------------------
// 通道带宽配置结构体：控制 AXI-Stream 通道的 valid/ready 时序行为
// 使用 axis_pkg 中的 valid/ready 生成模式枚举
//-----------------------------------------------------------------------------
typedef struct {
    axis_valid_gen_mode_e   valid_mode;     // Valid 信号生成模式
    axis_ready_gen_mode_e   ready_mode;     // Ready 信号生成模式
    int unsigned            idle_cycles;    // 固定空闲周期数（VALID_FIXED_IDLE 模式）
    int unsigned            valid_weight;   // Valid 权重（VALID_WEIGHTED 模式，0-100）
    int unsigned            ready_weight;   // Ready 权重（READY_WEIGHTED 模式，0-100）
    int unsigned            burst_len;      // Burst 长度（VALID_BURST_PAUSE 模式）
    int unsigned            pause_len;      // Pause 长度（VALID_BURST_PAUSE 模式）
} xilinx_channel_bw_config_t;

//-----------------------------------------------------------------------------
// 中断事务 item：捕获一次中断事件的所有信息
//-----------------------------------------------------------------------------
class xilinx_interrupt_item extends uvm_sequence_item;
    `uvm_object_utils_begin(xilinx_interrupt_item)
        `uvm_field_enum(xilinx_interrupt_mode_e, mode,      UVM_ALL_ON)
        `uvm_field_int (vector_num,                         UVM_ALL_ON)
        `uvm_field_int (msix_addr,                          UVM_ALL_ON)
        `uvm_field_int (msix_data,                          UVM_ALL_ON)
        `uvm_field_int (msi_data,                           UVM_ALL_ON)
        `uvm_field_int (timestamp,                          UVM_ALL_ON)
    `uvm_object_utils_end

    // 中断模式：Legacy / MSI / MSI-X
    xilinx_interrupt_mode_e mode;

    // MSI-X 向量编号（Legacy 模式下表示 INTx 编号 0-3 对应 INTA-INTD）
    int unsigned            vector_num;

    // MSI-X 专用字段：写入内存的目标地址和数据
    bit [63:0]              msix_addr;   // MSI-X 表项中的 Message Address
    bit [31:0]              msix_data;   // MSI-X 表项中的 Message Data

    // MSI 专用字段：写入 MSI Capability 结构中的消息数据
    bit [31:0]              msi_data;

    // 仿真时间戳（单位：ps），用于时序分析
    longint unsigned        timestamp;

    function new(string name = "xilinx_interrupt_item");
        super.new(name);
    endfunction

endclass : xilinx_interrupt_item

//-----------------------------------------------------------------------------
// 描述符事务 item：表示一个完整的 AXI-Stream 描述符及其 payload
// 对应 PG213 中 RQ/RC/CQ/CC 四个通道的描述符格式
//-----------------------------------------------------------------------------
class xilinx_desc_item extends uvm_sequence_item;
    `uvm_object_utils_begin(xilinx_desc_item)
        `uvm_field_enum(xilinx_channel_e, channel,   UVM_ALL_ON)
        `uvm_field_int (descriptor,                  UVM_ALL_ON)
        `uvm_field_array_int(payload,                UVM_ALL_ON)
    `uvm_object_utils_end

    // 所属通道：RQ / RC / CQ / CC
    xilinx_channel_e    channel;

    // 128 位描述符头（PG213 定义的描述符格式，具体字段由 codec 解码）
    bit [127:0]         descriptor;

    // 可变长度 payload 数据（MWR/CPLD 等携带数据的事务，按字节存储）
    byte unsigned       payload[];

    // 解码后的 PCIe TLP 对象（由 codec 填充，用于 scoreboard 比较）
    pcie_tl_tlp         decoded_tlp;

    function new(string name = "xilinx_desc_item");
        super.new(name);
        decoded_tlp = null;
    endfunction

endclass : xilinx_desc_item

//=============================================================================
// tuser 宽度查询函数：根据 AXI-Stream 数据位宽返回对应的 tuser 位宽
// 来源：Xilinx PG213，各通道 tuser 位宽随数据宽度变化
//=============================================================================

//-----------------------------------------------------------------------------
// RQ 通道 tuser 宽度 (PG213: 64/128/256 同宽 62, 512 为 137)
// 64b->62, 128b->62, 256b->62, 512b->137
//-----------------------------------------------------------------------------
function automatic int xilinx_get_rq_tuser_width(int data_width);
    case (data_width)
        64:      return 62;
        128:     return 62;
        256:     return 62;
        512:     return 137;
        default: begin
            $fatal(1, "[xilinx_pcie] xilinx_get_rq_tuser_width: 不支持的数据宽度 %0d", data_width);
            return -1;
        end
    endcase
endfunction : xilinx_get_rq_tuser_width

//-----------------------------------------------------------------------------
// RC 通道 tuser 宽度 (PG213: 64/128/256 同宽 75, 512 为 161)
// 64b->75, 128b->75, 256b->75, 512b->161
//-----------------------------------------------------------------------------
function automatic int xilinx_get_rc_tuser_width(int data_width);
    case (data_width)
        64:      return 75;
        128:     return 75;
        256:     return 75;
        512:     return 161;
        default: begin
            $fatal(1, "[xilinx_pcie] xilinx_get_rc_tuser_width: 不支持的数据宽度 %0d", data_width);
            return -1;
        end
    endcase
endfunction : xilinx_get_rc_tuser_width

//-----------------------------------------------------------------------------
// CQ 通道 tuser 宽度 (PG213: 64/128/256 同宽 88, 512 为 183)
// 64b->88, 128b->88, 256b->88, 512b->183
//-----------------------------------------------------------------------------
function automatic int xilinx_get_cq_tuser_width(int data_width);
    case (data_width)
        64:      return 88;
        128:     return 88;
        256:     return 88;
        512:     return 183;
        default: begin
            $fatal(1, "[xilinx_pcie] xilinx_get_cq_tuser_width: 不支持的数据宽度 %0d", data_width);
            return -1;
        end
    endcase
endfunction : xilinx_get_cq_tuser_width

//-----------------------------------------------------------------------------
// CC 通道 tuser 宽度 (PG213: 64/128/256 同宽 33, 512 为 81)
// 64b->33, 128b->33, 256b->33, 512b->81
//-----------------------------------------------------------------------------
function automatic int xilinx_get_cc_tuser_width(int data_width);
    case (data_width)
        64:      return 33;
        128:     return 33;
        256:     return 33;
        512:     return 81;
        default: begin
            $fatal(1, "[xilinx_pcie] xilinx_get_cc_tuser_width: 不支持的数据宽度 %0d", data_width);
            return -1;
        end
    endcase
endfunction : xilinx_get_cc_tuser_width
