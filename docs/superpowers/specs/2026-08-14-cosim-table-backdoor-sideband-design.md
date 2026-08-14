# CoSim 表项语义后门 Sideband 设计

**日期：** 2026-08-14

**状态：** 对话设计已批准，待书面规格评审

**范围：** Guest 自定义驱动、QEMU CoSim 设备、QEMU/VCS table transport、VCS/SV table handler

## 1. 背景

Guest 驱动目前通过 `wr32_for_each()` 或 `wr32_for_high_order()` 把一个宽表项拆成多次
4B MMIO write。每个 write 经 QEMU、CoSim、PCIe CQ 和完整 DUT 数据通路后才生效。对于
128/256/1024-bit 表项和数百、数千深度的表，完整 RTL 路径过慢。

驱动调用这些宏时已经持有完整结构体或连续表 buffer，因此应把完整数据作为一笔语义事务
传给 VCS。VCS 根据 PF/VF、BAR 和 BAR 内 offset 找到表 handler，再由 handler 直接写
DUT RAM 后门。DUT 专用的层级路径、多 RAM 镜像、index 分支以及 ECC/parity 都留在 SV
环境处理。

本设计取代
`docs/superpowers/specs/2026-08-12-pf0-bar0-backdoor-design.md` 中“在普通 BAR TLP
路径被动聚合多个 DWORD”的方案，也不依赖 `aip_core`。旧前门功能必须完整保留。

## 2. 目标

- 后门写一次携带完整表项或连续多条表项，不在 QEMU 被动等待 DWORD 收齐；
- PF0 BAR0/BAR1 的所有 DUT 地址仍然有效，不预留或复用任何控制地址；
- 使用 QEMU-only PCIe 控制 endpoint 传递 descriptor 和完整 DMA buffer；
- VCS 只按逻辑地址路由到 handler，不在映射文件记录 DUT 层级路径；
- handler 支持单 RAM、多 RAM、按 index 选择不同路径以及 `none/ecc/parity/custom`；
- 表读取仍按普通 PF BAR 4B 访问，命中 route 时由 VCS 后门直接返回；
- 用户可通过启动参数选择后门或完整保留的前门；
- 未开始后门执行时允许自动回退，执行状态不确定或已经开始时禁止重复前门；
- 协议从第一版保留多 RC、多 DUT、多 PF 和多 VF 的目标身份字段。

## 3. 非目标

- 不把控制寄存器放入 DUT PF0 BAR0、BAR1 或其他 DUT BAR；
- 不把控制 endpoint 伪装成 DUT 的另一个 PF、VF 或同 slot function；
- 不在 route 文件表达 HDL path、RAM 宏或保护位物理布局；
- 不保证多次 RAM deposit 的事务回滚；
- 第一版不启用非约定 RC0/device0/PF0 BAR0/BAR1 的后门路由；
- 不改变普通 TLP、DMA、MSI 或 Ethernet 现有线格式。

## 4. 方案比较

### 4.1 独立控制 endpoint 和 DMA descriptor（采用）

完整表项或整表只需要一次或少量 doorbell。驱动能得到明确完成状态，地址未命中时能安全
回退。控制设备独立于 DUT PF，不占用 DUT 地址空间。

### 4.2 普通 BAR 4B write 被动聚合（不采用）

实现较简单，但 1024-bit 表每条仍产生 32 次 Guest MMIO。QEMU看不到驱动函数边界，只能
根据有效字节 mask 猜测何时收齐，并且 posted write 无法把 handler 错误可靠返回驱动。

### 4.3 PF 配置空间 VSEC 或 ivshmem/virtio sideband（不采用）

VSEC 会改变 DUT PF 配置空间并可能与真实 capability 冲突。ivshmem/virtio 可以工作，但
Guest 和 QEMU 接入面比专用 PCI endpoint 更大。

## 5. 总体架构

```text
Guest 自定义驱动
  |- 前门模式
  |    `- DUT PF BAR -> existing CoSim TLP -> CQ -> DUT
  |
  `- 后门模式
       |- write -> CoSim table control endpoint
       |          -> coherent DMA descriptor/payload
       |          -> QEMU table transport
       |          -> VCS route + SV handler.write_entry()
       |
       `- read  -> DUT PF BAR 4B read
                  -> QEMU route cache
                  -> VCS handler.read_dword()
                  -> direct QEMU MMIO return
```

职责边界如下：

- **Guest 驱动：** 知道完整原始数据、目标 BAR/offset 和前门 DWORD 顺序；负责选择前门或
  后门，并在安全状态下自动回退。
- **QEMU table control endpoint：** 从 Guest coherent DMA 内存读取 descriptor 和 payload，
  校验本地 route cache，向 VCS发送语义请求并同步返回状态。
- **table transport：** 独立承载 route、长 payload、4B read 和 completion；不复用固定
  64B 的 `tlp_entry_t`。
- **VCS table service：** 解析唯一 route 文件、同步 route 到 QEMU、切割批量数据并调用
  已注册 handler。
- **SV handler：** 管理 DUT path、RAM 选择、保护位、deposit、4B read 和 HIGH 日志。

## 6. 控制 endpoint 与 PCIe 拓扑

控制 endpoint 是 QEMU 创建的独立虚拟 PCIe endpoint，不是真实 DUT function。它挂在所
服务 RC 的虚拟 PCIe bus 上，并使用独立 slot/BDF：

```text
RC0
  |- DUT0 PF0/PF1/VFs
  `- CoSim table control 0

RC1
  |- DUT1 PF0/PF1/VFs
  `- CoSim table control 1
```

原则如下：

- 每条 RC/CoSim transport 实例一个控制 endpoint；
- 同一 RC 下多个 DUT、PF 和 VF 共享该 endpoint；
- 控制 endpoint 不使用 DUT 的 vendor/device 身份，驱动按专用 PCI ID 发现它；
- BDF 和控制 BAR base 均由 Guest PCI core 动态分配，驱动不得硬编码；
- 控制 endpoint 通过 QEMU 的 `rc_id` 属性与 table transport 实例绑定；
- Guest 驱动根据 PCI domain 和上游 root port 把目标 DUT 与所属控制 endpoint 匹配；
- coherent DMA buffer 必须由控制 endpoint 的 `struct pci_dev` 分配，保证 IOMMU requester
  上下文正确。

第一版只在 RC0/device0 上启用 PF0 BAR0/BAR1 route。目标字段和 endpoint 组织不限制未来
扩展。

控制endpoint支持代码编译进同一个Guest自定义驱动交付物，并在驱动内部维护每RC controller
registry；不要求额外的Guest用户态程序。控制endpoint和DUT PF的probe顺序不构成依赖，目标
写发生时controller尚未ready就走前门。

## 7. Guest 驱动接入

### 7.1 统一写入口

把两个现有宏的循环体收敛到一个有返回值的函数：

```c
enum dpu_table_write_result
dpu_table_write(struct dpu_hw *hw,
                unsigned int bar,
                u64 bar_offset,
                const void *data,
                u32 length,
                enum dpu_write_order fallback_order);
```

`wr32_for_each()` 传 `LOW_TO_HIGH`，`wr32_for_high_order()` 传 `HIGH_TO_LOW`。后门协议不
传 DWORD 顺序；该字段只用于未命中时重放原前门循环。

函数行为：

1. `table_backdoor=0` 或没有 ready controller：按原顺序执行前门；
2. controller ready：提交完整 `data[0:length]`；
3. 返回 `NOT_READY/NO_ROUTE/UNSUPPORTED/SLOT_BUSY`：按原顺序执行前门；
4. 返回 `SUCCESS`：不再生成 PF BAR write；
5. 返回执行错误或未知状态：打印错误且不得前门重放。

宏继续可作为普通 statement 使用；旧调用点可以忽略返回值。需要跳过 readback/retry 的
路径改为显式检查返回值。

### 7.2 单条和批量

- 通用入口把一次宏调用视为一笔完整语义事务；
- 调用者传入的 `length` 可以是 16/32/128B 等单条大小；
- 对已经持有整张连续软件表的函数增加 batch 调用；
- 第一版把 QID/vio-notify 这类已持有完整数组的路径改为整表或分块提交；
- 其他表先按每次宏调用一笔事务，无需逐个重写调用点。

53 上参考驱动当前在 QID 路径逐条调用 `wr32_for_high_order()`，随后 `udelay(5)`、
`rd32_for_each()` 和重试。后门 `SUCCESS` 已表示 handler 完成，因此该路径跳过延时、逐
DWORD 读回和重试。自动前门回退时保留原校验流程。

### 7.3 控制设备内存

控制设备 probe 时预分配 descriptor/payload slots，提交路径不动态分配可睡眠内存。每个
slot 包含：

```text
slot_state
transaction_id
target identity
BAR/offset/length
payload
completion status
failed_index
committed_entry_count
handler_error_code
```

驱动通过原子状态占用空闲 slot，复制数据后执行 `dma_wmb()` 并写 doorbell。没有空闲
slot 时请求尚未被接受，可安全走前门。默认 slot payload 上限由控制设备 capability 给出；
更大的 batch 必须在完整表项边界分块。

## 8. 目标 descriptor

Guest→QEMU descriptor 至少包含：

```text
magic
protocol_version
header_bytes
transaction_id
rc_id
device_instance
PCI domain
target_bdf
target_type          PF or VF
pf_index
vf_index
bar_index
bar_offset
byte_len
payload_offset
flags
```

`device_instance` 是同一RC下的稳定逻辑DUT编号；`target_bdf`是该次运行中的动态PCI身份。
QEMU必须根据当前topology重新验证二者对应关系，以及PF/VF身份、所属RC和BAR aperture，
不能只信任Guest提供的派生编号。BDF在每笔事务中取当前 `struct pci_dev` 值，不跨VF
disable/enable缓存。

## 9. Table transport

table transport 是独立于现有普通 CoSim transport 的逻辑通道。关闭后门时不创建该通道，
从而不改变现有 SHM layout、TCP帧或 `tlp_entry_t` ABI。

消息类型：

```text
HELLO
CAPABILITY
ROUTE_TABLE
WRITE_BEGIN
WRITE_DATA
WRITE_END
READ_DWORD
COMPLETION
SHUTDOWN
```

长 payload 使用带 transaction ID、fragment offset、fragment length 和总长度的分片帧。
VCS必须收齐、校验无重叠且覆盖完整长度后，才能开始任何 handler task。乱序、重复、缺失或
越界分片在执行前失败。

每个 RC 使用独立 table channel。TCP和SHM实现提供相同消息语义；具体socket、SHM名称和
端口由启动脚本按RC派生，且只在 `--table-backdoor=on` 时创建。

## 10. Route 配置与同步

VCS是route的唯一配置源。启动时执行：

1. VCS解析并完整校验route文件；
2. 用户test注册所有handler；
3. table service验证每个route的handler存在且capability匹配；
4. VCS把精简route表和版本hash同步给QEMU；
5. QEMU原子替换本地cache后才把控制endpoint标记为ready。

配置示例：

```ini
[route.vio_notify]
rc = 0
device = 0
target = pf0
bar = 0
start = 0x1000
end = 0x2000
entry_bytes = 16
stride_bytes = 16
index_base = 0
handler = vio_notify
```

`start`包含，`end`不包含。route只包含逻辑路由信息，不包含HDL path、RAM、ECC或
parity布局。所有route地址都是BAR内offset，绝不使用Guest动态分配的绝对BAR base。

启动校验包括：

- route名称唯一；
- 同一目标的地址范围不重叠；
- `start < end`；
- `entry_bytes > 0` 且 `stride_bytes >= entry_bytes`；
- start、end和stride不会发生整数溢出；
- device、target、BAR和RC属于当前topology；
- handler已注册；
- handler声明的read/write capability满足route用途。

任何配置错误使整套table service保持not-ready。QEMU不安装部分route，Guest全部走前门。
第一版不热更新route。

## 11. 地址计算与数据切割

写请求必须满足：

```text
(bar_offset - route.start) % stride_bytes == 0
byte_len % entry_bytes == 0
entry_count = byte_len / entry_bytes
first_index = index_base + (bar_offset - route.start) / stride_bytes
last_entry_end = bar_offset + (entry_count - 1) * stride_bytes + entry_bytes
last_entry_end <= route.end
```

第 `n` 条数据映射为：

```text
raw_data[n * entry_bytes +: entry_bytes] -> first_index + n
```

因此 `stride_bytes > entry_bytes` 时，batch buffer仍连续保存逻辑表项，VCS用stride跳过
地址空洞。请求不得跨越两个route。

字节打包固定为小端字节序：

```systemverilog
packed_entry[8*b +: 8] = raw_data[b];
```

传输的是驱动内存中的原始结构体字节，与原宏从高DWORD还是低DWORD开始写无关。

## 12. VCS table service 与 handler registry

字符串不能在SystemVerilog运行时直接调用任意task，因此使用注册对象：

```systemverilog
virtual class cosim_table_handler;
    pure virtual task write_entry(
        input  cosim_table_context ctx,
        input  longint unsigned index,
        input  byte unsigned raw_data[],
        output cosim_table_result result);

    virtual task read_dword(
        input  cosim_table_context ctx,
        input  longint unsigned index,
        input  int unsigned byte_offset,
        output bit [31:0] data,
        output cosim_table_result result);

    virtual function bit supports_read();
endclass
```

用户test注册：

```systemverilog
table_service.register_handler("vio_notify", vio_notify_handler);
table_service.register_handler("qid_map", qid_map_handler);
```

service切割batch后按index递增顺序调用 `write_entry()`。每个handler封装：

- index到DUT层级、RAM和物理index的映射；
- 同一逻辑条目写一个或多个RAM；
- `none/parity/ecc/custom`保护模式；
- 保护位与原始数据的物理拼接；
- deposit宏或 `uvm_hdl_deposit()`；
- 4B读使用的权威RAM和数据解包；
- handler专用日志和错误详情。

公共SV包提供现有parity/ECC算法的复用接口，并保留custom codec callback。`none`直接使用
原始数据。保护模式不写入route；handler定义默认值，测试可用命令行按handler覆盖。

特殊多RAM handler应先计算完整原始值、保护位、所有目标路径和物理index，再执行deposit。
多次deposit中途失败无法回滚，必须返回 `EXEC_ERROR` 和已成功目标清单。

## 13. 4B读路径

表读取仍从目标DUT PF BAR发起普通1/2/4B CPU MMIO。QEMU先用route cache匹配：

- 未命中或handler不支持read：执行原MRd/CQ/DUT/Completion路径；
- 命中：发送 `READ_DWORD`，VCS调用 `handler.read_dword(index, byte_offset)`；
- 成功：QEMU按原CPU size和byte offset返回目标字节；
- handler已经开始后失败：记录错误并返回全1，不再发送第二个MRd。

QEMU先把CPU访问规范化到包含它的4B DWORD，再计算：

```text
delta = aligned_bar_offset - route.start
index = index_base + delta / stride_bytes
row_offset = delta % stride_bytes
```

只有 `row_offset + 4 <= entry_bytes` 时才是后门read hit；stride空洞和跨表项DWORD按route
miss走前门。handler可以内部读取完整物理RAM word，但只向QEMU返回目标DWORD。QEMU再按
原始CPU size和byte enable提取1/2/4B结果。read不聚合完整表项。

## 14. 完成语义与错误边界

控制endpoint的doorbell MMIO回调同步等待VCS completion。QEMU在回调返回前把结果写入对应
DMA slot，驱动执行 `dma_rmb()` 后读取结果。

| 状态 | handler执行 | 驱动动作 |
|---|---:|---|
| `SUCCESS` | 全部完成 | 后门成功 |
| `NOT_READY` | 否 | 前门回退 |
| `NO_ROUTE` | 否 | 前门回退 |
| `UNSUPPORTED` | 否 | 前门回退 |
| `SLOT_BUSY` | 否 | 前门回退 |
| `EXEC_ERROR` | 可能部分完成 | 报错，不回退 |
| `TIMEOUT`/`UNKNOWN` | 无法确定 | 报错，不回退 |
| `TARGET_GONE` | 否 | 报错，不访问失效目标 |

只有明确证明没有开始后门task的状态可以自动前门回退。transport断开或超时不能证明SV未
执行，因此禁止回退。

批量失败completion必须包含 `failed_index`、`committed_entry_count`、handler error code
和detail。service遇到第一条失败后停止后续条目。

## 15. 并发、顺序和生命周期

- 驱动提交路径使用预分配slot和原子slot state，不使用可睡眠分配；
- slot不足时请求尚未被接受，安全前门回退；
- 同一RC、device instance、目标BDF、BAR和route的事务保持提交顺序；
- 不同RC可独立并行；不同目标可并行，但同一handler可自行声明串行要求；
- reset、shutdown和控制设备remove停止接受新请求，等待或标记现有事务状态；
- VF disable后route cache中的旧BDF立即失效；带旧generation的事务返回
  `TARGET_GONE`；
- transaction ID在每个controller实例内单调递增，回绕时不得与未完成ID重用。

## 16. 参数

用户入口：

```text
--table-backdoor=on|off
--table-map=/absolute/path/to/routes.ini
--table-protect handler=none|ecc|parity|custom
--table-log=error|info|high|trace
```

启动脚本负责转换为：

- Guest模块参数 `table_backdoor=0|1`；
- QEMU控制endpoint及每RC table transport参数；
- VCS plusargs `+COSIM_TABLE_ENABLE`、`+COSIM_TABLE_MAP`、日志和handler保护覆盖。

默认off。没有新参数时不创建设备、不连接table transport，也不改变Guest驱动原行为。

## 17. 日志与统计

日志等级：

- `ERROR`：协议、timeout、handler、codec和deposit失败；
- `INFO`：capability、route摘要、transaction结果和最终统计；
- `HIGH`：原始数据、条目切割、保护位、最终物理值、RAM分支和物理index；
- `TRACE`：每个transport fragment和每个ECC/parity group。

HIGH日志示例：

```text
TABLE_WR txn=31 rc=0 bdf=01:00.0 bar=0 off=0x1020 len=48
TABLE_SPLIT route=qid_map first_idx=2 count=3 entry_bytes=16
TABLE_ENTRY txn=31 idx=2 raw=<128-bit>
TABLE_PROTECT idx=2 mode=ecc check=<bits> physical=<value>
TABLE_DEPOSIT idx=2 ram=L3_2 physical_idx=17 result=SUCCESS
TABLE_COMPLETE txn=31 committed=3 status=SUCCESS
```

大数据打印受dump上限控制，超过上限只显示头尾并附总字节数。

统计至少包含：

```text
submitted
batch_entries
read_hit
write_success
frontdoor_fallback
no_route
unsupported
exec_error
timeout
bytes_transferred
per-route/per-handler counters
```

## 18. 验证

### 18.1 协议和route单测

- version/capability不匹配；
- 大小端和原始字节保持；
- 长payload分片、重复、缺失、乱序和越界；
- route边界、重叠、stride空洞和跨route；
- device instance、target BDF、PF/VF、BAR、RC和VF generation；
- timeout及所有completion状态。

### 18.2 SV单测

- 128/256/1024-bit表项；
- 单条和连续batch切割；
- 单RAM、多RAM和index选择不同层级；
- `none/ecc/parity/custom`；
- 保护位和物理拼接；
- 4B read及不支持read的route；
- 第N条失败后的committed count和停止行为；
- HIGH/TRACE数据与截断格式。

### 18.3 Guest/QEMU单测

- 参数off、控制设备缺失和VCS not-ready；
- `wr32_for_each`与`wr32_for_high_order`前门顺序字节等价；
- NO_ROUTE/UNSUPPORTED/SLOT_BUSY自动回退；
- EXEC_ERROR/TIMEOUT不回退；
- coherent DMA同步和slot并发；
- 单条、整表和超大batch按entry边界切分；
- 多RC controller选择和VF失效。

### 18.4 VCS联仿

按项目规则在 `10.11.10.53` 使用 `ubuntu` 登录，并在bash login环境下运行：

- 后门关闭时现有前门回归不变；
- QID整表后门写不产生DUT CQ流量；
- 4B后门读返回正确值；
- task失败、transport timeout和回退边界；
- 两个RC的route、transaction和RAM隔离；
- ECC/parity/none最终物理RAM值；
- 特殊表在普通index及层级边界index写入正确RAM；
- HIGH日志的raw、保护位、最终数据和RAM目标一致。

## 19. 验收标准

- 默认off时Guest、QEMU、CoSim和VCS既有功能行为不变；
- PF0 BAR0/BAR1不预留控制地址，也不改变DUT PF BAR布局；
- 一次普通后门提交携带完整表项，QID路径支持连续batch；
- 后门写不生成目标DUT CQ请求；
- VCS按route正确计算entry index并调用对应handler；
- 128/256/1024-bit、stride空洞、none/ECC/parity和多RAM均通过测试；
- 4B表读取可直接从handler返回QEMU；
- 未执行task时能够前门回退，已执行或状态未知时绝不重复执行；
- 协议可识别RC、DUT、PF、VF、BAR和offset，后续扩展不修改基本descriptor；
- 53服务器的默认前门和后门联仿均通过。
