# VCS 对接指南 — 如何搭建自己的 VCS 环境与 QEMU 通信

本文档面向需要**自行搭建 VCS 仿真环境**并与 CoSim QEMU 对接的用户。
涵盖通信架构、启动参数、DPI-C 接口、数据格式，以及从零对接的步骤。

---

## 1. 通信架构总览

```
┌──────────────────────┐          ┌──────────────────────┐
│       QEMU 侧        │          │       VCS 侧         │
│  (cosim-pcie-rc 设备) │          │  (SystemVerilog TB)  │
│                      │          │                      │
│  bridge_qemu.c       │◄────────►│  bridge_vcs.c        │
│  (C 库，编译进 QEMU)  │  通信层  │  (DPI-C，编译进 VCS) │
└──────────────────────┘          └──────────────────────┘
         │                                  │
         │     方式一: SHM + Unix Socket     │
         │     方式二: TCP (跨机)            │
         │                                  │
```

**两种通信模式：**

| 模式 | 适用场景 | QEMU 参数 | VCS 参数 |
|------|----------|-----------|----------|
| SHM  | 同机调试 | `shm_name=/cosim0,sock_path=/tmp/cosim0.sock` | `+SHM_NAME=/cosim0 +SOCK_PATH=/tmp/cosim0.sock` |
| TCP  | 跨机部署 | `transport=tcp,port_base=9100,instance_id=0` | `+transport=tcp +REMOTE_HOST=<QEMU_IP> +PORT_BASE=9100 +INSTANCE_ID=0` |

---

## 2. QEMU 侧启动参数

QEMU 通过 `-device` 参数挂载 cosim PCIe 设备：

### SHM 模式（同机）
```bash
qemu-system-x86_64 -M q35 -m 512M -smp 1 \
    -kernel guest/images/ubuntu/vmlinuz \
    -drive file=guest/images/ubuntu/rootfs.ext4,format=raw,if=none,id=rootdisk \
    -device virtio-blk-pci,drive=rootdisk,addr=0x10 \
    -append 'console=ttyS0 root=/dev/vda rw' \
    -device cosim-pcie-rc,shm_name=/cosim0,sock_path=/tmp/cosim0.sock \
    -nographic
```

### TCP 模式（跨机）
```bash
qemu-system-x86_64 -M q35 -m 512M -smp 1 \
    -kernel guest/images/ubuntu/vmlinuz \
    -drive file=guest/images/ubuntu/rootfs.ext4,format=raw,if=none,id=rootdisk \
    -device virtio-blk-pci,drive=rootdisk,addr=0x10 \
    -append 'console=ttyS0 root=/dev/vda rw' \
    -device cosim-pcie-rc,transport=tcp,port_base=9100,instance_id=0 \
    -nographic
```

### cosim-pcie-rc 设备属性一览

| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `shm_name` | string | 无 | POSIX SHM 名称，如 `/cosim0`（SHM 模式必填） |
| `sock_path` | string | 无 | Unix Socket 路径，如 `/tmp/cosim0.sock`（SHM 模式必填） |
| `transport` | string | 无 | 传输模式：不填=SHM，`tcp`=TCP |
| `remote_host` | string | 无 | TCP 模式远程地址（VCS 侧连 QEMU 时 VCS 填） |
| `port_base` | uint32 | 9100 | TCP 模式端口基数 |
| `instance_id` | uint32 | 0 | 实例编号（多实例时区分，影响端口分配） |
| `debug` | bool | false | 运行时调试打印开关 |

### TCP 端口分配规则

QEMU（server 侧）监听 3 个端口，按 `port_base + instance_id * 3` 计算：

```
ctrl_port = port_base + instance_id * 3       # 控制通道（sync 消息）
data_port = port_base + instance_id * 3 + 1   # 数据通道（TLP/Completion）
aux_port  = port_base + instance_id * 3 + 2   # 辅助通道（DMA/MSI）
```

示例：`port_base=9100, instance_id=0` → 端口 9100, 9101, 9102
示例：`port_base=9100, instance_id=1` → 端口 9103, 9104, 9105

### 连接超时

QEMU 启动后等待 VCS 连接，默认超时 180 秒（3 分钟）。
可通过环境变量调整：

```bash
export COSIM_CONNECT_TIMEOUT=300  # 5 分钟
```

---

## 3. VCS 侧对接

### 3.1 编译 bridge 库

VCS 需要编译并链接 `bridge_vcs.c`（通过 DPI-C 调用）。

**所需源文件：**
```
bridge/vcs/bridge_vcs.c          # DPI-C 函数实现（主文件）
bridge/vcs/sock_sync_vcs.c       # Socket 同步通信（VCS 侧）
bridge/common/shm_layout.c       # SHM 内存布局
bridge/common/ring_buffer.c      # 环形缓冲区
bridge/common/cosim_types.h      # TLP/Completion/DMA 数据结构
bridge/common/shm_layout.h       # SHM 内存布局定义
bridge/common/cosim_topology.h   # SR-IOV 拓扑定义
bridge/common/cosim_transport.h  # 传输抽象层
bridge/common/transport_tcp.c    # TCP 传输实现（跨机模式）
bridge/common/transport_shm.c    # SHM 传输实现（同机模式）
bridge/qemu/sock_sync.h          # Socket API 声明
```

**VCS 编译命令示例：**
```bash
vcs -sverilog -full64 \
    +define+UVM_NO_DEPRECATED \
    -CFLAGS "-I${PROJECT_DIR}/bridge/common -I${PROJECT_DIR}/bridge/qemu" \
    ${PROJECT_DIR}/bridge/vcs/bridge_vcs.c \
    ${PROJECT_DIR}/bridge/common/shm_layout.c \
    ${PROJECT_DIR}/bridge/common/ring_buffer.c \
    ${PROJECT_DIR}/bridge/common/transport_tcp.c \
    ${PROJECT_DIR}/bridge/common/transport_shm.c \
    your_testbench.sv \
    -o simv
```

### 3.2 VCS 启动参数（plusargs）

VCS 通过 `$value$plusargs` 读取运行时参数：

**SHM 模式：**
```bash
./simv +SHM_NAME=/cosim0 +SOCK_PATH=/tmp/cosim0.sock
```

**TCP 模式：**
```bash
./simv +transport=tcp +REMOTE_HOST=192.168.1.100 +PORT_BASE=9100 +INSTANCE_ID=0
```

**全部 plusargs 列表：**

| 参数 | 说明 |
|------|------|
| `+SHM_NAME=<name>` | POSIX SHM 名称，必须和 QEMU 侧一致 |
| `+SOCK_PATH=<path>` | Unix Socket 路径，必须和 QEMU 侧一致 |
| `+transport=tcp` | 使用 TCP 模式 |
| `+REMOTE_HOST=<ip>` | QEMU 所在机器的 IP 地址 |
| `+PORT_BASE=<port>` | 端口基数，必须和 QEMU 侧一致 |
| `+INSTANCE_ID=<id>` | 实例编号，必须和 QEMU 侧一致 |
| `+ETH_SHM=<name>` | 以太网数据面 SHM（双实例对打时 VCS 之间通信） |
| `+ETH_ROLE=0\|1` | 以太网角色：0=创建 SHM，1=加入已有 SHM |
| `+ETH_CREATE=0\|1` | 是否创建以太网 SHM |
| `+MAC_LAST=<byte>` | MAC 地址末字节（区分多实例） |
| `+NUM_PFS=<n>` | PF 数量（SR-IOV 模式） |
| `+MAX_VFS=<n>` | 每个 PF 最大 VF 数量 |
| `+SIM_TIMEOUT_MS=<ms>` | 仿真超时（毫秒） |
| `+NO_WAVE` | 不 dump 波形 |

---

## 4. DPI-C 接口参考

VCS 侧通过以下 DPI-C 函数与 bridge 交互。以下是完整的调用顺序和每个函数的说明。

### 4.1 初始化

```c
// SHM 模式初始化
int bridge_vcs_init(const char *shm_name, const char *sock_path);
//   shm_name:  POSIX SHM 名称，如 "/cosim0"
//   sock_path: Unix Socket 路径，如 "/tmp/cosim0.sock"
//   返回: 0=成功, -1=失败

// TCP 模式初始化（扩展版）
int bridge_vcs_init_ex(const char *transport_type,
                       const char *remote_host, int port_base,
                       int instance_id,
                       const char *shm_name, const char *sock_path);
//   transport_type: "tcp" 或 "shm"
//   remote_host:    QEMU IP（TCP 模式）
//   port_base:      端口基数（TCP 模式，默认 9100）
//   instance_id:    实例编号
//   shm_name/sock_path: SHM 模式参数（TCP 模式时可传 NULL）
//   返回: 0=成功, -1=失败
```

### 4.2 拓扑设置（SR-IOV 多 Function 模式）

```c
// 设置每个 PF 的拓扑信息（在仿真开始前调用）
void bridge_vcs_set_pf_topology(
    int pf_idx,                           // PF 编号 (0-based)
    int bdf,                              // PCIe Bus:Device:Function
    int num_vfs, int vf_device_id,        // VF 配置
    int vendor_id, int device_id,         // PCI ID
    int msix_vectors, int vf_msix_vectors,// MSI-X 向量数
    unsigned long long pf_bar0, ... pf_bar5,  // PF BAR 大小
    unsigned long long vf_bar0, ... vf_bar5); // VF BAR 大小

// 完成拓扑设置
void bridge_vcs_finalize_topology(int num_pfs, int tag_width);
//   num_pfs:   PF 总数
//   tag_width: TLP tag 宽度（1=8bit, 2=10bit）
```

### 4.3 TLP 收发（核心循环）

```c
// 轮询 QEMU 发来的 TLP 请求（非阻塞）
int bridge_vcs_poll_tlp(
    unsigned char *tlp_type,    // [out] TLP 类型（见 tlp_type_t 枚举）
    unsigned long long *addr,   // [out] 目标地址
    unsigned int *data,         // [out] 数据（最多 16 个 DW = 64 字节）
    int *len,                   // [out] 数据长度（DW 数）
    int *tag);                  // [out] TLP tag（用于 Completion 匹配）
//   返回: 1=有 TLP, 0=无 TLP

// 获取当前 TLP 的路由信息（poll_tlp 返回 1 后调用）
int bridge_vcs_get_tlp_target_bdf(void);     // 目标 BDF
int bridge_vcs_get_tlp_requester_id(void);   // 请求者 BDF

// 发送 Completion 给 QEMU（响应 CfgRd/MRd 请求）
int bridge_vcs_send_completion(
    int tag,                    // 原始请求的 tag
    const unsigned int *data,   // 返回数据
    int len);                   // 数据长度（DW 数）
//   返回: 0=成功, -1=失败
```

### 4.4 DMA（VCS 主动读写 Guest 内存）

```c
// 同步 DMA 读（VCS 从 Guest 内存读数据）
int bridge_vcs_dma_read_sync(
    unsigned long long host_addr,  // Guest 物理地址
    unsigned int *data,            // [out] 读取的数据
    int len);                      // 长度（字节）
//   返回: 0=成功, -1=失败

// 同步 DMA 写（VCS 向 Guest 内存写数据）
int bridge_vcs_dma_write_sync(
    unsigned long long host_addr,  // Guest 物理地址
    const unsigned int *data,      // 要写的数据
    int len);                      // 长度（字节）
//   返回: 0=成功, -1=失败
```

### 4.5 中断

```c
// 触发 MSI 中断
int bridge_vcs_raise_msi(int vector);
//   vector: MSI-X 向量编号
//   返回: 0=成功, -1=失败
```

### 4.6 清理

```c
void bridge_vcs_cleanup(void);    // SHM 模式清理
void bridge_vcs_cleanup_ex(void); // TCP 模式清理
```

---

## 5. 通信协议详解

### 5.1 SHM 内存布局

```
偏移           大小      用途
0x00000000    4KB       控制区 (cosim_ctrl_t)
0x00001000    1MB       请求环 (QEMU→VCS TLP)
0x00101000    1MB       完成环 (VCS→QEMU Completion)
0x00201000    256KB     DMA 请求环 (VCS→QEMU)
0x00241000    256KB     DMA 完成环 (QEMU→VCS)
0x00281000    64KB      MSI 队列
0x00291000    ~13.4MB   DMA 数据缓冲区
总计: 16MB
```

### 5.2 同步消息类型

QEMU 和 VCS 通过 Unix Socket (SHM模式) 或 TCP ctrl_port 交换同步消息：

```c
typedef struct {
    sync_msg_type_t type;    // 消息类型
    uint32_t        payload; // 负载
} sync_msg_t;                // 8 字节
```

| type 值 | 名称 | 方向 | 说明 |
|---------|------|------|------|
| 0 | TLP_READY | QEMU→VCS | 请求环有新 TLP |
| 1 | CPL_READY | VCS→QEMU | 完成环有新 Completion |
| 2 | MODE_SWITCH | 双向 | 切换仿真模式 |
| 3 | SHUTDOWN | 双向 | 关闭连接 |
| 4 | DMA_REQ | VCS→QEMU | DMA 请求 |
| 5 | DMA_CPL | QEMU→VCS | DMA 完成 |
| 6 | MSI | VCS→QEMU | MSI 中断 |
| 0x10 | QUERY_TOPOLOGY | QEMU→VCS | 查询 SR-IOV 拓扑 |
| 0x11 | TOPOLOGY_RESP | VCS→QEMU | 拓扑响应 |
| 0x12 | VF_EVENT | QEMU→VCS | VF 热插拔事件 |

### 5.3 TLP 数据结构

```c
typedef struct {
    uint8_t   type;           // TLP 类型（见 tlp_type_t）
    uint8_t   _pad_type;
    uint16_t  tag;            // 请求 tag（Completion 匹配用）
    uint16_t  len;            // 数据长度
    uint8_t   msg_code;       // Message code
    uint8_t   atomic_op_size;
    uint16_t  vendor_id;
    uint16_t  requester_id;   // 请求者 BDF
    uint16_t  target_bdf;     // 目标设备 BDF
    uint16_t  _pad_bdf;
    uint64_t  addr;           // 目标地址
    uint8_t   data[64];       // 数据负载（最多 64 字节）
    uint64_t  dma_offset;
    uint64_t  timestamp;
    uint8_t   first_be;       // First DW Byte Enable
    uint8_t   last_be;        // Last DW Byte Enable
    uint8_t   _reserved[6];
} tlp_entry_t;                // 总计 112 字节
```

### 5.4 TLP 类型枚举

| 值 | 名称 | 说明 |
|----|------|------|
| 0 | TLP_MWR | Memory Write（Posted，不需要 Completion） |
| 1 | TLP_MRD | Memory Read（需要 Completion 返回数据） |
| 2 | TLP_CFGWR0 | Config Write Type 0（需要 Completion） |
| 3 | TLP_CFGRD0 | Config Read Type 0（需要 Completion 返回数据） |
| 4 | TLP_CPL | Completion without Data |
| 5 | TLP_CFGWR1 | Config Write Type 1 |
| 6 | TLP_CFGRD1 | Config Read Type 1 |
| 9 | TLP_CPLD | Completion with Data |

---

## 6. 典型对接流程（从零开始）

### 6.1 最小可运行示例（SHM 模式）

**SystemVerilog testbench 伪代码：**

```systemverilog
import "DPI-C" function int    bridge_vcs_init(string shm_name, string sock_path);
import "DPI-C" function int    bridge_vcs_poll_tlp(
    output byte unsigned tlp_type, output longint unsigned addr,
    output int unsigned data[16], output int len, output int tag);
import "DPI-C" function int    bridge_vcs_send_completion(
    int tag, input int unsigned data[16], int len);
import "DPI-C" function void   bridge_vcs_cleanup();

module cosim_tb;
    string shm_name, sock_path;

    initial begin
        // 读取 plusargs
        if (!$value$plusargs("SHM_NAME=%s", shm_name)) shm_name = "/cosim0";
        if (!$value$plusargs("SOCK_PATH=%s", sock_path)) sock_path = "/tmp/cosim0.sock";

        // 初始化 bridge
        if (bridge_vcs_init(shm_name, sock_path) < 0) begin
            $display("ERROR: bridge init failed");
            $finish;
        end
        $display("Bridge connected!");

        // 主循环：轮询 TLP 并响应
        forever begin
            byte unsigned tlp_type;
            longint unsigned addr;
            int unsigned data[16];
            int len, tag;

            if (bridge_vcs_poll_tlp(tlp_type, addr, data, len, tag)) begin
                case (tlp_type)
                    3: begin // TLP_CFGRD0 — 配置空间读
                        int unsigned cpl_data[16];
                        cpl_data[0] = read_config_reg(addr);
                        bridge_vcs_send_completion(tag, cpl_data, 1);
                    end
                    2: begin // TLP_CFGWR0 — 配置空间写
                        write_config_reg(addr, data[0]);
                        int unsigned cpl_data[16];
                        bridge_vcs_send_completion(tag, cpl_data, 0);
                    end
                    1: begin // TLP_MRD — 内存读
                        int unsigned cpl_data[16];
                        read_device_memory(addr, cpl_data, len);
                        bridge_vcs_send_completion(tag, cpl_data, len);
                    end
                    0: begin // TLP_MWR — 内存写
                        write_device_memory(addr, data, len);
                        // MWr 是 Posted，不需要 Completion
                    end
                endcase
            end

            #10; // 仿真时钟推进
        end
    end

    final begin
        bridge_vcs_cleanup();
    end
endmodule
```

### 6.2 启动顺序

```
时序（必须严格遵守）：
  1. 启动 QEMU        → 创建 SHM，监听 Socket，等待 VCS 连接（最多 180 秒）
  2. 启动 VCS (simv)   → 打开 SHM，连接 Socket
  3. QEMU 检测到连接   → 开始 Guest 启动，发送 CfgRd TLP 枚举设备
  4. VCS 主循环响应 TLP → Guest 枚举 PCIe 设备
  5. Guest 启动完成     → 可以使用 cosim 网卡
```

**关键：QEMU 必须先启动。** QEMU 创建 SHM 并 listen Socket，VCS connect 到它。
如果 VCS 先启动会报 `Failed to open SHM` 或 `Failed to connect Socket`。

### 6.3 双实例对打

```
QEMU1 (shm=/cosim_d0, sock=cosim_d0.sock)  ←→  VCS1 (RoleA, MAC=01)
QEMU2 (shm=/cosim_d1, sock=cosim_d1.sock)  ←→  VCS2 (RoleB, MAC=02)
                                                      │
                                              VCS1 ←ETH_SHM→ VCS2
                                              （以太网数据面互通）
```

每对 QEMU↔VCS 使用**独立的** SHM 和 Socket（或独立的 TCP instance_id）。
两个 VCS 之间通过共享的 `ETH_SHM` 交换以太网帧。

---

## 7. 常见问题

**Q: QEMU 报 "waiting for VCS connection" 后超时退出？**
A: VCS 未在超时时间内连接。检查 SHM 名称/Socket 路径是否一致，或延长超时：
```bash
export COSIM_CONNECT_TIMEOUT=600
```

**Q: VCS 报 "Failed to open SHM"？**
A: QEMU 必须先启动（它创建 SHM）。确认 QEMU 已运行且 SHM 名称一致。

**Q: TLP poll 始终返回 0？**
A: 检查仿真时钟是否在推进（`#10` 等）。bridge 的 poll 是非阻塞的，需要持续调用。

**Q: TCP 模式连不上？**
A: 检查防火墙，确认端口 `port_base` 到 `port_base+2` 可达。`instance_id` 两侧必须一致。

**Q: 如何支持 SR-IOV？**
A: 在 `bridge_vcs_init` 后、仿真主循环前调用 `bridge_vcs_set_pf_topology` 和 `bridge_vcs_finalize_topology`。
