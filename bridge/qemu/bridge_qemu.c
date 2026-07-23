#include "bridge_qemu.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

/* Consume a VCS-pushed vf_config arriving inline on the ctrl channel and
 * dispatch it to the device callback (or stash for polling). */
static void bridge_consume_vf_config(bridge_ctx_t *ctx);
static void bridge_consume_vf_event(bridge_ctx_t *ctx);

bridge_ctx_t *bridge_init(const char *shm_name, const char *sock_path) {
    bridge_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    strncpy(ctx->shm_name, shm_name, sizeof(ctx->shm_name) - 1);
    strncpy(ctx->sock_path, sock_path, sizeof(ctx->sock_path) - 1);
    ctx->listen_fd = -1;
    ctx->client_fd = -1;
    ctx->next_tag = 0;
    ctx->tag_mask = 0x03FF;   /* 10-bit extended tags (1024 outstanding); updated after topology handshake */
    pthread_mutex_init(&ctx->tlp_mutex, NULL);

    if (cosim_shm_create(&ctx->shm, shm_name) < 0) {
        free(ctx);
        return NULL;
    }

    ctx->listen_fd = sock_sync_listen(sock_path);
    if (ctx->listen_fd < 0) {
        cosim_shm_destroy(&ctx->shm, shm_name);
        free(ctx);
        return NULL;
    }

    atomic_store(&ctx->shm.ctrl->qemu_ready, 1);

    return ctx;
}

int bridge_connect(bridge_ctx_t *ctx) {
    ctx->client_fd = sock_sync_accept(ctx->listen_fd);
    return (ctx->client_fd >= 0) ? 0 : -1;
}

int bridge_send_tlp(bridge_ctx_t *ctx, tlp_entry_t *req) {
    req->tag = ctx->next_tag & ctx->tag_mask;
    ctx->next_tag = (ctx->next_tag + 1) & ctx->tag_mask;
    /* P3: ensure multi-function routing fields are initialized */
    if (req->requester_id == 0 && req->target_bdf == 0) {
        /* leave as zero — single-function default */
    }

    if (ctx->trace_enabled) trace_log_tlp(&ctx->trace, req);

    if (ctx->transport) {
        if (ctx->debug)
            fprintf(stderr, "[send_tlp] type=%d tag=%d addr=0x%llx\n",
                    req->type, req->tag, (unsigned long long)req->addr);
        int ret = ctx->transport->send_tlp(ctx->transport, req);
        if (ret < 0) {
            fprintf(stderr, "bridge_send_tlp: transport send_tlp failed\n");
            return -1;
        }
        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        ret = ctx->transport->send_sync(ctx->transport, &msg);
        if (ctx->debug)
            fprintf(stderr, "[send_tlp] sync sent ret=%d\n", ret);
        return ret;
    }

    int ret = ring_buf_enqueue(&ctx->shm.req_ring, req);
    if (ret < 0) {
        fprintf(stderr, "bridge_send_tlp: request queue full\n");
        return -1;
    }

    sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
    return sock_sync_send(ctx->client_fd, &msg);
}

int bridge_wait_completion(bridge_ctx_t *ctx, uint16_t tag, cpl_entry_t *cpl) {
    sync_msg_t msg;
    int ret;
    int drain_guard = 256;  /* bound stale-cpl drain to avoid wedging */

    /* Drain completions until we match the expected tag. Fire-and-forget
       TLPs (CfgWr on the QEMU side) still generate a Cpl from the VCS EP
       (required by PCIe spec for non-posted writes); those cpls land in
       our receive queue with no waiter, so when a new waiter arrives for
       a different tag the queue may contain stale entries. Skip them. */
    while (drain_guard-- > 0) {
        if (ctx->transport) {
            ret = ctx->transport->recv_sync(ctx->transport, &msg);
            if (ret < 0) return -1;
            if (msg.type == SYNC_MSG_VF_CONFIG) {
                /* VCS pushed a VF config (e.g. during a VF-enable CfgWr);
                 * consume it and keep draining for our completion. */
                bridge_consume_vf_config(ctx);
                continue;
            }
            if (msg.type == SYNC_MSG_VF_EVENT) {
                /* VF enable/disable notification — drain the event frame so it
                 * doesn't desync ctrl_fd, then keep draining for our completion. */
                bridge_consume_vf_event(ctx);
                continue;
            }
            if (msg.type != SYNC_MSG_CPL_READY) {
                fprintf(stderr, "bridge_wait_completion: unexpected msg type %d (expected %d)\n",
                        msg.type, SYNC_MSG_CPL_READY);
                return -1;
            }
            ret = ctx->transport->recv_cpl(ctx->transport, cpl);
            if (ret < 0) {
                fprintf(stderr, "bridge_wait_completion: transport recv_cpl failed\n");
                return -1;
            }
        } else {
            ret = sock_sync_recv(ctx->client_fd, &msg);
            if (ret < 0) return -1;
            if (msg.type != SYNC_MSG_CPL_READY) {
                fprintf(stderr, "bridge_wait_completion: unexpected msg type %d\n", msg.type);
                return -1;
            }
            ret = ring_buf_dequeue(&ctx->shm.cpl_ring, cpl);
            if (ret < 0) {
                fprintf(stderr, "bridge_wait_completion: completion queue empty\n");
                return -1;
            }
        }

        if (ctx->trace_enabled) trace_log_cpl(&ctx->trace, cpl);

        if (cpl->tag == tag) {
            if (ctx->debug)
                fprintf(stderr, "[cpl] tag=%d len=%d data[0..7]=%02x %02x %02x %02x %02x %02x %02x %02x\n",
                        cpl->tag, cpl->len,
                        cpl->data[0], cpl->data[1], cpl->data[2], cpl->data[3],
                        cpl->data[4], cpl->data[5], cpl->data[6], cpl->data[7]);
            return 0;
        }
        /* Stale cpl (likely from a prior fire-and-forget TLP) — drop and retry. */
    }

    fprintf(stderr, "bridge_wait_completion: drained 256 stale cpls without matching tag=%d\n",
            tag);
    return -1;
}

int bridge_send_tlp_and_wait(bridge_ctx_t *ctx, tlp_entry_t *req, cpl_entry_t *cpl) {
    pthread_mutex_lock(&ctx->tlp_mutex);
    int ret = bridge_send_tlp(ctx, req);
    if (ret < 0) {
        pthread_mutex_unlock(&ctx->tlp_mutex);
        return ret;
    }
    ret = bridge_wait_completion(ctx, req->tag, cpl);
    pthread_mutex_unlock(&ctx->tlp_mutex);
    return ret;
}

int bridge_wait_completion_timed(bridge_ctx_t *ctx, uint16_t tag,
                                 cpl_entry_t *cpl, int timeout_ms) {
    /* SHM or a transport without timed recv → fall back to the blocking wait. */
    if (!ctx->transport || !ctx->transport->recv_sync_timed)
        return bridge_wait_completion(ctx, tag, cpl);

    sync_msg_t msg;
    int ret;
    int drain_guard = 256;  /* bound stale-cpl drain (same as bridge_wait_completion) */
    while (drain_guard-- > 0) {
        ret = ctx->transport->recv_sync_timed(ctx->transport, &msg, timeout_ms);
        if (ret == 1) return -2;   /* poll timeout: VCS did not answer within timeout_ms */
        if (ret != 0) return -1;
        if (msg.type == SYNC_MSG_VF_CONFIG) {
            bridge_consume_vf_config(ctx);
            continue;
        }
        if (msg.type == SYNC_MSG_VF_EVENT) {
            bridge_consume_vf_event(ctx);
            continue;
        }
        if (msg.type != SYNC_MSG_CPL_READY) {
            fprintf(stderr, "bridge_wait_completion_timed: unexpected msg type %d\n", msg.type);
            return -1;
        }
        if (ctx->transport->recv_cpl(ctx->transport, cpl) < 0) {
            fprintf(stderr, "bridge_wait_completion_timed: recv_cpl failed\n");
            return -1;
        }
        if (ctx->trace_enabled) trace_log_cpl(&ctx->trace, cpl);
        if (cpl->tag == tag) return 0;
        /* stale cpl (prior fire-and-forget TLP) — drop and retry */
    }
    return -1;
}

int bridge_send_tlp_and_wait_timed(bridge_ctx_t *ctx, tlp_entry_t *req,
                                   cpl_entry_t *cpl, int timeout_ms) {
    pthread_mutex_lock(&ctx->tlp_mutex);
    int ret = bridge_send_tlp(ctx, req);
    if (ret < 0) {
        pthread_mutex_unlock(&ctx->tlp_mutex);
        return ret;
    }
    ret = bridge_wait_completion_timed(ctx, req->tag, cpl, timeout_ms);
    pthread_mutex_unlock(&ctx->tlp_mutex);
    return ret;
}

int bridge_send_tlp_fire(bridge_ctx_t *ctx, tlp_entry_t *req) {
    pthread_mutex_lock(&ctx->tlp_mutex);
    int ret = bridge_send_tlp(ctx, req);
    pthread_mutex_unlock(&ctx->tlp_mutex);
    return ret;
}

int bridge_complete_dma(bridge_ctx_t *ctx, uint32_t tag, uint32_t status) {
    dma_cpl_t cpl = { .tag = tag, .status = status, .timestamp = 0 };

    if (ctx->transport) {
        int ret = ctx->transport->send_dma_cpl(ctx->transport, &cpl);
        if (ret < 0) return -1;
        sync_msg_t msg = { .type = SYNC_MSG_DMA_CPL, .payload = tag };
        return ctx->transport->send_sync(ctx->transport, &msg);
    }

    int ret = ring_buf_enqueue(&ctx->shm.dma_cpl_ring, &cpl);
    if (ret < 0) return -1;
    sync_msg_t msg = { .type = SYNC_MSG_DMA_CPL, .payload = tag };
    return sock_sync_send(ctx->client_fd, &msg);
}

int bridge_complete_dma_with_data(bridge_ctx_t *ctx, uint32_t tag,
                                  uint32_t status, uint32_t direction,
                                  uint64_t host_addr, const uint8_t *data,
                                  uint32_t len) {
    if (ctx->transport) {
        int ret = ctx->transport->send_dma_data(ctx->transport, tag, direction,
                                                 host_addr, data, len);
        if (ret < 0) return -1;
        dma_cpl_t cpl = { .tag = tag, .status = status, .timestamp = 0 };
        ret = ctx->transport->send_dma_cpl(ctx->transport, &cpl);
        if (ret < 0) return -1;
        sync_msg_t msg = { .type = SYNC_MSG_DMA_CPL, .payload = tag };
        return ctx->transport->send_sync(ctx->transport, &msg);
    }

    /* SHM mode: data is already in shared dma_buf, just send completion */
    return bridge_complete_dma(ctx, tag, status);
}

int bridge_enable_trace(bridge_ctx_t *ctx, const char *path, trace_fmt_t fmt) {
    if (!ctx) return -1;
    if (ctx->trace_enabled) return 0;
    if (trace_log_open(&ctx->trace, path, fmt) < 0) return -1;
    ctx->trace_enabled = 1;
    return 0;
}

void bridge_disable_trace(bridge_ctx_t *ctx) {
    if (!ctx) return;
    if (ctx->trace_enabled) {
        trace_log_close(&ctx->trace);
        ctx->trace_enabled = 0;
    }
}

int bridge_request_mode_switch(bridge_ctx_t *ctx, cosim_mode_t target_mode) {
    if (ctx->transport) {
        fprintf(stderr, "bridge_request_mode_switch: not supported in TCP mode\n");
        return -1;
    }
    atomic_store(&ctx->shm.ctrl->target_mode, target_mode);
    atomic_store(&ctx->shm.ctrl->mode_switch_pending, 1);
    sync_msg_t msg = { .type = SYNC_MSG_MODE_SWITCH, .payload = target_mode };
    return sock_sync_send(ctx->client_fd, &msg);
}

cosim_mode_t bridge_get_mode(bridge_ctx_t *ctx) {
    if (ctx->transport) {
        return COSIM_MODE_FAST;  /* no shared ctrl in TCP mode */
    }
    return (cosim_mode_t)ctx->shm.ctrl->mode;
}

int bridge_advance_clock(bridge_ctx_t *ctx, uint64_t cycles) {
    if (ctx->transport) {
        fprintf(stderr, "bridge_advance_clock: not supported in TCP mode\n");
        return -1;
    }
    if (ctx->shm.ctrl->mode != COSIM_MODE_PRECISE) {
        fprintf(stderr, "bridge_advance_clock: not in precise mode\n");
        return -1;
    }

    sync_msg_t req = { .type = SYNC_MSG_CLOCK_STEP, .payload = (uint32_t)cycles };
    if (sock_sync_send(ctx->client_fd, &req) < 0) return -1;

    sync_msg_t ack;
    if (sock_sync_recv(ctx->client_fd, &ack) < 0) return -1;
    if (ack.type != SYNC_MSG_CLOCK_ACK) {
        fprintf(stderr, "bridge_advance_clock: unexpected ack type %d\n", ack.type);
        return -1;
    }

    return 0;
}

void bridge_destroy(bridge_ctx_t *ctx) {
    if (!ctx) return;

    /* 通知 VCS 优雅退出 */
    if (ctx->transport) {
        sync_msg_t msg = { .type = SYNC_MSG_SHUTDOWN };
        ctx->transport->send_sync(ctx->transport, &msg);
        fprintf(stderr, "[bridge] Sent SHUTDOWN to VCS (TCP)\n");
    } else if (ctx->client_fd >= 0) {
        sync_msg_t msg = { .type = SYNC_MSG_SHUTDOWN };
        sock_sync_send(ctx->client_fd, &msg);
        fprintf(stderr, "[bridge] Sent SHUTDOWN to VCS (SHM)\n");
    }

    if (ctx->trace_enabled) {
        trace_log_close(&ctx->trace);
        ctx->trace_enabled = 0;
    }
    if (ctx->transport) {
        ctx->transport->close(ctx->transport);
    } else {
        sock_sync_close(ctx->client_fd);
        sock_sync_close(ctx->listen_fd);
        cosim_shm_destroy(&ctx->shm, ctx->shm_name);
        unlink(ctx->sock_path);
    }
    free(ctx);
}

/* ========== P3: Topology query & BDF-aware TLP ========== */

int bridge_query_topology(bridge_ctx_t *ctx, topology_resp_t *topo) {
    if (!ctx || !topo) return -1;

    sync_msg_t req_msg = { .type = SYNC_MSG_QUERY_TOPOLOGY, .payload = 0 };

    if (ctx->transport) {
        /* TCP mode: send query sync, then recv topology response */
        if (ctx->transport->send_sync(ctx->transport, &req_msg) < 0) {
            fprintf(stderr, "bridge_query_topology: send_sync failed\n");
            return -1;
        }
        /* Wait for TOPOLOGY_RESP sync ack */
        sync_msg_t resp;
        if (ctx->transport->recv_sync(ctx->transport, &resp) < 0) {
            fprintf(stderr, "bridge_query_topology: recv_sync failed\n");
            return -1;
        }
        if (resp.type != SYNC_MSG_TOPOLOGY_RESP) {
            fprintf(stderr, "bridge_query_topology: unexpected sync type %d\n", resp.type);
            return -1;
        }
        /* Recv topology payload via transport */
        if (ctx->transport->recv_topology(ctx->transport, topo) < 0) {
            fprintf(stderr, "bridge_query_topology: recv_topology failed\n");
            return -1;
        }
        return 0;
    }

    /* SHM mode: send query via socket, recv ack, then memcpy from ctrl region */
    if (sock_sync_send(ctx->client_fd, &req_msg) < 0) {
        fprintf(stderr, "bridge_query_topology: sock_sync_send failed\n");
        return -1;
    }
    sync_msg_t resp;
    if (sock_sync_recv(ctx->client_fd, &resp) < 0) {
        fprintf(stderr, "bridge_query_topology: sock_sync_recv failed\n");
        return -1;
    }
    if (resp.type != SYNC_MSG_TOPOLOGY_RESP) {
        fprintf(stderr, "bridge_query_topology: unexpected sync type %d\n", resp.type);
        return -1;
    }
    /* Read topology from ctrl region (after cosim_ctrl_t) */
    const uint8_t *src = (const uint8_t *)ctx->shm.ctrl + sizeof(cosim_ctrl_t);
    memcpy(topo, src, sizeof(*topo));
    return 0;
}

int bridge_send_vf_event(bridge_ctx_t *ctx, const vf_event_t *ev) {
    if (!ctx || !ev) return -1;

    /* Encode vf_event in sync_msg payload (same format as bridge_vcs.c) */
    sync_msg_t msg;
    msg.type    = SYNC_MSG_VF_EVENT;
    msg.payload = ((uint32_t)ev->event_type) |
                  ((uint32_t)ev->pf_index << 8) |
                  ((uint32_t)ev->num_vfs << 16);

    if (ctx->transport) {
        return ctx->transport->send_sync(ctx->transport, &msg);
    }

    return sock_sync_send(ctx->client_fd, &msg);
}

static void bridge_consume_vf_config(bridge_ctx_t *ctx) {
    if (!ctx || !ctx->transport) return;
    if (ctx->transport->recv_vf_config(ctx->transport, &ctx->vf_config) < 0) return;
    if (ctx->vf_config_cb)
        ctx->vf_config_cb(&ctx->vf_config, ctx->vf_config_user);
    else
        ctx->vf_config_pending = 1;
}

/* Drain a VF enable/disable event frame off ctrl_fd. QEMU applies the VF layout
 * from vf_config (not the event); the event is a notification, so we just read
 * and discard it here to keep the ctrl_fd stream aligned. */
static void bridge_consume_vf_event(bridge_ctx_t *ctx) {
    if (!ctx || !ctx->transport) return;
    vf_event_t ev;
    ctx->transport->recv_vf_event(ctx->transport, &ev);
}

/* Bounded drain of VF_CONFIG/VF_EVENT that VCS pushes on ctrl_fd after an
 * SR-IOV VF-enable CfgWr (which is fire-and-forget, so those messages have no
 * waiter). Called synchronously after an extended-config write so the VF
 * apertures/config stubs are applied before the guest probes the VFs. Returns
 * once nothing more arrives within timeout_ms. Safe: config writes run on the
 * vCPU thread (BQL) and the irq_poller never reads ctrl_fd, so no other reader
 * competes here. */
void bridge_drain_vf_pending(bridge_ctx_t *ctx, int timeout_ms) {
    if (!ctx || !ctx->transport || !ctx->transport->recv_sync_timed) return;
    int guard = 64;
    while (guard-- > 0) {
        sync_msg_t msg;
        int ret = ctx->transport->recv_sync_timed(ctx->transport, &msg, timeout_ms);
        if (ret != 0) return;   /* timeout (1) or error (-1): nothing pending */
        if (msg.type == SYNC_MSG_VF_CONFIG) { bridge_consume_vf_config(ctx); continue; }
        if (msg.type == SYNC_MSG_VF_EVENT)  { bridge_consume_vf_event(ctx);  continue; }
        if (msg.type == SYNC_MSG_CPL_READY) {
            /* stray completion (unmatched Cpl) — discard to stay aligned */
            cpl_entry_t cpl;
            ctx->transport->recv_cpl(ctx->transport, &cpl);
            continue;
        }
        return;  /* unknown type — stop rather than mis-parse */
    }
}

int bridge_send_vf_config(bridge_ctx_t *ctx, const vf_config_t *cfg) {
    if (!ctx || !cfg) return -1;
    if (!ctx->transport) return -1;   /* SHM-legacy cannot carry vf_config */
    /* Sync trigger first, then payload (same frame order as topology). */
    sync_msg_t msg = { .type = SYNC_MSG_VF_CONFIG, .payload = 0 };
    if (ctx->transport->send_sync(ctx->transport, &msg) < 0) return -1;
    return ctx->transport->send_vf_config(ctx->transport, cfg);
}

void bridge_set_vf_config_cb(bridge_ctx_t *ctx,
                             void (*cb)(const vf_config_t *cfg, void *user),
                             void *user) {
    if (!ctx) return;
    ctx->vf_config_cb   = cb;
    ctx->vf_config_user = user;
}

int bridge_poll_vf_config(bridge_ctx_t *ctx, vf_config_t *cfg) {
    if (!ctx || !ctx->vf_config_pending) return 0;
    if (cfg) *cfg = ctx->vf_config;
    ctx->vf_config_pending = 0;
    return 1;
}

int bridge_send_tlp_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                         uint16_t requester_id, uint16_t target_bdf) {
    req->requester_id = requester_id;
    req->target_bdf = target_bdf;
    return bridge_send_tlp(ctx, req);
}

int bridge_send_tlp_and_wait_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                                  cpl_entry_t *cpl,
                                  uint16_t requester_id, uint16_t target_bdf) {
    req->requester_id = requester_id;
    req->target_bdf = target_bdf;
    return bridge_send_tlp_and_wait(ctx, req, cpl);
}

/* ========== Transport-aware API (新增) ========== */

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
    ctx->tag_mask = 0x03FF;   /* 10-bit extended tags (1024 outstanding) */
    pthread_mutex_init(&ctx->tlp_mutex, NULL);

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
