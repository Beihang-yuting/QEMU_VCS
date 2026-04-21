# cosim-platform 跨机 TCP 传输层设计

## 目标

在不修改现有 SHM+Unix socket 代码的前提下，新增 TCP 传输层，支持 QEMU 和 VCS 分别运行在两台不同的 Ubuntu 机器上。运行时通过参数选择传输模式（`shm` 或 `tcp`），编译时两种都包含。

## 约束

- 现有 `shm_layout.c`、`sock_sync.c`、`ring_buffer.c`、`eth_shm.c` 零修改
- 两端均为 x86_64 Linux，不做字节序转换
- 不做 RDMA（接口预留，后续可加 `transport_rdma.c`）
- 不做 TLS 加密（内网场景）
- 不做自动发现/服务注册

## 架构

### 传输层抽象

新增 `cosim_transport_t` 函数指针表，SHM 和 TCP 各实现一套：

```
cosim_transport_t
├── transport_shm.c   ← 包装现有 shm_layout + sock_sync
└── transport_tcp.c   ← 新增 TCP 实现
```

### 接口定义

```c
typedef struct cosim_transport cosim_transport_t;

typedef struct {
    const char *transport;       /* "shm" | "tcp" */
    /* SHM 模式参数 */
    const char *shm_name;       /* e.g. "/cosim0" */
    const char *sock_path;      /* e.g. "/tmp/cosim.sock" */
    /* TCP 模式参数 */
    const char *remote_host;    /* VCS 侧连接目标, e.g. "192.168.1.100" */
    const char *listen_addr;    /* QEMU 侧监听地址, e.g. "0.0.0.0" */
    int         port_base;      /* 端口基数, 默认 9100 */
    int         instance_id;    /* 实例 ID, 默认 0 */
    int         is_server;      /* 1=QEMU(listen), 0=VCS(connect) */
} transport_cfg_t;

struct cosim_transport {
    /* 控制通道 */
    int  (*send_sync)(cosim_transport_t *t, const sync_msg_t *msg);
    int  (*recv_sync)(cosim_transport_t *t, sync_msg_t *msg);
    int  (*recv_sync_timed)(cosim_transport_t *t, sync_msg_t *msg, int timeout_ms);

    /* PCIe 数据通道 */
    int  (*send_tlp)(cosim_transport_t *t, const tlp_entry_t *tlp);
    int  (*recv_tlp)(cosim_transport_t *t, tlp_entry_t *tlp);
    int  (*send_cpl)(cosim_transport_t *t, const cpl_entry_t *cpl);
    int  (*recv_cpl)(cosim_transport_t *t, cpl_entry_t *cpl);

    /* DMA 通道 */
    int  (*send_dma_req)(cosim_transport_t *t, const dma_req_t *req);
    int  (*recv_dma_req)(cosim_transport_t *t, dma_req_t *req);
    int  (*send_dma_cpl)(cosim_transport_t *t, const dma_cpl_t *cpl);
    int  (*recv_dma_cpl)(cosim_transport_t *t, dma_cpl_t *cpl);

    /* MSI 通道 */
    int  (*send_msi)(cosim_transport_t *t, const msi_event_t *ev);
    int  (*recv_msi)(cosim_transport_t *t, msi_event_t *ev);

    /* ETH 通道 */
    int  (*send_eth)(cosim_transport_t *t, const eth_frame_t *frame);
    int  (*recv_eth)(cosim_transport_t *t, eth_frame_t *frame, uint64_t timeout_ns);

    /* 状态查询 */
    int  (*peer_ready)(cosim_transport_t *t);
    void (*set_ready)(cosim_transport_t *t);

    /* 生命周期 */
    void (*close)(cosim_transport_t *t);

    /* 私有数据 */
    void *priv;
};

/* 工厂函数 */
cosim_transport_t *transport_create(const transport_cfg_t *cfg);
```

### 调用方改造

`bridge_qemu.c` 和 `bridge_vcs.c` 中现有的 `cosim_shm_*` / `sock_sync_*` / `ring_buf_*` 调用，改为通过 `cosim_transport_t` 接口调用：

- `bridge_ctx_t` 新增 `cosim_transport_t *transport` 字段
- `bridge_init()` 根据 `transport_cfg_t.transport` 创建对应实现
- `bridge_send_tlp()` 内部调 `ctx->transport->send_tlp()`
- 原有 SHM 直接操作逻辑移入 `transport_shm.c`

## TCP 双连接架构

### 端口分配

```
实例 N:
  控制通道端口: port_base + N * 2       (默认 9100 → 9100, 9102, 9104...)
  数据通道端口: port_base + N * 2 + 1   (默认 9101 → 9101, 9103, 9105...)
```

QEMU 侧 listen（server），VCS 侧 connect（client）。

### 连接建立流程

```
QEMU (server)                          VCS (client)
  │                                      │
  ├─ listen(ctrl_port)                   │
  ├─ listen(data_port)                   │
  │                                      ├─ connect(ctrl_port)
  ├─ accept(ctrl_fd) ◄──────────────────┤
  │                                      ├─ connect(data_port)
  ├─ accept(data_fd) ◄──────────────────┤
  │                                      │
  ├─ 发送 HANDSHAKE {magic, version}     │
  │                      ────────────►   ├─ 验证 magic/version
  │                      ◄────────────   ├─ 回复 HANDSHAKE_ACK
  ├─ set_ready()                         ├─ set_ready()
  │                                      │
  └─ 开始正常通信 ◄─────────────────────►┘
```

### TCP 消息协议

所有消息加 8 字节头：

```
┌───────────────┬───────────────┐
│ msg_type (4B) │ payload_len(4B│
├───────────────┴───────────────┤
│ payload (payload_len bytes)   │
└───────────────────────────────┘
```

msg_type 值：

| type | 名称 | payload | 通道 |
|------|------|---------|------|
| 0x00 | HANDSHAKE | magic(4B) + version(4B) | ctrl |
| 0x01 | SYNC_MSG | sync_msg_t (8B) | ctrl |
| 0x02 | TLP_ENTRY | tlp_entry_t (104B) | data |
| 0x03 | CPL_ENTRY | cpl_entry_t (80B) | data |
| 0x04 | DMA_REQ | dma_req_t (32B) | data |
| 0x05 | DMA_CPL | dma_cpl_t (16B) | data |
| 0x06 | MSI_EVENT | msi_event_t (16B) | data |
| 0x07 | ETH_FRAME | eth_frame_t (12B header + len bytes data) | data |

结构体已 `__attribute__((packed))`，两端均 x86_64，直接 send/recv 整个结构体。

ETH 帧优化：不传完整 9232 字节，只传 `header (12B) + data[0..len-1]`，节省带宽。

### TCP socket 选项

```c
TCP_NODELAY = 1      /* 禁用 Nagle，降低延迟 */
SO_KEEPALIVE = 1     /* 检测断连 */
SO_RCVBUF = 256KB    /* 接收缓冲区 */
SO_SNDBUF = 256KB    /* 发送缓冲区 */
```

## SHM 包装实现

`transport_shm.c` 包装现有代码，不修改原文件：

```c
typedef struct {
    cosim_shm_t  shm;
    eth_shm_t    eth;
    int          listen_fd;
    int          client_fd;
    int          is_server;
    char         shm_name[256];
    char         sock_path[256];
} transport_shm_priv_t;
```

各接口映射：

| transport 接口 | SHM 实现 |
|---------------|---------|
| send_tlp | ring_buf_enqueue(&req_ring) + sock_sync_send(TLP_READY) |
| recv_tlp | sock_sync_recv() + ring_buf_dequeue(&req_ring) |
| send_cpl | ring_buf_enqueue(&cpl_ring) + sock_sync_send(CPL_READY) |
| recv_cpl | sock_sync_recv() + ring_buf_dequeue(&cpl_ring) |
| send_dma_req | ring_buf_enqueue(&dma_req_ring) |
| recv_dma_req | ring_buf_dequeue(&dma_req_ring) |
| send_msi | ring_buf_enqueue(&msi_ring) |
| recv_msi | ring_buf_dequeue(&msi_ring) |
| send_eth | eth_shm_enqueue() |
| recv_eth | eth_shm_dequeue() |
| peer_ready | atomic_load(&ctrl->vcs_ready) 或 qemu_ready |
| set_ready | atomic_store(&ctrl->xxx_ready, 1) |

## 文件结构

```
bridge/common/
  cosim_transport.h      ← 接口定义（函数指针表 + cfg 结构体）
  transport_shm.c        ← SHM 包装实现
  transport_tcp.c        ← TCP 实现
  transport_tcp.h        ← TCP 内部头文件（msg_header_t 等）

bridge/qemu/
  bridge_qemu.c          ← 改造：通过 transport 接口操作
  bridge_qemu.h          ← bridge_ctx_t 新增 transport 字段

bridge/vcs/
  bridge_vcs.c           ← 改造：通过 transport 接口操作

不修改的文件：
  bridge/common/shm_layout.c/.h
  bridge/qemu/sock_sync.c/.h
  bridge/common/ring_buffer.c/.h
  bridge/common/eth_shm.c/.h
  bridge/common/link_model.c/.h
  bridge/eth/eth_port.c/.h
```

## 构建控制

### CMakeLists.txt

`cosim_bridge_common` 库新增两个源文件：

```cmake
add_library(cosim_bridge_common STATIC
    ...现有文件...
    common/transport_shm.c
    common/transport_tcp.c
)
```

### Makefile（VCS 编译）

```makefile
BRIDGE_C_SRCS += \
    bridge/common/transport_shm.c \
    bridge/common/transport_tcp.c
```

### 运行时参数

```bash
# 本地 SHM 模式（默认，完全兼容现有用法）
./simv +transport=shm +SHM_NAME=/cosim0 +SOCK_PATH=/tmp/cosim.sock

# 跨机 TCP 模式 — QEMU 侧（server, listen）
qemu-system-x86_64 ... \
  -device cosim-pcie-rc,transport=tcp,listen=0.0.0.0,port_base=9100,instance_id=0

# 跨机 TCP 模式 — VCS 侧（client, connect）
./simv +transport=tcp +REMOTE_HOST=192.168.1.100 +PORT_BASE=9100 +INSTANCE_ID=0

# 多实例（同时跑 2 对）
# 实例 0: 端口 9100/9101
./simv +transport=tcp +REMOTE_HOST=10.0.0.1 +PORT_BASE=9100 +INSTANCE_ID=0
# 实例 1: 端口 9102/9103
./simv +transport=tcp +REMOTE_HOST=10.0.0.1 +PORT_BASE=9100 +INSTANCE_ID=1
```

## 测试计划

### 单元测试

- `test_transport_shm.c`：验证 SHM 包装层行为与原 bridge_loopback 一致
- `test_transport_tcp.c`：本机 127.0.0.1 TCP loopback 测试
- `test_transport_tcp_multi.c`：多实例端口分配验证

### 集成测试

- `test_tcp_tlp_roundtrip.c`：TCP 模式下 TLP send/wait_cpl
- `test_tcp_precise_mode.c`：TCP 模式下 Precise 时钟同步
- `test_tcp_eth_throughput.c`：TCP 模式下 ETH 帧吞吐量
- 复用现有 `test_qemu_integration.c`，参数化 transport 类型

### 跨机测试

- 两台 Ubuntu，QEMU 在 A，VCS 在 B
- 验证 TLP roundtrip、模式切换、时钟同步、ETH 打流

## 性能预期

| 指标 | SHM 模式 | TCP 模式 (万兆网) |
|------|---------|------------------|
| sync_msg roundtrip | ~18 us | ~50-80 us |
| TLP roundtrip | ~34 us | ~100-150 us |
| ETH 吞吐 (1500B) | 5.5 Gbps | 3-5 Gbps |
| ETH 吞吐 (9000B) | 27 Gbps | 5-8 Gbps |

## 后续扩展

- `transport_rdma.c`：RDMA 实现，接口已预留，无需改上层代码
- `transport_dpdk.c`：DPDK 用户态网络栈，更高 ETH 吞吐
