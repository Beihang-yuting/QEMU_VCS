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

/* ========== DMA 数据搬运 (SHM 模式不需要，使用 dma_buf 直接访问) ========== */

static int shm_send_dma_data(cosim_transport_t *t, uint32_t tag, uint32_t direction,
                              uint64_t host_addr, const uint8_t *data, uint32_t len) {
    (void)t; (void)tag; (void)direction; (void)host_addr; (void)data; (void)len;
    return -1;  /* SHM 模式使用 dma_buf 直接访问，不需要网络搬运 */
}

static int shm_recv_dma_data(cosim_transport_t *t, uint32_t *tag, uint32_t *direction,
                              uint64_t *host_addr, uint8_t *data, uint32_t *len) {
    (void)t; (void)tag; (void)direction; (void)host_addr; (void)data; (void)len;
    return -1;
}

/* ========== 非阻塞接收 ========== */

static int shm_recv_dma_req_nb(cosim_transport_t *t, dma_req_t *req) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    int ret = ring_buf_dequeue(&p->shm.dma_req_ring, req);
    return (ret < 0) ? 1 : 0;  /* ring_buf_dequeue returns -1 if empty */
}

static int shm_recv_msi_nb(cosim_transport_t *t, msi_event_t *ev) {
    transport_shm_priv_t *p = (transport_shm_priv_t *)t->priv;
    int ret = ring_buf_dequeue(&p->shm.msi_ring, ev);
    return (ret < 0) ? 1 : 0;
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
    t->send_dma_data   = shm_send_dma_data;
    t->recv_dma_data   = shm_recv_dma_data;
    t->recv_dma_req_nb = shm_recv_dma_req_nb;
    t->recv_msi_nb     = shm_recv_msi_nb;
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
