# TCP 传输层实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 TCP 传输层，支持 QEMU 和 VCS 分别运行在两台不同的 Ubuntu 机器上，同时保持现有 SHM+Unix socket 代码零修改。

**Architecture:** 定义 `cosim_transport_t` 函数指针表作为传输层抽象。SHM 和 TCP 各实现一套，`transport_create()` 工厂函数根据 `transport_cfg_t.transport` 字段选择实现。`bridge_qemu.c` 和 `bridge_vcs.c` 改为通过 transport 接口操作，原有 SHM 直接操作逻辑移入 `transport_shm.c`。

**Tech Stack:** C11, POSIX sockets, TCP_NODELAY, packed structs over TCP, CMake + Makefile

---

## 文件结构

| 操作 | 文件路径 | 职责 |
|------|---------|------|
| 创建 | `bridge/common/cosim_transport.h` | 传输层接口定义（函数指针表 + cfg 结构体 + 工厂函数声明） |
| 创建 | `bridge/common/transport_shm.c` | SHM 包装实现：将现有 shm_layout + sock_sync + ring_buffer + eth_shm 包装为 transport 接口 |
| 创建 | `bridge/common/transport_tcp.h` | TCP 内部头文件：msg_header_t、msg_type 枚举、handshake 常量 |
| 创建 | `bridge/common/transport_tcp.c` | TCP 传输实现：双连接、消息协议、所有通道的 send/recv |
| 修改 | `bridge/qemu/bridge_qemu.h` | `bridge_ctx_t` 新增 `cosim_transport_t *transport` 字段，新增 `bridge_init_ex()` |
| 修改 | `bridge/qemu/bridge_qemu.c` | 新增 `bridge_init_ex()`，原函数保持不变保证兼容 |
| 修改 | `bridge/vcs/bridge_vcs.c` | 新增 `bridge_vcs_init_ex()`，原函数保持不变保证兼容 |
| 修改 | `bridge/CMakeLists.txt` | cosim_bridge_common 添加 transport_shm.c、transport_tcp.c |
| 修改 | `Makefile` | BRIDGE_C_SRCS 添加两个新文件 |
| 创建 | `tests/unit/test_transport_tcp.c` | TCP loopback 单元测试 |
| 创建 | `tests/integration/test_tcp_roundtrip.c` | TCP 模式 TLP roundtrip 集成测试 |
| 修改 | `tests/unit/CMakeLists.txt` | 添加 test_transport_tcp |
| 修改 | `tests/integration/CMakeLists.txt` | 添加 test_tcp_roundtrip |

**不修改的文件：** `shm_layout.c/.h`, `sock_sync.c/.h`, `ring_buffer.c/.h`, `eth_shm.c/.h`, `link_model.c/.h`, `eth_port.c/.h`, `cosim_types.h`

---

### Task 1: 传输层接口定义 — `cosim_transport.h`

**Files:**
- Create: `bridge/common/cosim_transport.h`
- Test: 编译检查

- [ ] **Step 1: 创建 cosim_transport.h**

```c
/* cosim_transport.h — 传输层抽象接口
 *
 * SHM 和 TCP 各实现一套函数指针，上层代码通过此接口操作，
 * 运行时根据 transport_cfg_t.transport 选择实现。
 */
#ifndef COSIM_TRANSPORT_H
#define COSIM_TRANSPORT_H

#include "cosim_types.h"
#include "eth_types.h"
#include <stdint.h>

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

    /* SHM 兼容 — 暴露底层 SHM 指针供需要直接访问的代码使用
     * TCP 模式下返回 NULL */
    void *(*get_shm_base)(cosim_transport_t *t);
    void *(*get_dma_buf)(cosim_transport_t *t, uint32_t *out_size);

    /* 生命周期 */
    void (*close)(cosim_transport_t *t);

    /* 私有数据 */
    void *priv;
};

/* 工厂函数 — 根据 cfg->transport 创建对应实现 */
cosim_transport_t *transport_create(const transport_cfg_t *cfg);

/* 各实现的创建函数（内部使用） */
cosim_transport_t *transport_shm_create(const transport_cfg_t *cfg);
cosim_transport_t *transport_tcp_create(const transport_cfg_t *cfg);

#endif /* COSIM_TRANSPORT_H */
```

- [ ] **Step 2: 验证头文件编译通过**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && gcc -fsyntax-only -I bridge/common bridge/common/cosim_transport.h`
Expected: 无输出，退出码 0

- [ ] **Step 3: Commit**

```bash
git add bridge/common/cosim_transport.h
git commit -m "feat: add cosim_transport.h transport layer interface"
```

---

### Task 2: TCP 内部头文件 — `transport_tcp.h`

**Files:**
- Create: `bridge/common/transport_tcp.h`

- [ ] **Step 1: 创建 transport_tcp.h**

```c
/* transport_tcp.h — TCP 传输层内部定义
 *
 * 消息协议: 8 字节头 (msg_type 4B + payload_len 4B) + payload
 * 双连接: 控制通道 (sync_msg) + 数据通道 (tlp/cpl/dma/msi/eth)
 */
#ifndef TRANSPORT_TCP_H
#define TRANSPORT_TCP_H

#include <stdint.h>

#define TCP_HANDSHAKE_MAGIC   0x434F5349u  /* "COSI" */
#define TCP_HANDSHAKE_VERSION 1u
#define TCP_DEFAULT_PORT_BASE 9100
#define TCP_RECV_BUF_SIZE     (256 * 1024)
#define TCP_SEND_BUF_SIZE     (256 * 1024)

/* 消息类型 */
typedef enum {
    TCP_MSG_HANDSHAKE    = 0x00,
    TCP_MSG_SYNC         = 0x01,
    TCP_MSG_TLP          = 0x02,
    TCP_MSG_CPL          = 0x03,
    TCP_MSG_DMA_REQ      = 0x04,
    TCP_MSG_DMA_CPL      = 0x05,
    TCP_MSG_MSI          = 0x06,
    TCP_MSG_ETH_FRAME    = 0x07,
    TCP_MSG_DMA_DATA     = 0x08,  /* DMA 数据搬运 */
} tcp_msg_type_t;

/* 消息头 */
typedef struct {
    uint32_t msg_type;
    uint32_t payload_len;
} __attribute__((packed)) tcp_msg_hdr_t;

/* 握手消息 */
typedef struct {
    uint32_t magic;
    uint32_t version;
} __attribute__((packed)) tcp_handshake_t;

/* DMA 数据传输消息 — TCP 模式没有共享内存，
 * DMA 数据需要通过网络搬运 */
typedef struct {
    uint32_t tag;
    uint32_t direction;   /* DMA_DIR_READ=0, DMA_DIR_WRITE=1 */
    uint64_t host_addr;
    uint32_t len;
    uint32_t _pad;
    /* 后跟 len 字节 DMA 数据 */
} __attribute__((packed)) tcp_dma_data_hdr_t;

#endif /* TRANSPORT_TCP_H */
```

- [ ] **Step 2: 验证编译**

Run: `gcc -fsyntax-only -I bridge/common bridge/common/transport_tcp.h`
Expected: 退出码 0

- [ ] **Step 3: Commit**

```bash
git add bridge/common/transport_tcp.h
git commit -m "feat: add transport_tcp.h TCP message protocol definitions"
```

---

### Task 3: SHM 包装实现 — `transport_shm.c`

**Files:**
- Create: `bridge/common/transport_shm.c`
- Test: 编译链接检查

- [ ] **Step 1: 创建 transport_shm.c**

```c
/* transport_shm.c — 将现有 SHM+Unix socket 代码包装为 cosim_transport_t 接口
 *
 * 不修改 shm_layout.c / sock_sync.c / ring_buffer.c / eth_shm.c 的任何一行。
 * 只是把它们的函数组合起来，填入 cosim_transport_t 函数指针表。
 */
#include "cosim_transport.h"
#include "shm_layout.h"
#include "ring_buffer.h"
#include "eth_shm.h"
#include "sock_sync.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

typedef struct {
    cosim_shm_t  shm;
    eth_shm_t    eth;
    int          listen_fd;
    int          client_fd;
    int          is_server;
    int          eth_initialized;
    char         shm_name[256];
    char         sock_path[256];
} transport_shm_priv_t;

/* ========== 控制通道 ========== */

static int shm_send_sync(cosim_transport_t *t, const sync_msg_t *msg) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return sock_sync_send(p->client_fd, msg);
}

static int shm_recv_sync(cosim_transport_t *t, sync_msg_t *msg) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return sock_sync_recv(p->client_fd, msg);
}

static int shm_recv_sync_timed(cosim_transport_t *t, sync_msg_t *msg, int timeout_ms) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return sock_sync_recv_timed(p->client_fd, msg, timeout_ms);
}

/* ========== PCIe 数据通道 ========== */

static int shm_send_tlp(cosim_transport_t *t, const tlp_entry_t *tlp) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_enqueue(&p->shm.req_ring, tlp);
}

static int shm_recv_tlp(cosim_transport_t *t, tlp_entry_t *tlp) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_dequeue(&p->shm.req_ring, tlp);
}

static int shm_send_cpl(cosim_transport_t *t, const cpl_entry_t *cpl) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_enqueue(&p->shm.cpl_ring, cpl);
}

static int shm_recv_cpl(cosim_transport_t *t, cpl_entry_t *cpl) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_dequeue(&p->shm.cpl_ring, cpl);
}

/* ========== DMA 通道 ========== */

static int shm_send_dma_req(cosim_transport_t *t, const dma_req_t *req) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_enqueue(&p->shm.dma_req_ring, req);
}

static int shm_recv_dma_req(cosim_transport_t *t, dma_req_t *req) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_dequeue(&p->shm.dma_req_ring, req);
}

static int shm_send_dma_cpl(cosim_transport_t *t, const dma_cpl_t *cpl) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_enqueue(&p->shm.dma_cpl_ring, cpl);
}

static int shm_recv_dma_cpl(cosim_transport_t *t, dma_cpl_t *cpl) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_dequeue(&p->shm.dma_cpl_ring, cpl);
}

/* ========== MSI 通道 ========== */

static int shm_send_msi(cosim_transport_t *t, const msi_event_t *ev) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_enqueue(&p->shm.msi_ring, ev);
}

static int shm_recv_msi(cosim_transport_t *t, msi_event_t *ev) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return ring_buf_dequeue(&p->shm.msi_ring, ev);
}

/* ========== ETH 通道 ========== */

static int shm_send_eth(cosim_transport_t *t, const eth_frame_t *frame) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    if (!p->eth_initialized) return -1;
    eth_frame_ring_t *ring = eth_shm_tx_ring(&p->eth, ETH_ROLE_A);
    return eth_shm_enqueue(ring, frame);
}

static int shm_recv_eth(cosim_transport_t *t, eth_frame_t *frame, uint64_t timeout_ns) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    if (!p->eth_initialized) return -1;
    (void)timeout_ns;
    eth_frame_ring_t *ring = eth_shm_rx_ring(&p->eth, ETH_ROLE_A);
    return eth_shm_dequeue(ring, frame);
}

/* ========== 状态查询 ========== */

static int shm_peer_ready(cosim_transport_t *t) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    if (p->is_server) {
        return (int)atomic_load(&p->shm.ctrl->vcs_ready);
    } else {
        return (int)atomic_load(&p->shm.ctrl->qemu_ready);
    }
}

static void shm_set_ready(cosim_transport_t *t) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    if (p->is_server) {
        atomic_store(&p->shm.ctrl->qemu_ready, 1);
    } else {
        atomic_store(&p->shm.ctrl->vcs_ready, 1);
    }
}

/* ========== SHM 兼容 ========== */

static void *shm_get_shm_base(cosim_transport_t *t) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    return p->shm.base;
}

static void *shm_get_dma_buf(cosim_transport_t *t, uint32_t *out_size) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    if (out_size) *out_size = p->shm.dma_buf_size;
    return p->shm.dma_buf;
}

/* ========== 生命周期 ========== */

static void shm_close(cosim_transport_t *t) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    if (!p) return;

    sock_sync_close(p->client_fd);
    sock_sync_close(p->listen_fd);

    if (p->is_server) {
        cosim_shm_destroy(&p->shm, p->shm_name);
        unlink(p->sock_path);
    } else {
        cosim_shm_close(&p->shm);
    }

    if (p->eth_initialized) {
        eth_shm_close(&p->eth);
    }

    free(p);
    free(t);
}

/* ========== 工厂函数 ========== */

cosim_transport_t *transport_shm_create(const transport_cfg_t *cfg) {
    cosim_transport_t *t = calloc(1, sizeof(*t));
    if (!t) return NULL;

    transport_shm_priv_t *p = calloc(1, sizeof(*p));
    if (!p) { free(t); return NULL; }

    p->is_server = cfg->is_server;
    p->listen_fd = -1;
    p->client_fd = -1;
    p->eth_initialized = 0;

    if (cfg->shm_name) {
        strncpy(p->shm_name, cfg->shm_name, sizeof(p->shm_name) - 1);
    }
    if (cfg->sock_path) {
        strncpy(p->sock_path, cfg->sock_path, sizeof(p->sock_path) - 1);
    }

    int ret;
    if (cfg->is_server) {
        ret = cosim_shm_create(&p->shm, p->shm_name);
    } else {
        ret = cosim_shm_open(&p->shm, p->shm_name);
    }
    if (ret < 0) {
        fprintf(stderr, "[transport_shm] Failed to %s SHM '%s'\n",
                cfg->is_server ? "create" : "open", p->shm_name);
        free(p); free(t);
        return NULL;
    }

    if (cfg->is_server) {
        p->listen_fd = sock_sync_listen(p->sock_path);
        if (p->listen_fd < 0) {
            cosim_shm_destroy(&p->shm, p->shm_name);
            free(p); free(t);
            return NULL;
        }
    }

    t->send_sync       = shm_send_sync;
    t->recv_sync       = shm_recv_sync;
    t->recv_sync_timed = shm_recv_sync_timed;
    t->send_tlp        = shm_send_tlp;
    t->recv_tlp        = shm_recv_tlp;
    t->send_cpl        = shm_send_cpl;
    t->recv_cpl        = shm_recv_cpl;
    t->send_dma_req    = shm_send_dma_req;
    t->recv_dma_req    = shm_recv_dma_req;
    t->send_dma_cpl    = shm_send_dma_cpl;
    t->recv_dma_cpl    = shm_recv_dma_cpl;
    t->send_msi        = shm_send_msi;
    t->recv_msi        = shm_recv_msi;
    t->send_eth        = shm_send_eth;
    t->recv_eth        = shm_recv_eth;
    t->peer_ready      = shm_peer_ready;
    t->set_ready       = shm_set_ready;
    t->get_shm_base    = shm_get_shm_base;
    t->get_dma_buf     = shm_get_dma_buf;
    t->close           = shm_close;
    t->priv            = p;

    return t;
}
```

- [ ] **Step 2: 验证编译**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && gcc -c -std=c11 -I bridge/common -I bridge/qemu bridge/common/transport_shm.c -o /dev/null`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add bridge/common/transport_shm.c
git commit -m "feat: add transport_shm.c SHM wrapper for transport interface"
```

---

### Task 4: TCP 传输实现 — `transport_tcp.c`

**Files:**
- Create: `bridge/common/transport_tcp.c`

这是最核心的新增文件，实现完整的 TCP 传输层。

- [ ] **Step 1: 创建 transport_tcp.c**

```c
/* transport_tcp.c — TCP 传输层实现
 *
 * 双连接架构:
 *   控制通道 (ctrl_fd): sync_msg 收发
 *   数据通道 (data_fd): TLP/CPL/DMA/MSI/ETH 消息
 *
 * 端口分配:
 *   实例 N: 控制=port_base+N*2, 数据=port_base+N*2+1
 *
 * QEMU 侧 listen (server), VCS 侧 connect (client)
 */
#include "cosim_transport.h"
#include "transport_tcp.h"
#include "cosim_types.h"
#include "eth_types.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>

typedef struct {
    int  ctrl_fd;        /* 控制通道 socket */
    int  data_fd;        /* 数据通道 socket */
    int  ctrl_listen_fd; /* server 侧监听 fd (ctrl) */
    int  data_listen_fd; /* server 侧监听 fd (data) */
    int  is_server;
    int  peer_is_ready;
    int  self_is_ready;
    int  ctrl_port;
    int  data_port;
    char remote_host[256];
    char listen_addr[64];
} transport_tcp_priv_t;

/* ========== 底层 TCP 工具函数 ========== */

static int tcp_send_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("[tcp] send");
            return -1;
        }
        if (n == 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int tcp_recv_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t received = 0;
    while (received < len) {
        ssize_t n = recv(fd, p + received, len - received, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("[tcp] recv");
            return -1;
        }
        if (n == 0) return -1;
        received += (size_t)n;
    }
    return 0;
}

/* 返回: 0=成功, 1=超时, -1=错误 */
static int tcp_recv_timed(int fd, void *buf, size_t len, int timeout_ms) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) {
        if (errno == EINTR) return 1;
        return -1;
    }
    if (ret == 0) return 1;
    if (pfd.revents & (POLLERR | POLLHUP)) return -1;
    return tcp_recv_all(fd, buf, len);
}

static int tcp_send_msg(int fd, tcp_msg_type_t type, const void *payload, uint32_t payload_len) {
    tcp_msg_hdr_t hdr = { .msg_type = (uint32_t)type, .payload_len = payload_len };
    if (tcp_send_all(fd, &hdr, sizeof(hdr)) < 0) return -1;
    if (payload_len > 0 && payload) {
        if (tcp_send_all(fd, payload, payload_len) < 0) return -1;
    }
    return 0;
}

static int tcp_recv_hdr(int fd, tcp_msg_hdr_t *hdr) {
    return tcp_recv_all(fd, hdr, sizeof(*hdr));
}

static void tcp_set_opts(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    int bufsz = TCP_RECV_BUF_SIZE;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
    bufsz = TCP_SEND_BUF_SIZE;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz));
}

static int tcp_listen_port(const char *addr, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("[tcp] socket"); return -1; }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (addr && addr[0]) {
        inet_pton(AF_INET, addr, &sa.sin_addr);
    } else {
        sa.sin_addr.s_addr = INADDR_ANY;
    }

    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        perror("[tcp] bind");
        close(fd);
        return -1;
    }
    if (listen(fd, 1) < 0) {
        perror("[tcp] listen");
        close(fd);
        return -1;
    }
    return fd;
}

static int tcp_connect_host(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("[tcp] socket"); return -1; }

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) <= 0) {
        fprintf(stderr, "[tcp] invalid address: %s\n", host);
        close(fd);
        return -1;
    }

    for (int i = 0; i < 30; i++) {
        if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
            tcp_set_opts(fd);
            return fd;
        }
        if (errno != ECONNREFUSED) {
            perror("[tcp] connect");
            close(fd);
            return -1;
        }
        usleep(500000);
    }
    fprintf(stderr, "[tcp] connect timeout: %s:%d\n", host, port);
    close(fd);
    return -1;
}

/* ========== 传输接口实现 ========== */

static int tcp_send_sync(cosim_transport_t *t, const sync_msg_t *msg) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->ctrl_fd, TCP_MSG_SYNC, msg, sizeof(*msg));
}

static int tcp_recv_sync(cosim_transport_t *t, sync_msg_t *msg) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_SYNC || hdr.payload_len != sizeof(*msg)) {
        fprintf(stderr, "[tcp] unexpected ctrl msg: type=%u len=%u\n",
                hdr.msg_type, hdr.payload_len);
        return -1;
    }
    return tcp_recv_all(p->ctrl_fd, msg, sizeof(*msg));
}

static int tcp_recv_sync_timed(cosim_transport_t *t, sync_msg_t *msg, int timeout_ms) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    int ret = tcp_recv_timed(p->ctrl_fd, &hdr, sizeof(hdr), timeout_ms);
    if (ret != 0) return ret;
    if (hdr.msg_type != TCP_MSG_SYNC || hdr.payload_len != sizeof(*msg)) {
        fprintf(stderr, "[tcp] unexpected timed ctrl msg: type=%u len=%u\n",
                hdr.msg_type, hdr.payload_len);
        return -1;
    }
    return tcp_recv_all(p->ctrl_fd, msg, sizeof(*msg));
}

static int tcp_send_tlp(cosim_transport_t *t, const tlp_entry_t *tlp) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->data_fd, TCP_MSG_TLP, tlp, sizeof(*tlp));
}

static int tcp_recv_tlp(cosim_transport_t *t, tlp_entry_t *tlp) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->data_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_TLP) return -1;
    return tcp_recv_all(p->data_fd, tlp, sizeof(*tlp));
}

static int tcp_send_cpl(cosim_transport_t *t, const cpl_entry_t *cpl) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->data_fd, TCP_MSG_CPL, cpl, sizeof(*cpl));
}

static int tcp_recv_cpl(cosim_transport_t *t, cpl_entry_t *cpl) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->data_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_CPL) return -1;
    return tcp_recv_all(p->data_fd, cpl, sizeof(*cpl));
}

static int tcp_send_dma_req(cosim_transport_t *t, const dma_req_t *req) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->data_fd, TCP_MSG_DMA_REQ, req, sizeof(*req));
}

static int tcp_recv_dma_req(cosim_transport_t *t, dma_req_t *req) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->data_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_DMA_REQ) return -1;
    return tcp_recv_all(p->data_fd, req, sizeof(*req));
}

static int tcp_send_dma_cpl(cosim_transport_t *t, const dma_cpl_t *cpl) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->data_fd, TCP_MSG_DMA_CPL, cpl, sizeof(*cpl));
}

static int tcp_recv_dma_cpl(cosim_transport_t *t, dma_cpl_t *cpl) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->data_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_DMA_CPL) return -1;
    return tcp_recv_all(p->data_fd, cpl, sizeof(*cpl));
}

static int tcp_send_msi(cosim_transport_t *t, const msi_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->data_fd, TCP_MSG_MSI, ev, sizeof(*ev));
}

static int tcp_recv_msi(cosim_transport_t *t, msi_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->data_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_MSI) return -1;
    return tcp_recv_all(p->data_fd, ev, sizeof(*ev));
}

static int tcp_send_eth(cosim_transport_t *t, const eth_frame_t *frame) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    uint32_t payload_len = 16u + frame->len;
    tcp_msg_hdr_t hdr = { .msg_type = TCP_MSG_ETH_FRAME, .payload_len = payload_len };
    if (tcp_send_all(p->data_fd, &hdr, sizeof(hdr)) < 0) return -1;
    if (tcp_send_all(p->data_fd, frame, 16) < 0) return -1;
    if (frame->len > 0) {
        if (tcp_send_all(p->data_fd, frame->data, frame->len) < 0) return -1;
    }
    return 0;
}

static int tcp_recv_eth(cosim_transport_t *t, eth_frame_t *frame, uint64_t timeout_ns) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int timeout_ms = (timeout_ns == 0) ? 0 : (int)(timeout_ns / 1000000ULL);
    if (timeout_ms == 0 && timeout_ns > 0) timeout_ms = 1;

    tcp_msg_hdr_t hdr;
    int ret = tcp_recv_timed(p->data_fd, &hdr, sizeof(hdr), timeout_ms);
    if (ret != 0) return ret;
    if (hdr.msg_type != TCP_MSG_ETH_FRAME) return -1;

    memset(frame, 0, sizeof(*frame));
    if (tcp_recv_all(p->data_fd, frame, 16) < 0) return -1;
    if (frame->len > 0 && frame->len <= ETH_FRAME_MAX_DATA) {
        if (tcp_recv_all(p->data_fd, frame->data, frame->len) < 0) return -1;
    }
    return 0;
}

/* ========== 状态查询 ========== */

static int tcp_peer_ready(cosim_transport_t *t) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return p->peer_is_ready;
}

static void tcp_set_ready(cosim_transport_t *t) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    p->self_is_ready = 1;
}

static void *tcp_get_shm_base(cosim_transport_t *t) {
    (void)t;
    return NULL;
}

static void *tcp_get_dma_buf(cosim_transport_t *t, uint32_t *out_size) {
    (void)t;
    if (out_size) *out_size = 0;
    return NULL;
}

/* ========== 生命周期 ========== */

static void tcp_close(cosim_transport_t *t) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    if (!p) return;

    if (p->ctrl_fd >= 0) close(p->ctrl_fd);
    if (p->data_fd >= 0) close(p->data_fd);
    if (p->ctrl_listen_fd >= 0) close(p->ctrl_listen_fd);
    if (p->data_listen_fd >= 0) close(p->data_listen_fd);

    free(p);
    free(t);
}

/* ========== 握手 ========== */

static int tcp_do_handshake_server(transport_tcp_priv_t *p) {
    tcp_handshake_t hs = { .magic = TCP_HANDSHAKE_MAGIC, .version = TCP_HANDSHAKE_VERSION };
    if (tcp_send_msg(p->ctrl_fd, TCP_MSG_HANDSHAKE, &hs, sizeof(hs)) < 0) return -1;

    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_HANDSHAKE) return -1;
    tcp_handshake_t ack;
    if (tcp_recv_all(p->ctrl_fd, &ack, sizeof(ack)) < 0) return -1;
    if (ack.magic != TCP_HANDSHAKE_MAGIC || ack.version != TCP_HANDSHAKE_VERSION) {
        fprintf(stderr, "[tcp] handshake mismatch: magic=0x%08x ver=%u\n",
                ack.magic, ack.version);
        return -1;
    }
    p->peer_is_ready = 1;
    return 0;
}

static int tcp_do_handshake_client(transport_tcp_priv_t *p) {
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_HANDSHAKE) return -1;
    tcp_handshake_t hs;
    if (tcp_recv_all(p->ctrl_fd, &hs, sizeof(hs)) < 0) return -1;
    if (hs.magic != TCP_HANDSHAKE_MAGIC || hs.version != TCP_HANDSHAKE_VERSION) {
        fprintf(stderr, "[tcp] handshake mismatch: magic=0x%08x ver=%u\n",
                hs.magic, hs.version);
        return -1;
    }

    tcp_handshake_t ack = { .magic = TCP_HANDSHAKE_MAGIC, .version = TCP_HANDSHAKE_VERSION };
    if (tcp_send_msg(p->ctrl_fd, TCP_MSG_HANDSHAKE, &ack, sizeof(ack)) < 0) return -1;
    p->peer_is_ready = 1;
    return 0;
}

/* ========== 工厂函数 ========== */

cosim_transport_t *transport_tcp_create(const transport_cfg_t *cfg) {
    cosim_transport_t *t = calloc(1, sizeof(*t));
    if (!t) return NULL;

    transport_tcp_priv_t *p = calloc(1, sizeof(*p));
    if (!p) { free(t); return NULL; }

    p->ctrl_fd = -1;
    p->data_fd = -1;
    p->ctrl_listen_fd = -1;
    p->data_listen_fd = -1;
    p->is_server = cfg->is_server;
    p->peer_is_ready = 0;
    p->self_is_ready = 0;

    int port_base = (cfg->port_base > 0) ? cfg->port_base : TCP_DEFAULT_PORT_BASE;
    p->ctrl_port = port_base + cfg->instance_id * 2;
    p->data_port = port_base + cfg->instance_id * 2 + 1;

    if (cfg->remote_host) {
        strncpy(p->remote_host, cfg->remote_host, sizeof(p->remote_host) - 1);
    }
    if (cfg->listen_addr) {
        strncpy(p->listen_addr, cfg->listen_addr, sizeof(p->listen_addr) - 1);
    }

    fprintf(stderr, "[tcp] Creating transport: %s ctrl_port=%d data_port=%d\n",
            cfg->is_server ? "server" : "client", p->ctrl_port, p->data_port);

    if (cfg->is_server) {
        p->ctrl_listen_fd = tcp_listen_port(p->listen_addr, p->ctrl_port);
        if (p->ctrl_listen_fd < 0) goto fail;

        p->data_listen_fd = tcp_listen_port(p->listen_addr, p->data_port);
        if (p->data_listen_fd < 0) goto fail;

        fprintf(stderr, "[tcp] Server listening on ctrl=%d data=%d, waiting for client...\n",
                p->ctrl_port, p->data_port);

        p->ctrl_fd = accept(p->ctrl_listen_fd, NULL, NULL);
        if (p->ctrl_fd < 0) { perror("[tcp] accept ctrl"); goto fail; }
        tcp_set_opts(p->ctrl_fd);

        p->data_fd = accept(p->data_listen_fd, NULL, NULL);
        if (p->data_fd < 0) { perror("[tcp] accept data"); goto fail; }
        tcp_set_opts(p->data_fd);

        fprintf(stderr, "[tcp] Client connected, performing handshake...\n");
        if (tcp_do_handshake_server(p) < 0) {
            fprintf(stderr, "[tcp] Handshake failed\n");
            goto fail;
        }
    } else {
        fprintf(stderr, "[tcp] Client connecting to %s ctrl=%d data=%d...\n",
                p->remote_host, p->ctrl_port, p->data_port);

        p->ctrl_fd = tcp_connect_host(p->remote_host, p->ctrl_port);
        if (p->ctrl_fd < 0) goto fail;

        p->data_fd = tcp_connect_host(p->remote_host, p->data_port);
        if (p->data_fd < 0) goto fail;

        fprintf(stderr, "[tcp] Connected, performing handshake...\n");
        if (tcp_do_handshake_client(p) < 0) {
            fprintf(stderr, "[tcp] Handshake failed\n");
            goto fail;
        }
    }

    fprintf(stderr, "[tcp] Handshake complete, transport ready\n");

    t->send_sync       = tcp_send_sync;
    t->recv_sync       = tcp_recv_sync;
    t->recv_sync_timed = tcp_recv_sync_timed;
    t->send_tlp        = tcp_send_tlp;
    t->recv_tlp        = tcp_recv_tlp;
    t->send_cpl        = tcp_send_cpl;
    t->recv_cpl        = tcp_recv_cpl;
    t->send_dma_req    = tcp_send_dma_req;
    t->recv_dma_req    = tcp_recv_dma_req;
    t->send_dma_cpl    = tcp_send_dma_cpl;
    t->recv_dma_cpl    = tcp_recv_dma_cpl;
    t->send_msi        = tcp_send_msi;
    t->recv_msi        = tcp_recv_msi;
    t->send_eth        = tcp_send_eth;
    t->recv_eth        = tcp_recv_eth;
    t->peer_ready      = tcp_peer_ready;
    t->set_ready       = tcp_set_ready;
    t->get_shm_base    = tcp_get_shm_base;
    t->get_dma_buf     = tcp_get_dma_buf;
    t->close           = tcp_close;
    t->priv            = p;
    return t;

fail:
    if (p->ctrl_fd >= 0) close(p->ctrl_fd);
    if (p->data_fd >= 0) close(p->data_fd);
    if (p->ctrl_listen_fd >= 0) close(p->ctrl_listen_fd);
    if (p->data_listen_fd >= 0) close(p->data_listen_fd);
    free(p);
    free(t);
    return NULL;
}

/* ========== 工厂分发 ========== */

cosim_transport_t *transport_create(const transport_cfg_t *cfg) {
    if (!cfg || !cfg->transport) {
        fprintf(stderr, "[transport] No transport type specified\n");
        return NULL;
    }
    if (strcmp(cfg->transport, "shm") == 0) {
        return transport_shm_create(cfg);
    }
    if (strcmp(cfg->transport, "tcp") == 0) {
        return transport_tcp_create(cfg);
    }
    fprintf(stderr, "[transport] Unknown transport type: %s\n", cfg->transport);
    return NULL;
}
```

- [ ] **Step 2: 验证编译**

Run: `gcc -c -std=c11 -I bridge/common -I bridge/qemu bridge/common/transport_tcp.c -o /dev/null`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add bridge/common/transport_tcp.c
git commit -m "feat: add transport_tcp.c TCP transport implementation"
```

---

### Task 5: 构建系统更新 — CMakeLists.txt + Makefile

**Files:**
- Modify: `bridge/CMakeLists.txt:1-12`
- Modify: `Makefile:29-38`

- [ ] **Step 1: 更新 bridge/CMakeLists.txt**

在 `cosim_bridge_common` 库的源文件列表中添加两个新文件，并在 include 中添加 `qemu` 目录：

将第 1-12 行替换为：

```cmake
add_library(cosim_bridge_common STATIC
    common/shm_layout.c
    common/ring_buffer.c
    common/dma_manager.c
    common/trace_log.c
    common/eth_shm.c
    common/link_model.c
    common/transport_shm.c
    common/transport_tcp.c
)
target_include_directories(cosim_bridge_common PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/common
    ${CMAKE_CURRENT_SOURCE_DIR}/qemu
)
target_link_libraries(cosim_bridge_common PRIVATE rt pthread)
```

- [ ] **Step 2: 更新 Makefile BRIDGE_C_SRCS**

将 `BRIDGE_C_SRCS` 替换为：

```makefile
BRIDGE_C_SRCS = \
	bridge/vcs/bridge_vcs.c \
	bridge/vcs/sock_sync_vcs.c \
	bridge/common/shm_layout.c \
	bridge/common/ring_buffer.c \
	bridge/common/dma_manager.c \
	bridge/common/trace_log.c \
	bridge/common/eth_shm.c \
	bridge/common/link_model.c \
	bridge/vcs/vq_eth_stub.c \
	bridge/common/transport_shm.c \
	bridge/common/transport_tcp.c
```

- [ ] **Step 3: 验证构建通过**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build -j$(nproc)`
Expected: 编译成功，无错误

- [ ] **Step 4: Commit**

```bash
git add bridge/CMakeLists.txt Makefile
git commit -m "build: add transport_shm.c and transport_tcp.c to CMake and Makefile"
```

---

### Task 6: QEMU Bridge 改造 — 新增 `bridge_init_ex()`

**Files:**
- Modify: `bridge/qemu/bridge_qemu.h`
- Modify: `bridge/qemu/bridge_qemu.c`

策略：**不修改任何现有函数**。新增 `bridge_init_ex()` 和 `bridge_connect_ex()` 函数。

- [ ] **Step 1: 修改 bridge_qemu.h — 新增 transport 字段和新函数声明**

在 `bridge_ctx_t` 结构体末尾（`int trace_enabled;` 之后）添加：

```c
    struct cosim_transport *transport;  /* NULL = legacy SHM mode */
```

在文件末尾 `#endif` 之前添加前向声明和新函数：

```c
/* Transport-aware API (新增，不影响现有代码) */
struct cosim_transport;
typedef struct {
    const char *transport;
    const char *shm_name;
    const char *sock_path;
    const char *remote_host;
    const char *listen_addr;
    int         port_base;
    int         instance_id;
    int         is_server;
} transport_cfg_t;

bridge_ctx_t *bridge_init_ex(const transport_cfg_t *cfg);
int bridge_connect_ex(bridge_ctx_t *ctx);
```

- [ ] **Step 2: 修改 bridge_qemu.c — 在 bridge_destroy() 之后追加新函数**

在文件末尾追加：

```c
/* ========== Transport-aware API (新增) ========== */

#include "cosim_transport.h"

bridge_ctx_t *bridge_init_ex(const transport_cfg_t *cfg) {
    if (!cfg) return NULL;

    /* SHM 模式 — 委托给原有 bridge_init */
    if (!cfg->transport || strcmp(cfg->transport, "shm") == 0) {
        bridge_ctx_t *ctx = bridge_init(cfg->shm_name, cfg->sock_path);
        if (ctx) ctx->transport = NULL;
        return ctx;
    }

    /* TCP 模式 */
    bridge_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    ctx->listen_fd = -1;
    ctx->client_fd = -1;
    ctx->next_tag = 0;

    transport_cfg_t server_cfg = *cfg;
    server_cfg.is_server = 1;
    ctx->transport = transport_create(&server_cfg);
    if (!ctx->transport) {
        free(ctx);
        return NULL;
    }

    ctx->transport->set_ready(ctx->transport);
    return ctx;
}

int bridge_connect_ex(bridge_ctx_t *ctx) {
    if (!ctx) return -1;

    if (!ctx->transport) {
        return bridge_connect(ctx);
    }

    return ctx->transport->peer_ready(ctx->transport) ? 0 : -1;
}
```

- [ ] **Step 3: 验证构建**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && cmake --build build -j$(nproc)`
Expected: 编译成功

- [ ] **Step 4: Commit**

```bash
git add bridge/qemu/bridge_qemu.h bridge/qemu/bridge_qemu.c
git commit -m "feat: add bridge_init_ex() and bridge_connect_ex() for transport layer"
```

---

### Task 7: VCS Bridge 改造 — 新增 `bridge_vcs_init_ex()`

**Files:**
- Modify: `bridge/vcs/bridge_vcs.c`

策略同 QEMU 侧：不修改任何现有函数，新增 `bridge_vcs_init_ex()` 函数。

- [ ] **Step 1: 在 bridge_vcs.c 的 bridge_vcs_cleanup() 之后追加 transport 支持代码**

在第 527 行（`bridge_vcs_cleanup` 函数闭合括号之后）追加：

```c
/* ========== Transport-aware API (新增) ========== */

#include "cosim_transport.h"

static cosim_transport_t *g_transport = NULL;

int bridge_vcs_init_ex(const char *transport_type,
                        const char *shm_name, const char *sock_path,
                        const char *remote_host, int port_base, int instance_id) {
    if (g_initialized) return 0;

    if (!transport_type || strcmp(transport_type, "shm") == 0) {
        return bridge_vcs_init(shm_name, sock_path);
    }

    transport_cfg_t cfg = {
        .transport   = transport_type,
        .shm_name    = shm_name,
        .sock_path   = sock_path,
        .remote_host = remote_host,
        .port_base   = port_base,
        .instance_id = instance_id,
        .is_server   = 0,
    };

    g_transport = transport_create(&cfg);
    if (!g_transport) {
        fprintf(stderr, "[VCS Bridge] Failed to create %s transport\n", transport_type);
        return -1;
    }

    g_transport->set_ready(g_transport);
    g_initialized = 1;
    fprintf(stderr, "[VCS Bridge] Initialized: transport=%s remote=%s port=%d inst=%d\n",
            transport_type, remote_host ? remote_host : "(null)", port_base, instance_id);
    return 0;
}

void bridge_vcs_cleanup_ex(void) {
    if (g_transport) {
        g_transport->close(g_transport);
        g_transport = NULL;
        g_initialized = 0;
    } else {
        bridge_vcs_cleanup();
    }
}
```

- [ ] **Step 2: 验证构建**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && cmake --build build -j$(nproc)`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add bridge/vcs/bridge_vcs.c
git commit -m "feat: add bridge_vcs_init_ex() for transport layer support"
```

---

### Task 8: TCP loopback 单元测试

**Files:**
- Create: `tests/unit/test_transport_tcp.c`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: 创建 test_transport_tcp.c**

```c
/* test_transport_tcp.c — TCP transport loopback 单元测试
 *
 * 在本机 127.0.0.1 创建 server + client transport，
 * 验证各通道消息的收发正确性。
 */
#include "cosim_transport.h"
#include "cosim_types.h"
#include "eth_types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        fflush(stderr); \
        abort(); \
    } \
} while (0)

typedef struct {
    cosim_transport_t *transport;
    int test_pass;
} server_ctx_t;

static void *server_thread(void *arg) {
    server_ctx_t *sctx = (server_ctx_t *)arg;

    transport_cfg_t cfg = {
        .transport   = "tcp",
        .listen_addr = "127.0.0.1",
        .port_base   = 19100,
        .instance_id = 0,
        .is_server   = 1,
    };

    sctx->transport = transport_create(&cfg);
    if (!sctx->transport) {
        fprintf(stderr, "Server: transport_create failed\n");
        sctx->test_pass = 0;
        return NULL;
    }
    sctx->test_pass = 1;
    return NULL;
}

static void test_sync_roundtrip(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 1: sync_msg roundtrip... ");

    sync_msg_t send_msg = { .type = SYNC_MSG_TLP_READY, .payload = 42 };
    CHECK(client->send_sync(client, &send_msg) == 0);

    sync_msg_t recv_msg;
    CHECK(server->recv_sync(server, &recv_msg) == 0);
    CHECK(recv_msg.type == SYNC_MSG_TLP_READY);
    CHECK(recv_msg.payload == 42);

    sync_msg_t ack = { .type = SYNC_MSG_CPL_READY, .payload = 99 };
    CHECK(server->send_sync(server, &ack) == 0);

    sync_msg_t ack_recv;
    CHECK(client->recv_sync(client, &ack_recv) == 0);
    CHECK(ack_recv.type == SYNC_MSG_CPL_READY);
    CHECK(ack_recv.payload == 99);

    printf("PASS\n");
}

static void test_tlp_roundtrip(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 2: TLP roundtrip... ");

    tlp_entry_t tlp;
    memset(&tlp, 0, sizeof(tlp));
    tlp.type = TLP_MWR;
    tlp.tag = 7;
    tlp.len = 4;
    tlp.addr = 0xFEED0000ULL;
    tlp.data[0] = 0xDE;
    tlp.data[1] = 0xAD;
    tlp.data[2] = 0xBE;
    tlp.data[3] = 0xEF;

    CHECK(server->send_tlp(server, &tlp) == 0);

    tlp_entry_t recv_tlp;
    CHECK(client->recv_tlp(client, &recv_tlp) == 0);
    CHECK(recv_tlp.type == TLP_MWR);
    CHECK(recv_tlp.tag == 7);
    CHECK(recv_tlp.addr == 0xFEED0000ULL);
    CHECK(memcmp(recv_tlp.data, tlp.data, 4) == 0);

    cpl_entry_t cpl;
    memset(&cpl, 0, sizeof(cpl));
    cpl.type = TLP_CPL;
    cpl.tag = 7;
    cpl.status = 0;
    cpl.len = 4;
    cpl.data[0] = 0xCA;

    CHECK(client->send_cpl(client, &cpl) == 0);

    cpl_entry_t recv_cpl;
    CHECK(server->recv_cpl(server, &recv_cpl) == 0);
    CHECK(recv_cpl.tag == 7);
    CHECK(recv_cpl.data[0] == 0xCA);

    printf("PASS\n");
}

static void test_dma_roundtrip(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 3: DMA roundtrip... ");

    dma_req_t req = {
        .tag = 1000,
        .direction = DMA_DIR_READ,
        .host_addr = 0x80000000ULL,
        .len = 64,
        .dma_offset = 0,
        .timestamp = 12345,
    };
    CHECK(client->send_dma_req(client, &req) == 0);

    dma_req_t recv_req;
    CHECK(server->recv_dma_req(server, &recv_req) == 0);
    CHECK(recv_req.tag == 1000);
    CHECK(recv_req.host_addr == 0x80000000ULL);

    dma_cpl_t cpl = { .tag = 1000, .status = 0, .timestamp = 12346 };
    CHECK(server->send_dma_cpl(server, &cpl) == 0);

    dma_cpl_t recv_cpl;
    CHECK(client->recv_dma_cpl(client, &recv_cpl) == 0);
    CHECK(recv_cpl.tag == 1000);
    CHECK(recv_cpl.status == 0);

    printf("PASS\n");
}

static void test_msi(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 4: MSI event... ");

    msi_event_t ev = { .vector = 3, .timestamp = 99999 };
    CHECK(client->send_msi(client, &ev) == 0);

    msi_event_t recv_ev;
    CHECK(server->recv_msi(server, &recv_ev) == 0);
    CHECK(recv_ev.vector == 3);
    CHECK(recv_ev.timestamp == 99999);

    printf("PASS\n");
}

static void test_eth_frame(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 5: ETH frame... ");

    eth_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.len = 64;
    frame.seq = 1;
    frame.timestamp_ns = 1000000;
    for (int i = 0; i < 64; i++) {
        frame.data[i] = (uint8_t)(i & 0xFF);
    }

    CHECK(server->send_eth(server, &frame) == 0);

    eth_frame_t recv_frame;
    CHECK(client->recv_eth(client, &recv_frame, 5000000000ULL) == 0);
    CHECK(recv_frame.len == 64);
    CHECK(recv_frame.seq == 1);
    for (int i = 0; i < 64; i++) {
        CHECK(recv_frame.data[i] == (uint8_t)(i & 0xFF));
    }

    printf("PASS\n");
}

static void test_recv_timeout(cosim_transport_t *server) {
    printf("Test 6: recv_sync_timed timeout... ");

    sync_msg_t msg;
    int ret = server->recv_sync_timed(server, &msg, 100);
    CHECK(ret == 1);

    printf("PASS\n");
}

static void test_port_allocation(void) {
    printf("Test 7: port allocation... ");

    CHECK(9100 + 0 * 2     == 9100);
    CHECK(9100 + 0 * 2 + 1 == 9101);
    CHECK(9100 + 1 * 2     == 9102);
    CHECK(9100 + 1 * 2 + 1 == 9103);
    CHECK(9100 + 2 * 2     == 9104);
    CHECK(9100 + 2 * 2 + 1 == 9105);

    printf("PASS\n");
}

int main(void) {
    printf("=== TCP Transport Unit Tests ===\n\n");

    test_port_allocation();

    server_ctx_t sctx = { .transport = NULL, .test_pass = 0 };
    pthread_t server_tid;
    pthread_create(&server_tid, NULL, server_thread, &sctx);

    usleep(200000);

    transport_cfg_t client_cfg = {
        .transport   = "tcp",
        .remote_host = "127.0.0.1",
        .port_base   = 19100,
        .instance_id = 0,
        .is_server   = 0,
    };
    cosim_transport_t *client = transport_create(&client_cfg);
    CHECK(client != NULL);

    pthread_join(server_tid, NULL);
    CHECK(sctx.test_pass == 1);
    cosim_transport_t *server = sctx.transport;
    CHECK(server != NULL);

    printf("\n");

    test_sync_roundtrip(server, client);
    test_tlp_roundtrip(server, client);
    test_dma_roundtrip(server, client);
    test_msi(server, client);
    test_eth_frame(server, client);
    test_recv_timeout(server);

    server->close(server);
    client->close(client);

    printf("\n=== All 7 tests PASSED ===\n");
    return 0;
}
```

- [ ] **Step 2: 更新 tests/unit/CMakeLists.txt**

追加：

```cmake
add_executable(test_transport_tcp test_transport_tcp.c)
target_link_libraries(test_transport_tcp cosim_bridge_common cosim_bridge pthread)
add_test(NAME test_transport_tcp COMMAND test_transport_tcp)
set_tests_properties(test_transport_tcp PROPERTIES TIMEOUT 30)
```

- [ ] **Step 3: 构建并运行测试**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && cmake --build build -j$(nproc) && cd build && ctest --test-dir tests/unit -R test_transport_tcp --output-on-failure -V`
Expected: 7/7 tests PASS

- [ ] **Step 4: Commit**

```bash
git add tests/unit/test_transport_tcp.c tests/unit/CMakeLists.txt
git commit -m "test: add TCP transport unit tests (7 tests, loopback)"
```

---

### Task 9: TCP 模式集成测试 — TLP roundtrip

**Files:**
- Create: `tests/integration/test_tcp_roundtrip.c`
- Modify: `tests/integration/CMakeLists.txt`

模拟 QEMU+VCS 两侧（fork），验证 TCP 模式下 TLP send + wait_cpl 完整流程。

- [ ] **Step 1: 创建 test_tcp_roundtrip.c**

```c
/* test_tcp_roundtrip.c — TCP 模式 QEMU-VCS TLP roundtrip
 *
 * fork() 创建两个进程:
 *   Parent = QEMU (server): send TLP + wait CPL
 *   Child  = VCS  (client): recv TLP + send CPL
 */
#include "cosim_transport.h"
#include "cosim_types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        fflush(stderr); \
        abort(); \
    } \
} while (0)

#define TCP_TEST_PORT 19200
#define NUM_ROUNDTRIPS 10

static int run_vcs(void) {
    usleep(200000);

    transport_cfg_t cfg = {
        .transport   = "tcp",
        .remote_host = "127.0.0.1",
        .port_base   = TCP_TEST_PORT,
        .instance_id = 0,
        .is_server   = 0,
    };
    cosim_transport_t *t = transport_create(&cfg);
    if (!t) {
        fprintf(stderr, "[VCS] transport_create failed\n");
        return 1;
    }
    t->set_ready(t);

    for (int i = 0; i < NUM_ROUNDTRIPS; i++) {
        sync_msg_t msg;
        CHECK(t->recv_sync(t, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_TLP_READY);

        tlp_entry_t tlp;
        CHECK(t->recv_tlp(t, &tlp) == 0);
        CHECK(tlp.type == TLP_MRD);
        CHECK(tlp.tag == (uint8_t)i);

        cpl_entry_t cpl;
        memset(&cpl, 0, sizeof(cpl));
        cpl.type = TLP_CPL;
        cpl.tag = tlp.tag;
        cpl.status = 0;
        cpl.len = 4;
        uint32_t val = 0xA0000000 + (uint32_t)i;
        memcpy(cpl.data, &val, 4);

        CHECK(t->send_cpl(t, &cpl) == 0);

        sync_msg_t ack = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        CHECK(t->send_sync(t, &ack) == 0);
    }

    t->close(t);
    return 0;
}

static int run_qemu(void) {
    transport_cfg_t cfg = {
        .transport   = "tcp",
        .listen_addr = "127.0.0.1",
        .port_base   = TCP_TEST_PORT,
        .instance_id = 0,
        .is_server   = 1,
    };
    cosim_transport_t *t = transport_create(&cfg);
    if (!t) {
        fprintf(stderr, "[QEMU] transport_create failed\n");
        return 1;
    }
    t->set_ready(t);

    for (int i = 0; i < NUM_ROUNDTRIPS; i++) {
        tlp_entry_t tlp;
        memset(&tlp, 0, sizeof(tlp));
        tlp.type = TLP_MRD;
        tlp.tag = (uint8_t)i;
        tlp.len = 4;
        tlp.addr = (uint64_t)(0x1000 + i * 4);

        CHECK(t->send_tlp(t, &tlp) == 0);

        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        CHECK(t->send_sync(t, &msg) == 0);

        sync_msg_t ack;
        CHECK(t->recv_sync(t, &ack) == 0);
        CHECK(ack.type == SYNC_MSG_CPL_READY);

        cpl_entry_t cpl;
        CHECK(t->recv_cpl(t, &cpl) == 0);
        CHECK(cpl.tag == (uint8_t)i);

        uint32_t val;
        memcpy(&val, cpl.data, 4);
        CHECK(val == 0xA0000000 + (uint32_t)i);

        fprintf(stderr, "[QEMU] roundtrip %d/%d OK\n", i + 1, NUM_ROUNDTRIPS);
    }

    t->close(t);
    return 0;
}

int main(void) {
    printf("=== TCP TLP Roundtrip Integration Test (%d rounds) ===\n\n", NUM_ROUNDTRIPS);

    pid_t pid = fork();
    CHECK(pid >= 0);

    if (pid == 0) {
        int rc = run_vcs();
        _exit(rc);
    }

    int rc_qemu = run_qemu();

    int status;
    waitpid(pid, &status, 0);
    int rc_vcs = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

    printf("\n=== Result: QEMU=%d VCS=%d ===\n", rc_qemu, rc_vcs);
    return (rc_qemu || rc_vcs) ? 1 : 0;
}
```

- [ ] **Step 2: 更新 tests/integration/CMakeLists.txt**

追加：

```cmake
# TCP transport roundtrip integration test
add_executable(test_tcp_roundtrip test_tcp_roundtrip.c)
target_link_libraries(test_tcp_roundtrip cosim_bridge_common cosim_bridge pthread)
add_test(NAME test_tcp_roundtrip COMMAND test_tcp_roundtrip)
set_tests_properties(test_tcp_roundtrip PROPERTIES TIMEOUT 30)
```

- [ ] **Step 3: 构建并运行测试**

Run: `cd /home/ubuntu/ryan/software/cosim-platform && cmake --build build -j$(nproc) && cd build && ctest --test-dir tests/integration -R test_tcp_roundtrip --output-on-failure -V`
Expected: 10 roundtrips PASS

- [ ] **Step 4: Commit**

```bash
git add tests/integration/test_tcp_roundtrip.c tests/integration/CMakeLists.txt
git commit -m "test: add TCP TLP roundtrip integration test"
```

---

### Task 10: Makefile 运行目标更新

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: 在 Makefile 末尾追加 TCP 模式运行目标**

```makefile
# ===== TCP 跨机模式 =====
# QEMU 侧 (server, listen)
.PHONY: run-vip-tcp-server
run-vip-tcp-server: vcs-vip
	$(BUILD_DIR)/simv_vip +transport=tcp +LISTEN=0.0.0.0 +PORT_BASE=9100 +INSTANCE_ID=0 \
		+UVM_TESTNAME=cosim_test

# VCS 侧 (client, connect) — 用法: make run-vip-tcp-client REMOTE_HOST=192.168.1.100
.PHONY: run-vip-tcp-client
run-vip-tcp-client: vcs-vip
	$(BUILD_DIR)/simv_vip +transport=tcp +REMOTE_HOST=$(REMOTE_HOST) +PORT_BASE=9100 +INSTANCE_ID=0 \
		+UVM_TESTNAME=cosim_test
```

- [ ] **Step 2: Commit**

```bash
git add Makefile
git commit -m "feat: add TCP mode run targets to Makefile"
```

---

## 实现顺序总结

| Task | 内容 | 依赖 |
|------|------|------|
| 1 | `cosim_transport.h` 接口定义 | — |
| 2 | `transport_tcp.h` TCP 协议定义 | — |
| 3 | `transport_shm.c` SHM 包装实现 | Task 1 |
| 4 | `transport_tcp.c` TCP 实现 | Task 1, 2 |
| 5 | 构建系统更新 | Task 3, 4 |
| 6 | QEMU Bridge 改造 | Task 1, 5 |
| 7 | VCS Bridge 改造 | Task 1, 5 |
| 8 | TCP loopback 单元测试 | Task 5 |
| 9 | TCP roundtrip 集成测试 | Task 5 |
| 10 | Makefile 运行目标 | Task 5 |

Tasks 1-2 可并行，Tasks 3-4 可并行，Tasks 6-7 可并行，Tasks 8-10 可并行。
