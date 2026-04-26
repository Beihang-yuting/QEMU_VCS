/* transport_tcp.c — TCP 传输层实现
 *
 * 连接架构 (版本协商):
 *   v1 (双连接): ctrl(sync) + data(tlp/cpl/dma/msi/eth)
 *     端口: ctrl=base+N*2, data=base+N*2+1
 *   v2 (三连接): ctrl(sync) + data(tlp/cpl) + aux(dma_req/dma_cpl/dma_data/msi/eth)
 *     端口: ctrl=base+N*3, data=base+N*3+1, aux=base+N*3+2
 *
 * 握手协商: server 发送自身版本，client 回复 min(server_ver, client_ver)
 * 双方使用协商后的版本。v1 客户端连接 v2 服务器时，aux_fd 保持 -1。
 *
 * QEMU 侧 listen (server), VCS 侧 connect (client)
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE      /* usleep(), getaddrinfo() */
#endif
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
    int  data_fd;        /* 数据通道 socket (TLP+CPL; v1 模式也走 DMA/MSI/ETH) */
    int  aux_fd;         /* 辅助通道 socket (v2: DMA_REQ/DMA_CPL/DMA_DATA/MSI/ETH) */
    int  ctrl_listen_fd; /* server 侧监听 fd (ctrl) */
    int  data_listen_fd; /* server 侧监听 fd (data) */
    int  aux_listen_fd;  /* server 侧监听 fd (aux, v2 only) */
    int  is_server;
    int  peer_is_ready;
    int  self_is_ready;
    int  ctrl_port;
    int  data_port;
    int  aux_port;       /* v2 辅助通道端口 */
    uint32_t negotiated_version; /* 协商后的协议版本 */
    char remote_host[256];
    char listen_addr[64];
} transport_tcp_priv_t;

/* 选择 DMA/MSI/ETH 消息应该走的 fd：v2 用 aux_fd，v1 回退到 data_fd */
static int aux_or_data_fd(transport_tcp_priv_t *p) {
    return (p->aux_fd >= 0) ? p->aux_fd : p->data_fd;
}

/* ========== 底层 TCP 工具函数 ========== */

static int tcp_send_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[tcp] send fd=%d len=%zu errno=%d (%s)\n",
                    fd, len, errno, strerror(errno));
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
    struct pollfd pfd;
    int ret;
    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = fd;
    pfd.events = POLLIN;
    ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) {
        if (errno == EINTR) return 1;
        return -1;
    }
    if (ret == 0) return 1;
    if (pfd.revents & (POLLERR | POLLHUP)) return -1;
    return tcp_recv_all(fd, buf, len);
}

static int tcp_send_msg(int fd, tcp_msg_type_t type, const void *payload, uint32_t payload_len) {
    tcp_msg_hdr_t hdr;
    hdr.msg_type = (uint32_t)type;
    hdr.payload_len = payload_len;
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

/* accept with poll loop: 每 2 秒检查一次，支持 Ctrl+C 中断 */
static int tcp_accept_poll(int listen_fd, const char *label) {
    struct pollfd pfd = { .fd = listen_fd, .events = POLLIN };
    int printed = 0;
    while (1) {
        int ret = poll(&pfd, 1, 2000);
        if (ret > 0) {
            int fd = accept(listen_fd, NULL, NULL);
            if (fd < 0) { perror(label); return -1; }
            fprintf(stderr, "%s: connected.\n", label);
            return fd;
        }
        if (ret < 0) {
            if (errno == EINTR) return -1;
            perror(label);
            return -1;
        }
        if (!printed) {
            fprintf(stderr, "%s: waiting for connection...\n", label);
            printed = 1;
        }
    }
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

/* 尝试连接，不重试，成功返回 fd，失败返回 -1 */
static int tcp_connect_host_once(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) <= 0) {
        close(fd);
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
        tcp_set_opts(fd);
        return fd;
    }
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

/* DMA_REQ/DMA_CPL/MSI/ETH: v2 走 aux_fd, v1 回退到 data_fd */

static int tcp_send_dma_req(cosim_transport_t *t, const dma_req_t *req) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(aux_or_data_fd(p), TCP_MSG_DMA_REQ, req, sizeof(*req));
}

static int tcp_recv_dma_req(cosim_transport_t *t, dma_req_t *req) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_DMA_REQ) return -1;
    return tcp_recv_all(fd, req, sizeof(*req));
}

/* 非阻塞 peek aux/data channel 下一条消息类型（不消费 buffer）
 * 返回: msg_type (>=0), 或 -1=无数据/错误 */
int tcp_peek_aux_msg_type(int fd) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    if (poll(&pfd, 1, 0) <= 0) return -1;
    if (pfd.revents & (POLLERR | POLLHUP)) return -1;
    tcp_msg_hdr_t hdr;
    int n = recv(fd, &hdr, sizeof(hdr), MSG_PEEK);
    if (n < (int)sizeof(hdr)) return -1;
    return (int)hdr.msg_type;
}

/* 跳过 aux channel 上一条不需要的消息（读完整 header+payload 丢弃）
 * 用于处理 irq_poller 不关心的消息类型（如 ETH_FRAME） */
int tcp_skip_aux_msg(int fd) {
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (hdr.payload_len > 0) {
        uint8_t discard[4096];
        uint32_t remaining = hdr.payload_len;
        while (remaining > 0) {
            uint32_t chunk = remaining < sizeof(discard) ? remaining : sizeof(discard);
            if (tcp_recv_all(fd, discard, chunk) < 0) return -1;
            remaining -= chunk;
        }
    }
    return 0;
}

static int tcp_recv_dma_req_nb(cosim_transport_t *t, dma_req_t *req) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);

    /* 先 peek 类型，不匹配则不消费，返回 1（无数据） */
    int msg_type = tcp_peek_aux_msg_type(fd);
    if (msg_type < 0) return 1;  /* 无数据 */
    if (msg_type != TCP_MSG_DMA_REQ) return 1;  /* 不是 DMA_REQ，留给其他 recv */

    /* 匹配，正式消费 header + payload */
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (tcp_recv_all(fd, req, sizeof(*req)) < 0) return -1;
    return 0;
}

static int tcp_send_dma_cpl(cosim_transport_t *t, const dma_cpl_t *cpl) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(aux_or_data_fd(p), TCP_MSG_DMA_CPL, cpl, sizeof(*cpl));
}

static int tcp_recv_dma_cpl(cosim_transport_t *t, dma_cpl_t *cpl) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_DMA_CPL) return -1;
    return tcp_recv_all(fd, cpl, sizeof(*cpl));
}

/* ========== DMA_DATA 数据搬运 ========== */

static int tcp_send_dma_data(cosim_transport_t *t, uint32_t tag, uint32_t direction,
                              uint64_t host_addr, const uint8_t *data, uint32_t len) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);

    tcp_dma_data_hdr_t dhdr;
    memset(&dhdr, 0, sizeof(dhdr));
    dhdr.tag = tag;
    dhdr.direction = direction;
    dhdr.host_addr = host_addr;
    dhdr.len = len;

    uint32_t payload_len = (uint32_t)sizeof(dhdr) + len;
    tcp_msg_hdr_t hdr;
    hdr.msg_type = (uint32_t)TCP_MSG_DMA_DATA;
    hdr.payload_len = payload_len;

    if (tcp_send_all(fd, &hdr, sizeof(hdr)) < 0) return -1;
    if (tcp_send_all(fd, &dhdr, sizeof(dhdr)) < 0) return -1;
    if (len > 0 && data) {
        if (tcp_send_all(fd, data, len) < 0) return -1;
    }
    return 0;
}

static int tcp_recv_dma_data(cosim_transport_t *t, uint32_t *tag, uint32_t *direction,
                              uint64_t *host_addr, uint8_t *data, uint32_t *len) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);

    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_DMA_DATA) return -1;
    if (hdr.payload_len < sizeof(tcp_dma_data_hdr_t)) return -1;

    tcp_dma_data_hdr_t dhdr;
    if (tcp_recv_all(fd, &dhdr, sizeof(dhdr)) < 0) return -1;

    uint32_t data_len = dhdr.len;
    if (hdr.payload_len != (uint32_t)sizeof(dhdr) + data_len) {
        fprintf(stderr, "[tcp] DMA_DATA payload mismatch: hdr=%u expected=%u\n",
                hdr.payload_len, (uint32_t)sizeof(dhdr) + data_len);
        return -1;
    }

    if (tag) *tag = dhdr.tag;
    if (direction) *direction = dhdr.direction;
    if (host_addr) *host_addr = dhdr.host_addr;
    if (len) *len = data_len;

    if (data_len > 0 && data) {
        if (tcp_recv_all(fd, data, data_len) < 0) return -1;
    } else if (data_len > 0) {
        /* caller provided no buffer, drain the data */
        uint8_t drain[4096];
        uint32_t remaining = data_len;
        while (remaining > 0) {
            uint32_t chunk = (remaining > sizeof(drain)) ? (uint32_t)sizeof(drain) : remaining;
            if (tcp_recv_all(fd, drain, chunk) < 0) return -1;
            remaining -= chunk;
        }
    }
    return 0;
}

/* ========== MSI 通道 ========== */

static int tcp_send_msi(cosim_transport_t *t, const msi_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(aux_or_data_fd(p), TCP_MSG_MSI, ev, sizeof(*ev));
}

static int tcp_recv_msi(cosim_transport_t *t, msi_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_MSI) return -1;
    return tcp_recv_all(fd, ev, sizeof(*ev));
}

static int tcp_recv_msi_nb(cosim_transport_t *t, msi_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);

    /* 先 peek 类型，不匹配则不消费 */
    int msg_type = tcp_peek_aux_msg_type(fd);
    if (msg_type < 0) return 1;  /* 无数据 */
    if (msg_type != TCP_MSG_MSI) return 1;  /* 不是 MSI，留给其他 recv */

    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(fd, &hdr) < 0) return -1;
    if (tcp_recv_all(fd, ev, sizeof(*ev)) < 0) return -1;
    return 0;
}

/* ========== ETH 通道 ========== */

static int tcp_send_eth(cosim_transport_t *t, const eth_frame_t *frame) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);
    uint32_t payload_len = 16u + frame->len;
    tcp_msg_hdr_t hdr;
    hdr.msg_type = TCP_MSG_ETH_FRAME;
    hdr.payload_len = payload_len;
    if (tcp_send_all(fd, &hdr, sizeof(hdr)) < 0) return -1;
    if (tcp_send_all(fd, frame, 16) < 0) return -1;
    if (frame->len > 0) {
        if (tcp_send_all(fd, frame->data, frame->len) < 0) return -1;
    }
    return 0;
}

static int tcp_recv_eth(cosim_transport_t *t, eth_frame_t *frame, uint64_t timeout_ns) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    int fd = aux_or_data_fd(p);
    int timeout_ms = (timeout_ns == 0) ? 0 : (int)(timeout_ns / 1000000ULL);
    if (timeout_ms == 0 && timeout_ns > 0) timeout_ms = 1;

    tcp_msg_hdr_t hdr;
    int ret = tcp_recv_timed(fd, &hdr, sizeof(hdr), timeout_ms);
    if (ret != 0) return ret;
    if (hdr.msg_type != TCP_MSG_ETH_FRAME) return -1;

    memset(frame, 0, sizeof(*frame));
    if (tcp_recv_all(fd, frame, 16) < 0) return -1;
    if (frame->len > 0 && frame->len <= ETH_FRAME_MAX_DATA) {
        if (tcp_recv_all(fd, frame->data, frame->len) < 0) return -1;
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
    if (p->aux_fd >= 0) close(p->aux_fd);
    if (p->ctrl_listen_fd >= 0) close(p->ctrl_listen_fd);
    if (p->data_listen_fd >= 0) close(p->data_listen_fd);
    if (p->aux_listen_fd >= 0) close(p->aux_listen_fd);

    free(p);
    free(t);
}

/* ========== 握手 ========== */

/*
 * 版本协商协议:
 *   1. Server 发送 handshake {magic, version=自身最高版本, conn_count}
 *   2. Client 回复 handshake {magic, version=min(server_ver, client_ver), conn_count}
 *   3. 双方使用回复中的 version
 *
 * 向后兼容: v1 客户端发送 8 字节 handshake (只有 magic+version)。
 * Server 通过 payload_len 区分: 8=v1, 16=v2。
 */

static int tcp_do_handshake_server(transport_tcp_priv_t *p) {
    tcp_handshake_t hs;
    uint32_t conn_count = (p->aux_fd >= 0) ? 3 : 2;

    memset(&hs, 0, sizeof(hs));
    hs.magic = TCP_HANDSHAKE_MAGIC;
    hs.version = TCP_HANDSHAKE_VERSION;
    hs.conn_count = conn_count;

    /* 发送 v2 格式握手 (16 字节) */
    if (tcp_send_msg(p->ctrl_fd, TCP_MSG_HANDSHAKE, &hs, sizeof(hs)) < 0) return -1;

    /* 接收 client 回复 */
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_HANDSHAKE) return -1;

    tcp_handshake_t ack;
    memset(&ack, 0, sizeof(ack));

    if (hdr.payload_len == 8) {
        /* v1 客户端: 只发送 magic + version (8字节) */
        if (tcp_recv_all(p->ctrl_fd, &ack, 8) < 0) return -1;
        ack.conn_count = 2;
    } else if (hdr.payload_len == sizeof(ack)) {
        /* v2 客户端 */
        if (tcp_recv_all(p->ctrl_fd, &ack, sizeof(ack)) < 0) return -1;
    } else {
        fprintf(stderr, "[tcp] handshake unexpected payload_len=%u\n", hdr.payload_len);
        return -1;
    }

    if (ack.magic != TCP_HANDSHAKE_MAGIC) {
        fprintf(stderr, "[tcp] handshake magic mismatch: 0x%08x\n", ack.magic);
        return -1;
    }

    /* 使用客户端回复的版本 (已经是 min) */
    p->negotiated_version = ack.version;

    /* 如果协商到 v1，关闭 aux 连接 */
    if (p->negotiated_version < TCP_HANDSHAKE_V2 && p->aux_fd >= 0) {
        fprintf(stderr, "[tcp] Negotiated v%u, closing aux connection\n", p->negotiated_version);
        close(p->aux_fd);
        p->aux_fd = -1;
        if (p->aux_listen_fd >= 0) {
            close(p->aux_listen_fd);
            p->aux_listen_fd = -1;
        }
    }

    fprintf(stderr, "[tcp] Server handshake done: negotiated v%u, %u connections\n",
            p->negotiated_version, (p->aux_fd >= 0) ? 3u : 2u);
    p->peer_is_ready = 1;
    return 0;
}

static int tcp_do_handshake_client(transport_tcp_priv_t *p) {
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_HANDSHAKE) return -1;

    tcp_handshake_t hs;
    memset(&hs, 0, sizeof(hs));

    uint32_t server_version;
    if (hdr.payload_len == 8) {
        /* v1 server */
        if (tcp_recv_all(p->ctrl_fd, &hs, 8) < 0) return -1;
        hs.conn_count = 2;
        server_version = hs.version;
    } else if (hdr.payload_len == sizeof(hs)) {
        if (tcp_recv_all(p->ctrl_fd, &hs, sizeof(hs)) < 0) return -1;
        server_version = hs.version;
    } else {
        fprintf(stderr, "[tcp] handshake unexpected payload_len=%u\n", hdr.payload_len);
        return -1;
    }

    if (hs.magic != TCP_HANDSHAKE_MAGIC) {
        fprintf(stderr, "[tcp] handshake magic mismatch: 0x%08x\n", hs.magic);
        return -1;
    }

    /* 协商: 取 min(server, client) */
    uint32_t my_version = TCP_HANDSHAKE_VERSION;
    uint32_t agreed = (server_version < my_version) ? server_version : my_version;
    p->negotiated_version = agreed;

    /* 回复 */
    tcp_handshake_t ack;
    memset(&ack, 0, sizeof(ack));
    ack.magic = TCP_HANDSHAKE_MAGIC;
    ack.version = agreed;
    ack.conn_count = (p->aux_fd >= 0 && agreed >= TCP_HANDSHAKE_V2) ? 3 : 2;

    if (tcp_send_msg(p->ctrl_fd, TCP_MSG_HANDSHAKE, &ack, sizeof(ack)) < 0) return -1;

    /* 如果协商到 v1，关闭 aux */
    if (agreed < TCP_HANDSHAKE_V2 && p->aux_fd >= 0) {
        fprintf(stderr, "[tcp] Negotiated v%u, closing aux connection\n", agreed);
        close(p->aux_fd);
        p->aux_fd = -1;
    }

    fprintf(stderr, "[tcp] Client handshake done: negotiated v%u, %u connections\n",
            p->negotiated_version, (p->aux_fd >= 0) ? 3u : 2u);
    p->peer_is_ready = 1;
    return 0;
}

/* ========== 工厂函数 ========== */

cosim_transport_t *transport_tcp_create(const transport_cfg_t *cfg) {
    cosim_transport_t *t = (cosim_transport_t *)calloc(1, sizeof(*t));
    if (!t) return NULL;

    transport_tcp_priv_t *p = (transport_tcp_priv_t *)calloc(1, sizeof(*p));
    if (!p) { free(t); return NULL; }

    p->ctrl_fd = -1;
    p->data_fd = -1;
    p->aux_fd = -1;
    p->ctrl_listen_fd = -1;
    p->data_listen_fd = -1;
    p->aux_listen_fd = -1;
    p->is_server = cfg->is_server;
    p->peer_is_ready = 0;
    p->self_is_ready = 0;
    p->negotiated_version = TCP_HANDSHAKE_V1;  /* 默认 v1，握手后更新 */

    int port_base = (cfg->port_base > 0) ? cfg->port_base : TCP_DEFAULT_PORT_BASE;

    /* v2 端口分配: base+N*3, base+N*3+1, base+N*3+2 */
    p->ctrl_port = port_base + cfg->instance_id * 3;
    p->data_port = port_base + cfg->instance_id * 3 + 1;
    p->aux_port  = port_base + cfg->instance_id * 3 + 2;

    if (cfg->remote_host) {
        strncpy(p->remote_host, cfg->remote_host, sizeof(p->remote_host) - 1);
    }
    if (cfg->listen_addr) {
        strncpy(p->listen_addr, cfg->listen_addr, sizeof(p->listen_addr) - 1);
    }

    fprintf(stderr, "[tcp] Creating transport: %s ctrl=%d data=%d aux=%d\n",
            cfg->is_server ? "server" : "client",
            p->ctrl_port, p->data_port, p->aux_port);

    if (cfg->is_server) {
        /* Server: 监听 3 个端口 */
        p->ctrl_listen_fd = tcp_listen_port(p->listen_addr, p->ctrl_port);
        if (p->ctrl_listen_fd < 0) goto fail;

        p->data_listen_fd = tcp_listen_port(p->listen_addr, p->data_port);
        if (p->data_listen_fd < 0) goto fail;

        p->aux_listen_fd = tcp_listen_port(p->listen_addr, p->aux_port);
        if (p->aux_listen_fd < 0) goto fail;

        fprintf(stderr, "[tcp] Server listening on ctrl=%d data=%d aux=%d, waiting for client...\n",
                p->ctrl_port, p->data_port, p->aux_port);

        /* 接受 ctrl 和 data (必须，poll 循环支持 Ctrl+C) */
        p->ctrl_fd = tcp_accept_poll(p->ctrl_listen_fd, "[tcp] accept ctrl");
        if (p->ctrl_fd < 0) goto fail;
        tcp_set_opts(p->ctrl_fd);

        p->data_fd = tcp_accept_poll(p->data_listen_fd, "[tcp] accept data");
        if (p->data_fd < 0) goto fail;
        tcp_set_opts(p->data_fd);

        /* 尝试接受 aux (非阻塞等待短暂时间，v1 客户端不会连接此端口) */
        {
            struct pollfd pfd;
            memset(&pfd, 0, sizeof(pfd));
            pfd.fd = p->aux_listen_fd;
            pfd.events = POLLIN;
            int ret = poll(&pfd, 1, 2000);  /* 等待 2 秒 */
            if (ret > 0 && (pfd.revents & POLLIN)) {
                p->aux_fd = accept(p->aux_listen_fd, NULL, NULL);
                if (p->aux_fd >= 0) {
                    tcp_set_opts(p->aux_fd);
                    fprintf(stderr, "[tcp] Aux connection accepted\n");
                }
            } else {
                fprintf(stderr, "[tcp] No aux connection (v1 client), proceeding with 2 connections\n");
                p->aux_fd = -1;
            }
        }

        fprintf(stderr, "[tcp] Client connected, performing handshake...\n");
        if (tcp_do_handshake_server(p) < 0) {
            fprintf(stderr, "[tcp] Handshake failed\n");
            goto fail;
        }
    } else {
        /* Client: 连接 ctrl + data (必须), 尝试 aux */
        fprintf(stderr, "[tcp] Client connecting to %s ctrl=%d data=%d aux=%d...\n",
                p->remote_host, p->ctrl_port, p->data_port, p->aux_port);

        p->ctrl_fd = tcp_connect_host(p->remote_host, p->ctrl_port);
        if (p->ctrl_fd < 0) goto fail;

        p->data_fd = tcp_connect_host(p->remote_host, p->data_port);
        if (p->data_fd < 0) goto fail;

        /* 尝试连接 aux (v2 server 会监听，v1 server 不会) */
        p->aux_fd = tcp_connect_host_once(p->remote_host, p->aux_port);
        if (p->aux_fd >= 0) {
            fprintf(stderr, "[tcp] Aux connection established\n");
        } else {
            fprintf(stderr, "[tcp] Aux connection failed (v1 server?), proceeding with 2 connections\n");
            p->aux_fd = -1;
        }

        fprintf(stderr, "[tcp] Connected, performing handshake...\n");
        if (tcp_do_handshake_client(p) < 0) {
            fprintf(stderr, "[tcp] Handshake failed\n");
            goto fail;
        }
    }

    fprintf(stderr, "[tcp] Handshake complete, transport ready (v%u, %s) "
            "ctrl_fd=%d data_fd=%d aux_fd=%d\n",
            p->negotiated_version, (p->aux_fd >= 0) ? "3-conn" : "2-conn",
            p->ctrl_fd, p->data_fd, p->aux_fd);

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
    t->send_dma_data   = tcp_send_dma_data;
    t->recv_dma_data   = tcp_recv_dma_data;
    t->recv_dma_req_nb = tcp_recv_dma_req_nb;
    t->recv_msi_nb     = tcp_recv_msi_nb;
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
    if (p->aux_fd >= 0) close(p->aux_fd);
    if (p->ctrl_listen_fd >= 0) close(p->ctrl_listen_fd);
    if (p->data_listen_fd >= 0) close(p->data_listen_fd);
    if (p->aux_listen_fd >= 0) close(p->aux_listen_fd);
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
