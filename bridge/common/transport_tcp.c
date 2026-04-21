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
