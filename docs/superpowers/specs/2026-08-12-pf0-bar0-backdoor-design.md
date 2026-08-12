# PF0 BAR0 可选后门旁路设计

**日期：** 2026-08-12
**分支：** `feature/ext-tlp-inbound`
**状态：** 已完成设计评审，待实施计划

## 1. 背景与目标

当前 QEMU 发起的 Host-to-Device BAR MMIO 请求经 CoSim transport 到达
`cosim_xrc_driver`，再编码到 Xilinx PCIe CQ 接口送入完整 DUT。DUT 返回的 CC
Completion 经 VCS Bridge 回到 QEMU。完整 RTL 数据通路过慢，尤其是驱动连续配置大表时，
需要一个显式可选的后门旁路。

本设计在 `cosim_xrc_driver` 进入 CQ 之前加入可注册的 BAR0 后门服务：

- 仅匹配当前 RC 下 PF0 的 BAR0；
- 命中映射的请求由后门直接访问 RTL 存储节点；
- MRd 直接向 QEMU 返回 Completion with Data；
- MWr 是 PCIe posted write，不向 QEMU 返回 Completion；
- 未命中或不支持的请求继续走原 CQ -> DUT -> CC 路径；
- 默认关闭，未注册服务时现有行为完全不变；
- 支持 128/256/1024 bit 等参数化宽表，写入时聚合完整逻辑行；
- 支持纯数据、parity、SECDED 和自定义保护算法；
- 支持普通单 RAM 以及按逻辑 index 路由到多个层级 RAM 的特殊 writer。

本文中的请求是 BAR MMIO TLP，不是 Device-to-Host DMA。二者的完成语义不同。

## 2. 范围

### 2.1 本轮范围

- PF0 BAR0 Memory Read/Write；
- 每次 QEMU 访问为 1/2/4B 且不跨 DWORD；表配置的常规访问粒度为 4B；
- 原始 CPU read 支持 1/2/4B；按现有 QEMU 插件规范化语义，后门即时读取并返回完整 4B DWORD；
- 写请求按表项逻辑宽度聚合，完整行收齐后一次提交；
- 一个映射文件描述多个 table/register region；
- 保护粒度支持 1B 或 4B；
- 保护模式支持 `none`、`parity`、`secded`、`custom`；
- 物理布局支持 `prefix`、`interleaved`；
- 默认复用 AIP Core 的 XOR parity 和 Hamming SECDED；
- codec 和 writer 均保留用户 callback；
- AIP 参数、日志、状态和 flush 命令；
- 多 RC 可用 mask 控制，但每个 RC 只匹配其 PF0 BAR0。

### 2.2 不在本轮

- PF1..N、VF 或其他 BAR；
- BAR config-space 请求的后门处理；
- 跨 DWORD、8B 或更长的单个 MMIO 请求；
- 自动热重载映射文件；
- 不完整逻辑行的自动超时提交；
- 对多次 `uvm_hdl_deposit` 提供事务回滚；
- 自动推断 DUT 专用 ECC 位序或层次结构；
- 在 `cosim-platform` 内下载、固定或 vendoring `aip_core`。

## 3. 设计原则

1. **默认零影响：** 命令行不开启、用户未编译 AIP 或未注册服务时，原路径不变。
2. **旁路点最靠前：** 在 `cosim_xrc_driver.request_loop()` 中、构造 VIP TLP 和发送 CQ
   之前判断，命中请求完全不进入慢速 DUT。
3. **CoSim 与 AIP 解耦：** CoSim 只定义抽象服务；AIP 实现由用户测试自行加入编译和注册。
4. **只用 BAR offset：** 映射文件不记录 Guest 动态分配的 BAR base。
5. **失败不重复执行：** 只有尚未开始后门处理的请求才能 `MISS` 回退。一旦接收或执行后门，
   后续失败必须 `ERROR`，不能再送 CQ。
6. **完整行提交：** 表项写入全部数据收齐后才计算保护位并更新 RTL。

## 4. 方案比较与选择

### 4.1 方案 A：VCS 请求驱动中、CQ 之前旁路（采用）

```text
QEMU TLP
  -> cosim_xrc_driver
       |- PF0 BAR0 + region hit -> registered backdoor service
       `- otherwise             -> existing CQ -> DUT -> CC
```

该点已经拥有 QEMU 的地址、数据、长度、tag 和目标 BDF，也能直接调用 per-RC Completion
DPI。命中请求完全避开 CQ，关闭开关时不改变现有逻辑。

### 4.2 方案 B：Xilinx CQ adapter 内旁路（不采用）

通用 adapter 不应承载 PF0、DUT table、AIP 和用户层次路径语义；读请求还需要反向合成 CC，
耦合更重。

### 4.3 方案 C：QEMU 设备中旁路（不采用）

QEMU 无法直接访问 VCS 中的 RTL 层次，需要新增双端后门协议，复杂度和线格式同步风险高。

## 5. 组件边界

```text
cosim-platform
  vcs-tb/cosim_bar0_backdoor_pkg.sv
    request/result/status definitions
    abstract cosim_bar0_backdoor_service
  vcs-tb/cosim_xrc_driver.sv
    PF0/BAR0/RC gating
    service dispatch
    direct MRd completion
    MISS fallback

aip_core (independent repository, user adds it to the test compilation)
  aip_bar0_map_parser
    INI parser and whole-map validation
  aip_wide_table_backdoor
    region lookup, read extraction, write aggregation
    protection encoding, physical packing, status/flush
  aip_table_codec
    default parity/SECDED plus custom callback interface
  aip_table_writer / aip_table_reader
    generic HDL implementation plus user callbacks

user test
  user_cosim_bar0_adapter extends cosim_bar0_backdoor_service
    owns/configures aip_wide_table_backdoor
    translates CoSim request/result to the AIP API
  optional DUT-specific codec/writer/reader callbacks
  uvm_config_db registration
```

`cosim-platform` 不包含 `aip_core` 路径、submodule、clone 脚本或凭据。用户测试自行保证
`aip_core_pkg.sv` 在同一次 VCS analysis 中按 AIP 的编译顺序先于消费者出现。

## 6. CoSim 抽象服务

### 6.1 文件位置

新增 `vcs-tb/cosim_bar0_backdoor_pkg.sv`。该包不得 import `aip_core_pkg`，只依赖
SystemVerilog/UVM 基础类型。

### 6.2 请求与结果

请求至少包含：

```systemverilog
typedef struct {
    int unsigned      rc_index;
    bit [15:0]        target_bdf;
    bit [7:0]         tlp_type;
    longint unsigned  absolute_addr;
    longint unsigned  bar0_base;
    longint unsigned  bar0_offset;
    int unsigned      len_bytes;
    bit [3:0]         first_be;
    bit [3:0]         last_be;
    bit [9:0]         qemu_tag;
    int unsigned      data_words[16];
} cosim_bar0_request;
```

具体实现可用 class 代替 packed struct，以便携带动态数组；接口语义不变。

结果状态：

```systemverilog
typedef enum { COSIM_BD_MISS, COSIM_BD_HANDLED, COSIM_BD_ERROR }
    cosim_bar0_status_e;
```

- `MISS`：服务未开启、PF/BAR/region 不匹配或请求尚未被服务接收；CoSim 走原 CQ 路径。
- `HANDLED`：后门成功处理；读结果包含返回字节，写请求不需要 Completion。
- `ERROR`：服务已经接收或执行请求但失败；CoSim 报错且不得回退。

抽象类：

```systemverilog
virtual class cosim_bar0_backdoor_service;
    pure virtual task access(
        input  cosim_bar0_request req,
        output cosim_bar0_result  result
    );
    virtual task flush(input string reason); endtask
    virtual function void report_status(); endfunction
endclass
```

### 6.3 注册

用户 test 在 env 创建前通过 `uvm_config_db` 注册服务。每个 `cosim_xrc_driver` 在
`build_phase` 中尝试获取。没有服务时句柄为 `null`，所有请求走原路径。

```systemverilog
uvm_config_db#(cosim_bar0_backdoor_service)::set(
    null, "uvm_test_top.env.rc_agent_*", "bar0_backdoor_service", svc);
```

## 7. PF0 BAR0 识别

映射文件中的所有 region 均约定属于当前 RC 的 PF0 BAR0，不要求用户配置 `target_bar`
或 BAR base。

判定顺序：

1. `+bar0_bd.enable=1`；
2. 当前 RC 位于 `+bar0_bd.rc_mask`；
3. 请求 `target_bdf` 匹配当前拓扑中的 PF0；
4. PF0 BAR0 已完成枚举并具有有效 base；
5. 请求地址落在 PF0 BAR0 aperture；
6. `bar0_offset = absolute_addr - bar0_base` 命中一个 region；
7. 请求长度、对齐和 Byte Enable 受支持。

任何在后门接收前失败的条件返回 `MISS`。

BAR0 base 来自现有 config proxy 对 Guest BAR 配置写的捕获。当前代码已经同步
`config_proxy.bar0_addr` 和 `bridge_vcs_set_bar_base_rc(rc, 0, ...)`；实现需使用每个 RC
当前值，不在 INI 中硬编码 `0x80000000` 一类动态地址。

CoSim per-RC poll 路径必须补齐 `target_bdf`、`first_be` 和 `last_be` getter 的使用，确保
PF0 身份和 8/16-bit 写语义不丢失。

## 8. 映射文件与解析器

### 8.1 格式

AIP 实现提供启动时一次性解析的 INI 风格文件：

```ini
[global]
version=1

[table.route]
offset=0x10000
depth=256
data_width_bits=128
stride_bytes=16
access_granule_bytes=4
protect_mode=secded
protect_granule_bytes=4
protect_layout=prefix
hdl_path=tb_top.dut.route_table
codec=default
writer=generic_hdl
reader=generic_hdl

[table.queue]
offset=0x20000
depth=1024
data_width_bits=256
stride_bytes=32
access_granule_bytes=4
protect_mode=parity
protect_granule_bytes=1
protect_layout=interleaved
hdl_path=tb_top.dut.queue_table
codec=default

[table.action]
offset=0x40000
depth=128
data_width_bits=1024
stride_bytes=128
access_granule_bytes=4
protect_mode=none
hdl_path=tb_top.dut.action_table

[table.vio_notify]
offset=0x60000
depth=1024
data_width_bits=128
stride_bytes=16
access_granule_bytes=4
protect_mode=secded
protect_granule_bytes=4
protect_layout=prefix
codec=default
writer=vio_notify
reader=vio_notify
```

### 8.2 地址计算

对 region：

```text
region_start = offset
region_end   = offset + depth * stride_bytes
delta        = bar0_offset - offset
logical_idx  = delta / stride_bytes
row_offset   = delta % stride_bytes
row_bytes    = data_width_bits / 8
```

命中条件为 `region_start <= bar0_offset < region_end` 且 `row_offset < row_bytes`。
当 stride 大于 row bytes 时，空洞访问返回 `MISS`。

### 8.3 校验

解析必须 fail closed，并在启用后门前完成全图校验：

- section 名唯一；
- region 地址区间不重叠；
- width 为 8 的倍数；
- width 可被访问粒度和保护粒度整除；
- 首版 `access_granule_bytes` 为 4，寄存器型区域可接受 1/2/4B；
- `protect_granule_bytes` 仅为 1 或 4；
- `stride_bytes >= row_bytes`；
- offset 和 stride 满足 4B 对齐；
- `offset + depth * stride` 不溢出；
- `protect_mode/layout` 合法；
- generic writer/reader 的 HDL path 可访问；
- custom codec/writer/reader 名称已注册；
- 最终物理宽度不超过 `UVM_HDL_MAX_WIDTH`。

任意配置错误使整个服务保持禁用；不得只启用部分 region。

## 9. 参数化数据表示

`uvm_reg_data_t` 和 `longint` 无法承载 128/256/1024 bit。公共组件内部、codec 和
writer/reader callback 统一使用动态字节数组和逐字节有效数组：

```systemverilog
typedef byte unsigned aip_table_bytes_t[];
typedef bit           aip_table_valid_t[];
```

只有 generic HDL accessor 调用 `uvm_hdl_read/deposit` 时才打包/解包
`uvm_hdl_data_t`。启动时检查物理宽度上限，禁止静默截断。

## 10. 读路径

读不聚合。QEMU 插件会把 1/2/4B CPU MMIO read 规范化为 DW 对齐、`len=4` 的 MRd，
并用 `first_be` 记录原始子字节位置。因此后门按与现有插件一致的语义返回包含目标字节的
完整 4B DWORD；QEMU 再根据原 CPU 地址提取 1/2/4B。数据流为：

```text
QEMU MRd
 -> PF0/BAR0/region/index/row_offset decode
 -> reader reads full physical RTL word at logical_idx
 -> unpack prefix/interleaved layout to logical data
 -> optionally verify protection (no automatic correction in first version)
 -> read the aligned logical DWORD at row_offset
 -> HANDLED + return the full 4B DWORD
 -> cosim_xrc_driver sends CplD using original QEMU tag
```

读请求不分配 VIP tag，不进入 CQ，也不等待 DUT CC。QEMU tag 必须原样回显，Completion
长度必须保持为 4B，以匹配当前 QEMU 插件。若该表项有
尚未收齐的写缓存，读仍读取 RTL 中上一次已提交的完整值，并打印 DEBUG 日志，不暴露半成品。

HDL read 已开始后失败返回 `ERROR`；不能回退 CQ，否则可能产生两个 Completion。

## 11. 写聚合与提交

### 11.1 缓存

每个 `(rc, region, logical_idx)` 维护：

- `data[row_bytes]`；
- `valid[row_bytes]`；
- `received_bytes`；
- `state = EMPTY/COLLECTING/COMMITTING/ERROR`；
- 第一/最后更新时间；
- 错误原因和提交统计。

不同 index 可以交错。同一个 index 不会在上一轮未收齐时开始下一轮完整写。

### 11.2 捕获

每次 MWr 根据 `row_offset`、长度和 `first_be/last_be` 只更新真正有效的字节。写入顺序
任意，高 DWORD 到低 DWORD或反向均可。

若同一轮重复写已经有效的 chunk，视为驱动协议异常：返回 `ERROR`，保留首轮缓存用于诊断，
不覆盖、不提交、不回退 CQ。

### 11.3 完整提交

当所有逻辑数据字节有效时：

1. 组装完整逻辑行；
2. 按 `protect_granule_bytes` 划分 1B 或 4B group；
3. 调用默认或 custom codec 为每组生成保护位；
4. 按 `prefix/interleaved` 组装最终物理 word；
5. 调用 writer callback；
6. writer 成功后计数并清空缓存，开始下一代写入。

每个 QEMU MWr 均为 posted request：服务接收后返回 `HANDLED`，CoSim 不发送 Completion。
这表示写已被旁路层接受；只有完整行 writer 成功才表示表项提交到 RTL。

### 11.4 不完整项

`aggregate_timeout_ns` 首版固定默认为 0，不按仿真时间自动提交或丢弃，避免慢仿真误报。
reset、shutdown 或显式 flush 时：

- 打印 region/index、已收到和缺失 mask；
- 计入 `incomplete_discard`；
- 默认丢弃，不写 DUT。

## 12. 保护算法与物理布局

### 12.1 模式

- `none`：纯数据，无保护位；布局字段忽略。
- `parity`：复用 AIP XOR parity，支持 even/odd 配置。
- `secded`：复用 AIP Hamming SECDED，首版保护 group 为现有实现支持的 8 或 32 bit。
- `custom`：调用按名称注册的 codec callback。

同一个 DUT 可以让不同 region 分别选择 none、parity、SECDED 或 custom。

### 12.2 粒度

`protect_granule_bytes=1|4`。例如 128-bit 数据按 4B SECDED：

```text
4 groups * 32 data bits
7 SECDED bits per group
total protection = 28 bits
physical width   = 156 bits
```

### 12.3 布局

`prefix`：

```text
{protect[N-1], ..., protect[0], data[DATA_WIDTH-1:0]}
```

`interleaved`：

```text
{protect[N-1], data[N-1], ..., protect[0], data[0]}
```

codec callback 输入完整逻辑行和保护粒度，输出每组保护位/宽度。DUT 位序或算法改变时只替换
codec，不修改 CoSim。

## 13. Writer/Reader

### 13.1 Generic HDL

普通表使用 `generic_hdl`：

- writer：将最终物理 word 打包成 `uvm_hdl_data_t`，对 `hdl_path[index]` 调
  `uvm_hdl_deposit`；
- reader：对 `hdl_path[index]` 调 `uvm_hdl_read` 并解包；
- 不使用 `force`；
- deposit 成功返回即视为 writer 完成，不做 readback；
- 路径必须指向 RTL 实际存储变量，不是临时总线输入信号。

### 13.2 Custom Writer/Reader

特殊表的物理 RAM 路径由逻辑 index 决定，且一次逻辑提交可能更新 L3/L2/L1 多层 RAM。
运行时字符串无法作为预处理宏参数，因此该规则必须由用户编译期 callback 实现，而不是
仅靠 INI。

图片中的 `vio_notify` 示例语义：

- 每个 `idx` 都更新一个 L3 RAM，`idx % 4` 选择 RAM 宏路径；
- 每 16 项末尾额外更新对应 L2 RAM；
- 每 256 项末尾额外更新对应 L1 RAM；
- 每层重新计算物理 RAM index；
- 多个 deposit 写相同的完整物理数据或指定 slice。

接口示意：

```systemverilog
virtual class aip_table_writer;
    pure virtual task write_row(
        input  string              region_name,
        input  longint unsigned    logical_idx,
        input  byte unsigned       logical_data[],
        input  byte unsigned       physical_data[],
        output bit                 success,
        output string              detail
    );
endclass
```

用户 `vio_notify_writer` 在 task 内按 `logical_idx` 计算 `l3_mod/l2_mod/l1_mod` 和物理 index，
通过现有 `ST_WRITE_DEPOSIT_RAM(index, value, RAM_MACRO_PATH)` case 分支调用编译期 RAM 宏。

reader 使用相同 index 路由读取主 L3 RAM并返回完整物理行；L2/L1 作为派生镜像，默认不用于
QEMU 读回。

多次 deposit 无法回滚。writer 必须预先完成数据计算和可做的路径检查，最后执行写入。
中途失败返回 `ERROR`，记录哪些层级已成功/失败，不自动重试或回退 CQ。

## 14. 命令行、命令与日志

用户的 AIP adapter 使用现有 `aip_int/aip_string`：

```text
+bar0_bd.enable=1
+bar0_bd.map=/path/to/pf0_bar0.ini
+bar0_bd.rc_mask=0x3
+bar0_bd.log_level=debug
+bar0_bd.dump_max_bits=1024
```

建议命令：

- `bar0_bd_status`：region、缓存和统计；
- `bar0_bd_flush incomplete=discard`：报告并丢弃未完成项；
- `bar0_bd_log level=info|debug|trace`：运行时调整日志。

AIP 日志分层：

- `INFO`：开关、映射摘要、region 配置、最终统计；
- `DEBUG`（相当于所需 HIGH）：每个 4B 捕获、valid mask、完整逻辑行、保护位、最终物理
  word、writer 路由、读回值和 QEMU tag；
- `TRACE`：每个 protection group 的输入和编码输出；
- `WARNING/ERROR`：MISS 原因摘要、重复 chunk、不完整 flush、HDL 和 callback 失败。

关键 DEBUG 示例：

```text
RC0 WR CAPTURE region=route idx=2 row_off=12 data=0x12345678 be=0xf valid=0xf000/0xffff
RC0 ROW COMPLETE region=route idx=2 logical_data=<128-bit hex>
RC0 PROTECT mode=secded granule=4 protect_bits=<28-bit hex>
RC0 PHYSICAL region=route idx=2 layout=prefix data=<156-bit hex>
RC0 CUSTOM WRITE region=vio_notify idx=255 L3=PCMP_3HH[15] L2=triggered L1=triggered result=SUCCESS
RC0 RD HIT region=route idx=2 row_off=12 physical=<156-bit hex> logical=<128-bit hex> return=0x12345678 tag=0x035
```

大于 `dump_max_bits` 的值须按头尾截断显示并附总宽度，防止 1024-bit 高频打印淹没日志。

## 15. CoSim 请求循环集成

`cosim_xrc_driver.request_loop()` 获取完整 DPI 字段后：

1. 保留现有 config-space bypass；
2. 对 MWr/MRd 构造 `cosim_bar0_request`；
3. service 为空则跳过；
4. 调 service：
   - `MISS`：执行现有 `build_mmio_tlp -> send_tlp -> tag map`；
   - `HANDLED + MRd`：填充 per-RC completion buffer，使用原 `dpi_tag` 直接
     `bridge_vcs_send_cpl_scalar_rc`；
   - `HANDLED + MWr`：计数后继续轮询，不发 Completion；
   - `ERROR`：记录 UVM/AIP error，不构造 CQ TLP。

后门读不使用 `vip_tag_to_qemu_tag`，避免与真实 DUT completion 路径混淆。原路径 tag 映射、
CQ/CC 和统计保持不变。

reset/shutdown 时 driver 调 service `flush(reason)`。服务状态报告纳入 test report phase 或显式命令。

## 16. 完成语义

### 16.1 MRd

只有 `bridge_vcs_send_cpl_scalar_rc` 成功后，后门读才算已回复 QEMU。Completion 使用原
QEMU tag、固定 4B 长度和从行内 offset 读取的完整 DWORD；QEMU 插件负责从该 DWORD
提取原始 1/2/4B CPU read。发送失败为 `ERROR`。

### 16.2 MWr

PCIe Memory Write 是 posted request，QEMU 不等待 Completion。捕获 chunk 成功即处理完该
MWr；完整行 writer 成功才表示逻辑表项已提交。Generic deposit 成功返回即完成，不做 readback。

### 16.3 回退边界

- 查表未命中、PF/BAR 不匹配、不支持的格式且尚未接收数据：允许 `MISS` 回退；
- 已更新聚合缓存、开始 HDL read/deposit 或进入 custom callback 后：失败必须 `ERROR`，禁止回退；
- 该边界避免同一写既后门生效又通过 DUT产生副作用，或同一读收到两个 Completion。

## 17. 统计

至少维护：

```text
read_hit
write_hit
miss
rows_committed
hdl_read_error
hdl_write_error
callback_error
incomplete_discard
duplicate_chunk
completion_error
```

统计按 RC 和 region 分层，并提供总计。

## 18. 验证策略

### 18.1 AIP Core 单测

- INI 多 region、重叠/非法配置 fail closed；
- 128/256/1024-bit 表；
- 高到低、低到高和交错 DWORD 写；
- Byte Enable；
- pure data、parity、SECDED；
- 1B/4B 保护粒度；
- prefix/interleaved；
- custom codec；
- generic HDL writer/reader；
- custom index-routing writer/reader；
- duplicate chunk；
- incomplete flush；
- 读期间存在半行缓存时返回已提交 RTL 值；
- DEBUG/TRACE 格式和大数截断。

### 18.2 CoSim SV 单测

- 开关关闭；
- service 未注册；
- PF1/VF/其他 BAR 返回 MISS；
- BAR 尚未枚举返回 MISS；
- PF0 BAR0 region hit；
- MRd 直接 Completion，tag/length/data 正确且 CQ 计数不增；
- MWr 不发送 Completion；
- service ERROR 不回退；
- 1/2/4B 和 Byte Enable；
- 原 CQ/DUT/CC 路径回归不变。

### 18.3 真实联仿

按项目规则在 VCS 仿真主机执行：

- QEMU 驱动完整写一行，确认 RTL 只在收齐后得到一次完整 physical word；
- QEMU 4B 读回正确；
- 开启后门时命中请求不进入 CQ；
- 关闭后门时相同流量完整经过 DUT；
- 多 index 交错；
- parity/ECC 数据和 HIGH/DEBUG 日志；
- `vio_notify` 普通 index、`idx % 16 == 15`、`idx % 256 == 255`，检查 L3/L2/L1
  RAM 路由、物理 index和值。

## 19. 实施拆分

实现计划应分成两个独立交付面，但保持接口契约一致：

1. **AIP Core：** parser、宽表聚合、codec、generic/custom writer/reader、参数日志命令和测试；
2. **CoSim：** 抽象服务包、DPI 字段补齐、PF0 BAR0 gating、request loop 分流、direct
   Completion 和测试；
3. **用户参考：** AIP-to-CoSim adapter、示例 INI、generic table 示例、`vio_notify` custom
   writer/reader 示例。

用户测试自行组合两个仓库；`cosim-platform` 不管理 AIP Core 的源码位置。

## 20. 验收标准

- 无任何新 plusarg、无 service 注册时，现有测试和 CQ/DUT/CC 数据流字节等价；
- PF0 BAR0 命中读无需进入 DUT 即能正确回复 QEMU；
- 参数化宽表写只在完整逻辑行收齐后提交；
- 128/256/1024 bit、none/parity/SECDED、1B/4B、prefix/interleaved 均有测试；
- 特殊表可通过 custom writer 按 index 选择多个 RAM 宏路径并更新 L3/L2/L1；
- 错误不会触发重复执行或双 Completion；
- DEBUG 日志可看见捕获数据、完整逻辑行、保护位、最终 physical word 和 writer 路由；
- 映射错误整体禁用后门，原 CQ 路径仍可用。
