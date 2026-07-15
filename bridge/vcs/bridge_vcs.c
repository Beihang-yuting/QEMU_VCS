/* cosim-platform/bridge/vcs/bridge_vcs.c
 * VCS 侧 DPI-C 函数实现，被 SystemVerilog testbench 调用
 */
#include "shm_layout.h"
#include "cosim_types.h"
#include "cosim_topology.h"
#include "cosim_transport.h"
#include "../qemu/sock_sync.h"
#include <string.h>
#include <stdio.h>

/* SHM 模式全局单实例（仅单 RC 使用） */
static cosim_shm_t g_shm;
static int g_sock_fd = -1;
static int g_initialized = 0;

#define TLP_CACHE_SIZE 1024
/* Multi-RC cosim: 多个 QEMU 主机各当一个 root complex，连到同一个 VCS fabric。
 * 每个 RC 一份 rc_ctx_t。默认单 RC 只用 g_rc[0]，故下面把历史单实例全局名
 * #define 成 g_rc[0].xxx —— 现有函数体逐字不改、字节级等价。COSIM_MAX_RCS 给
 * 到 4 留余量。 */
#ifndef COSIM_MAX_RCS
#define COSIM_MAX_RCS 4
#endif
typedef struct {
    cosim_transport_t *transport;      /* 原 g_transport */
    topology_resp_t    topology;       /* 原 g_topology */
    int                topology_ready; /* 原 g_topology_ready */
    int                pending_tlp_ready;
    int                vf_event_pending;
    vf_event_t         vf_event;
    tlp_entry_t        tlp_cache[TLP_CACHE_SIZE];
    int                tlp_cache_head;
    int                tlp_cache_tail;
    int                poll_count;     /* 原 g_poll_count */
    tlp_entry_t        last_entry;     /* 原 g_last_entry */
    int                empty_streak;   /* Phase-4 自适应超时状态（per-RC） */
    int                realized;       /* QEMU device realize done (handshake) */
} rc_ctx_t;

static rc_ctx_t g_rc[COSIM_MAX_RCS];   /* 全零初始化: transport=NULL 等 */
static int      g_num_rc = 1;          /* 默认单 RC */

/* Legacy single-RC aliases → g_rc[0]（阶段0/1: 零行为变化） */
#define g_transport         g_rc[0].transport
#define g_topology          g_rc[0].topology
#define g_topology_ready    g_rc[0].topology_ready
#define g_pending_tlp_ready g_rc[0].pending_tlp_ready
#define g_vf_event_pending  g_rc[0].vf_event_pending
#define g_vf_event          g_rc[0].vf_event
#define g_tlp_cache         g_rc[0].tlp_cache
#define g_tlp_cache_head    g_rc[0].tlp_cache_head
#define g_tlp_cache_tail    g_rc[0].tlp_cache_tail
#define g_poll_count        g_rc[0].poll_count
#define g_last_entry        g_rc[0].last_entry

/* Multi-RC: cache helpers operate on an explicit rc_ctx_t*. Legacy single-RC
 * callers pass &g_rc[0], preserving byte-level behavior. */
static int tlp_cache_push_ctx(rc_ctx_t *ctx, const tlp_entry_t *e) {
    int next = (ctx->tlp_cache_head + 1) % TLP_CACHE_SIZE;
    if (next == ctx->tlp_cache_tail) {
        fprintf(stderr, "[VCS Bridge] TLP cache full! dropping TLP\n");
        return -1;
    }
    ctx->tlp_cache[ctx->tlp_cache_head] = *e;
    ctx->tlp_cache_head = next;
    return 0;
}

static int tlp_cache_pop_ctx(rc_ctx_t *ctx, tlp_entry_t *e) {
    if (ctx->tlp_cache_head == ctx->tlp_cache_tail) return -1;
    *e = ctx->tlp_cache[ctx->tlp_cache_tail];
    ctx->tlp_cache_tail = (ctx->tlp_cache_tail + 1) % TLP_CACHE_SIZE;
    return 0;
}

static int tlp_cache_count_ctx(rc_ctx_t *ctx) __attribute__((unused));
static int tlp_cache_count_ctx(rc_ctx_t *ctx) {
    return (ctx->tlp_cache_head - ctx->tlp_cache_tail + TLP_CACHE_SIZE) % TLP_CACHE_SIZE;
}

/* g_poll_count 与 g_last_entry 现为 g_rc[0].poll_count / g_rc[0].last_entry
 * （见上方 rc_ctx_t 与 #define 别名）。 */

/* DPI-C: 初始化 — 打开 SHM，连接 Socket */
int bridge_vcs_init(const char *shm_name, const char *sock_path) {
    if (g_initialized) return 0;

    if (cosim_shm_open(&g_shm, shm_name) < 0) {
        fprintf(stderr, "[VCS Bridge] Failed to open SHM '%s'\n", shm_name);
        return -1;
    }

    g_sock_fd = sock_sync_connect(sock_path);
    if (g_sock_fd < 0) {
        fprintf(stderr, "[VCS Bridge] Failed to connect Socket '%s'\n", sock_path);
        cosim_shm_close(&g_shm);
        return -1;
    }

    /* 标记 VCS 就绪 */
    atomic_store(&g_shm.ctrl->vcs_ready, 1);
    g_initialized = 1;
    fprintf(stderr, "[VCS Bridge] Initialized: shm=%s sock=%s\n", shm_name, sock_path);
    return 0;
}

/* ========== P3: Topology DPI-C functions ========== */

/* DPI-C: Set topology for one PF (called from SV testbench during init) */
void bridge_vcs_set_pf_topology(int pf_idx,
                                 int bdf, int num_vfs, int vf_device_id,
                                 int vendor_id, int device_id,
                                 int msix_vectors, int vf_msix_vectors,
                                 unsigned long long pf_bar0, unsigned long long pf_bar1,
                                 unsigned long long pf_bar2, unsigned long long pf_bar3,
                                 unsigned long long pf_bar4, unsigned long long pf_bar5,
                                 unsigned long long vf_bar0, unsigned long long vf_bar1,
                                 unsigned long long vf_bar2, unsigned long long vf_bar3,
                                 unsigned long long vf_bar4, unsigned long long vf_bar5) {
    if (pf_idx < 0 || pf_idx >= COSIM_MAX_PFS) {
        fprintf(stderr, "[VCS Bridge] set_pf_topology: invalid pf_idx=%d\n", pf_idx);
        return;
    }
    pf_topology_t *pf = &g_topology.pfs[pf_idx];
    memset(pf, 0, sizeof(*pf));
    pf->bdf             = (uint16_t)bdf;
    pf->num_vfs         = (uint16_t)num_vfs;
    pf->vf_device_id    = (uint16_t)vf_device_id;
    pf->vendor_id       = (uint16_t)vendor_id;
    pf->device_id       = (uint16_t)device_id;
    pf->msix_vectors    = (uint16_t)msix_vectors;
    pf->vf_msix_vectors = (uint16_t)vf_msix_vectors;
    pf->pf_bar_size[0]  = pf_bar0;
    pf->pf_bar_size[1]  = pf_bar1;
    pf->pf_bar_size[2]  = pf_bar2;
    pf->pf_bar_size[3]  = pf_bar3;
    pf->pf_bar_size[4]  = pf_bar4;
    pf->pf_bar_size[5]  = pf_bar5;
    pf->vf_bar_size[0]  = vf_bar0;
    pf->vf_bar_size[1]  = vf_bar1;
    pf->vf_bar_size[2]  = vf_bar2;
    pf->vf_bar_size[3]  = vf_bar3;
    pf->vf_bar_size[4]  = vf_bar4;
    pf->vf_bar_size[5]  = vf_bar5;
    fprintf(stderr, "[VCS Bridge] set_pf_topology: pf[%d] bdf=0x%04x vfs=%d\n",
            pf_idx, bdf, num_vfs);
}

/* DPI-C: Finalize topology (marks it ready for queries) */
void bridge_vcs_finalize_topology(int num_pfs, int tag_width) {
    g_topology.header.num_pfs  = (uint8_t)num_pfs;
    g_topology.header.tag_width = (uint8_t)tag_width;
    memset(g_topology.header.pad, 0, sizeof(g_topology.header.pad));
    g_topology_ready = 1;
    fprintf(stderr, "[VCS Bridge] finalize_topology: num_pfs=%d tag_width=%d\n",
            num_pfs, tag_width);
}

/* Internal: Handle a QUERY_TOPOLOGY request from QEMU (per-RC ctx).
 * SHM branch uses the single-RC globals g_shm/g_sock_fd (SHM mode is
 * single-RC by construction — multi-RC always runs over a transport). */
static int handle_topology_query_ctx(rc_ctx_t *ctx) {
    if (!ctx->topology_ready) {
        fprintf(stderr, "[VCS Bridge] handle_topology_query: topology not ready\n");
        return -1;
    }

    if (ctx->transport) {
        /* TCP mode: send sync ack first, then topology payload.
         * Both go on ctrl_fd; QEMU recv_sync reads the sync header first,
         * then recv_topology reads the topology header+payload. */
        sync_msg_t resp = { .type = SYNC_MSG_TOPOLOGY_RESP, .payload = 0 };
        if (ctx->transport->send_sync(ctx->transport, &resp) < 0) {
            fprintf(stderr, "[VCS Bridge] handle_topology_query: send_sync failed\n");
            return -1;
        }
        if (ctx->transport->send_topology(ctx->transport, &ctx->topology) < 0) {
            fprintf(stderr, "[VCS Bridge] handle_topology_query: send_topology failed\n");
            return -1;
        }
        return 0;
    }

    /* SHM mode: write topology to ctrl region, then send sync ack */
    uint8_t *dst = (uint8_t *)g_shm.ctrl + sizeof(cosim_ctrl_t);
    memcpy(dst, &ctx->topology, sizeof(ctx->topology));
    sync_msg_t resp = { .type = SYNC_MSG_TOPOLOGY_RESP, .payload = 0 };
    return sock_sync_send(g_sock_fd, &resp);
}

/* DPI-C: Send VF event (enable/disable) to QEMU */
int bridge_vcs_send_vf_event(int event_type, int pf_index, int num_vfs) {
    vf_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.event_type = (uint8_t)event_type;
    ev.pf_index   = (uint8_t)pf_index;
    ev.num_vfs    = (uint16_t)num_vfs;

    if (g_transport) {
        if (g_transport->send_vf_event(g_transport, &ev) < 0) return -1;
        sync_msg_t msg = { .type = SYNC_MSG_VF_EVENT, .payload = 0 };
        return g_transport->send_sync(g_transport, &msg);
    }

    /* SHM mode: just send sync with encoded payload */
    sync_msg_t msg = { .type = SYNC_MSG_VF_EVENT,
                       .payload = ((uint32_t)event_type) |
                                  ((uint32_t)pf_index << 8) |
                                  ((uint32_t)num_vfs << 16) };
    return sock_sync_send(g_sock_fd, &msg);
}

/* DPI-C: Get target_bdf from most recently polled TLP */
int bridge_vcs_get_tlp_target_bdf(void) {
    return (int)g_last_entry.target_bdf;
}

/* DPI-C: Get requester_id from most recently polled TLP */
int bridge_vcs_get_tlp_requester_id(void) {
    return (int)g_last_entry.requester_id;
}

/* DPI-C: Check for pending VF event from QEMU.
 * Returns 1 if an event is pending, 0 otherwise.
 * event_type, pf_index, num_vfs are output parameters. */
int bridge_vcs_poll_vf_event(int *event_type, int *pf_index, int *num_vfs) {
    if (!g_vf_event_pending) return 0;
    *event_type = g_vf_event.event_type;
    *pf_index   = g_vf_event.pf_index;
    *num_vfs    = g_vf_event.num_vfs;
    g_vf_event_pending = 0;
    return 1;
}

/* DPI-C: 轮询请求队列，获取一个 TLP
 * 返回: 0=成功取到, 1=队列空（无新事务）, -1=错误
 */
static int poll_tlp_ctx(rc_ctx_t *ctx,
                         unsigned char *tlp_type, unsigned long long *addr,
                         unsigned int *data, int *len, int *tag) {
    ctx->poll_count++;

    /* ---- TCP transport path ----
     *
     * 分层策略解决 QEMU 实时 vs VCS 仿真时间不匹配：
     *   Phase 1: 从 TLP 缓存取（DMA 期间缓存的 TLP，零延迟）
     *   Phase 2: 非阻塞批量 drain ctrl_fd（读取所有已到达的 TLP_READY）
     *   Phase 3: 缓存非空则返回一个
     *   Phase 4: 带超时等待（适配跨机 TCP 延迟，避免丢失在途消息）
     */
    if (ctx->transport) {
        tlp_entry_t entry;
        sync_msg_t msg;
        int ret;

        /* Phase 1: TLP 缓存优先 */
        if (tlp_cache_pop_ctx(ctx, &entry) == 0)
            goto return_entry;

        /* Phase 2: 非阻塞批量 drain — 一次读完 ctrl_fd 中所有 TLP_READY */
        for (;;) {
            ret = ctx->transport->recv_sync_timed(ctx->transport, &msg, 0);
            if (ret < 0) return -1;
            if (ret == 1) break;  /* ctrl_fd 为空，drain 完成 */
            if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
            if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
                handle_topology_query_ctx(ctx);
                continue;
            }
            if (msg.type == SYNC_MSG_TLP_READY) {
                if (ctx->transport->recv_tlp(ctx->transport, &entry) == 0)
                    tlp_cache_push_ctx(ctx, &entry);
                continue;
            }
            if (msg.type == SYNC_MSG_VF_EVENT) {
                ctx->vf_event.event_type = (uint8_t)(msg.payload & 0xFF);
                ctx->vf_event.pf_index   = (uint8_t)((msg.payload >> 8) & 0xFF);
                ctx->vf_event.num_vfs    = (uint16_t)((msg.payload >> 16) & 0xFFFF);
                ctx->vf_event_pending = 1;
                continue;
            }
            /* 非 TLP_READY 消息在 poll 中不应出现，记录并跳过 */
            if (msg.type == SYNC_MSG_REALIZED) { ctx->realized = 1; continue; }
        fprintf(stderr, "[VCS poll] unexpected msg.type=%d in drain, discarding\n", msg.type);
        }

        /* Phase 3: drain 后缓存可能有 TLP */
        if (tlp_cache_pop_ctx(ctx, &entry) == 0)
            goto return_entry;

        /* Phase 4: 自适应超时等待 — 跨机 TCP 传输延迟可达数毫秒。
         * 刚收到过 TLP 时用短超时（1ms）快速响应后续包；
         * 连续空 poll 后递增到较长超时（50ms）减少 CPU 空转；
         * 收到 TLP 后重置为短超时。empty_streak 存 per-RC ctx，避免两个 RC 互相干扰。 */
        {
            int timeout_ms = (ctx->empty_streak < 5) ? 1 :
                             (ctx->empty_streak < 20) ? 5 : 50;
            ret = ctx->transport->recv_sync_timed(ctx->transport, &msg, timeout_ms);
            if (ret < 0) return -1;
            if (ret == 1) {
                ctx->empty_streak++;
                return 1;  /* 超时，无新 TLP */
            }
            ctx->empty_streak = 0;  /* 收到数据，重置 */
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
            handle_topology_query_ctx(ctx);
            return 1;  /* no TLP this iteration, let SV loop re-enter */
        }
        if (msg.type == SYNC_MSG_VF_EVENT) {
            ctx->vf_event.event_type = (uint8_t)(msg.payload & 0xFF);
            ctx->vf_event.pf_index   = (uint8_t)((msg.payload >> 8) & 0xFF);
            ctx->vf_event.num_vfs    = (uint16_t)((msg.payload >> 16) & 0xFFFF);
            ctx->vf_event_pending = 1;
            return 1;
        }
        if (msg.type == SYNC_MSG_TLP_READY) {
            if (ctx->transport->recv_tlp(ctx->transport, &entry) < 0) return 1;
            goto return_entry;
        }
        if (msg.type == SYNC_MSG_REALIZED) { ctx->realized = 1; return 1; }
        fprintf(stderr, "[VCS poll] unexpected msg.type=%d after wait, discarding\n", msg.type);
        return 1;

    return_entry:
        ctx->last_entry = entry;
        *tlp_type = entry.type;
        *addr = entry.addr;
        *len = entry.len;
        *tag = entry.tag;
        int words = (entry.len + 3) / 4;
        for (int i = 0; i < words && i < 16; i++)
            memcpy(&data[i], &entry.data[i * 4], 4);
        return 0;
    }

    /* ---- SHM path (original, single-RC only) ---- */

    /* If TLP_READY messages were consumed during DMA waits, dequeue
     * directly from the SHM ring without waiting for socket notification. */
    if (ctx->pending_tlp_ready > 0) {
        tlp_entry_t entry;
        int dret = ring_buf_dequeue(&g_shm.req_ring, &entry);
        if (dret == 0) {
            ctx->pending_tlp_ready--;
            ctx->last_entry = entry;
            *tlp_type = entry.type;
            *addr = entry.addr;
            *len = entry.len;
            *tag = entry.tag;
            int words = (entry.len + 3) / 4;
            for (int i = 0; i < words && i < 16; i++)
                memcpy(&data[i], &entry.data[i * 4], 4);
            return 0;
        }
        /* Ring empty despite pending count — reset counter */
        ctx->pending_tlp_ready = 0;
    }

    /* Check Socket with 0ms timeout (non-blocking) — VCS Q-2020 segfaults
     * when $finish fires during a blocking poll/select syscall on Linux 6.17.
     * SV-side #delay provides the pacing instead. */
    sync_msg_t msg;
    int ret = sock_sync_recv_timed(g_sock_fd, &msg, 0);
    if (ret < 0) return -1;
    if (ret == 1) return 1;  /* timeout — no TLP, allow RX poll */
    if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
        handle_topology_query_ctx(ctx);
        return 1;  /* handled, no TLP this iteration */
    }
    if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
    if (msg.type == SYNC_MSG_VF_EVENT) {
        ctx->vf_event.event_type = (uint8_t)(msg.payload & 0xFF);
        ctx->vf_event.pf_index   = (uint8_t)((msg.payload >> 8) & 0xFF);
        ctx->vf_event.num_vfs    = (uint16_t)((msg.payload >> 16) & 0xFFFF);
        ctx->vf_event_pending = 1;
        return 1; /* no TLP, but VF event is pending for SV to pick up */
    }
    if (msg.type != SYNC_MSG_TLP_READY) {
        return 1; /* 非 TLP 消息，返回空 */
    }

    /* 从请求队列出队 */
    tlp_entry_t entry;
    ret = ring_buf_dequeue(&g_shm.req_ring, &entry);
    if (ret < 0) return 1;

    ctx->last_entry = entry;
    *tlp_type = entry.type;
    *addr = entry.addr;
    *len = entry.len;
    *tag = entry.tag;
    /* 拷贝数据到 data 数组（按 4 字节对齐） */
    int words = (entry.len + 3) / 4;
    for (int i = 0; i < words && i < 16; i++) {
        memcpy(&data[i], &entry.data[i * 4], 4);
    }

    return 0;
}

/* DPI-C: 轮询请求队列，获取一个 TLP（legacy 单 RC = g_rc[0]）
 * 返回: 0=成功取到, 1=队列空（无新事务）, -1=错误 */
int bridge_vcs_poll_tlp(unsigned char *tlp_type, unsigned long long *addr,
                         unsigned int *data, int *len, int *tag) {
    return poll_tlp_ctx(&g_rc[0], tlp_type, addr, data, len, tag);
}

/* DPI-C: Extended poll (VIP mode) — same as poll_tlp but also returns
 * msg_code, atomic_op_size, vendor_id, first_be, last_be from tlp_entry_t. */
int bridge_vcs_poll_tlp_ext(unsigned char *tlp_type, unsigned long long *addr,
                             unsigned int *data, int *len, int *tag,
                             unsigned char *msg_code,
                             unsigned char *atomic_op_size,
                             unsigned short *vendor_id,
                             unsigned char *first_be,
                             unsigned char *last_be) {
    int ret = bridge_vcs_poll_tlp(tlp_type, addr, data, len, tag);
    if (ret != 0) return ret;

    /* Re-peek the entry for extended fields.  Since poll_tlp already dequeued,
     * we store a copy of the last dequeued entry in a static. */
    *msg_code       = g_last_entry.msg_code;
    *atomic_op_size = g_last_entry.atomic_op_size;
    *vendor_id      = g_last_entry.vendor_id;
    *first_be       = g_last_entry.first_be;
    *last_be        = g_last_entry.last_be;
    return 0;
}

static int send_completion_ctx(rc_ctx_t *ctx, int tag, const unsigned int *data, int len) {
    cpl_entry_t cpl;
    memset(&cpl, 0, sizeof(cpl));
    cpl.type = TLP_CPL;
    cpl.tag = (uint16_t)tag;
    cpl.status = 0;
    cpl.requester_id = 0;     /* P3: default single-function */
    cpl.completer_id = 0;     /* P3: default single-function */
    cpl.len = len;

    int bytes = (len < COSIM_TLP_DATA_SIZE) ? len : COSIM_TLP_DATA_SIZE;
    int words = (bytes + 3) / 4;
    for (int i = 0; i < words; i++) {
        memcpy(&cpl.data[i * 4], &data[i], 4);
    }

    /* ---- TCP transport path ---- */
    if (ctx->transport) {
        if (ctx->transport->send_cpl(ctx->transport, &cpl) < 0) {
            fprintf(stderr, "[VCS Bridge] send_cpl failed\n");
            return -1;
        }
        sync_msg_t msg = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        return ctx->transport->send_sync(ctx->transport, &msg);
    }

    /* ---- SHM path (original, single-RC only) ---- */
    int ret = ring_buf_enqueue(&g_shm.cpl_ring, &cpl);
    if (ret < 0) {
        fprintf(stderr, "[VCS Bridge] Completion queue full\n");
        return -1;
    }

    /* 通知 QEMU */
    sync_msg_t msg = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
    return sock_sync_send(g_sock_fd, &msg);
}

/* DPI-C: 发送 Completion（legacy 单 RC = g_rc[0]） */
int bridge_vcs_send_completion(int tag, const unsigned int *data, int len) {
    return send_completion_ctx(&g_rc[0], tag, data, len);
}

/* DPI-C: VCS initiates DMA request */
int bridge_vcs_dma_request(int direction, unsigned long long host_addr,
                            const unsigned int *data, int len,
                            int *out_tag) {
    static uint32_t next_tag = 1000;

    /* ---- TCP transport path ---- */
    if (g_transport) {
        uint32_t tag = next_tag++;

        /* For WRITE: send data before the request so QEMU has it */
        if (direction == DMA_DIR_WRITE) {
            if (g_transport->send_dma_data(g_transport, tag, DMA_DIR_WRITE,
                                            host_addr, (const uint8_t *)data, (uint32_t)len) < 0) {
                fprintf(stderr, "[VCS Bridge] dma_request: send_dma_data failed\n");
                return -1;
            }
        }

        dma_req_t req = {
            .tag = tag,
            .direction = (uint32_t)direction,
            .host_addr = host_addr,
            .len = (uint32_t)len,
            .dma_offset = 0,  /* unused in TCP mode */
            .timestamp = 0,
        };

        if (g_transport->send_dma_req(g_transport, &req) < 0) {
            fprintf(stderr, "[VCS Bridge] dma_request: send_dma_req failed\n");
            return -1;
        }

        *out_tag = (int)tag;
        return 0;
    }

    /* ---- SHM path (original) ---- */

    /* Simple bump offset for DMA buffer — wraps if exceeds dma_buf_size */
    static uint32_t bump_offset = 0;
    uint32_t aligned_len = (len + 63) & ~63;
    if (bump_offset + aligned_len > g_shm.dma_buf_size) {
        bump_offset = 0;
    }
    uint32_t offset = bump_offset;
    bump_offset += aligned_len;

    /* Write data if WRITE direction */
    if (direction == DMA_DIR_WRITE) {
        memcpy((uint8_t *)g_shm.dma_buf + offset, data, len);
    }

    dma_req_t req = {
        .tag = next_tag++,
        .direction = (uint32_t)direction,
        .host_addr = host_addr,
        .len = (uint32_t)len,
        .dma_offset = offset,
        .timestamp = 0,
    };

    if (ring_buf_enqueue(&g_shm.dma_req_ring, &req) < 0) {
        return -1;
    }

    *out_tag = (int)req.tag;
    return 0;
}

/* DPI-C: Synchronous DMA read — VCS reads data from Guest memory.
 * Blocks until QEMU completes the DMA and sends back SYNC_MSG_DMA_CPL. */
int bridge_vcs_dma_read_sync(unsigned long long host_addr,
                              unsigned int *data, int len) {
    if (!g_initialized || len <= 0) return -1;

    static uint32_t next_tag = 2000;

    /* ---- TCP transport path ---- */
    if (g_transport) {
        uint32_t tag = next_tag++;
        dma_req_t req = {
            .tag = tag,
            .direction = DMA_DIR_READ,
            .host_addr = host_addr,
            .len = (uint32_t)len,
            .dma_offset = 0,  /* unused in TCP mode */
            .timestamp = 0,
        };

        if (g_transport->send_dma_req(g_transport, &req) < 0) {
            fprintf(stderr, "[VCS Bridge] DMA read sync: send_dma_req failed\n");
            return -1;
        }

        /* Wait for SYNC_MSG_DMA_CPL */
        for (int i = 0; i < 1000; i++) {
            sync_msg_t msg;
            int ret = g_transport->recv_sync(g_transport, &msg);
            if (ret < 0) {
                fprintf(stderr, "[VCS Bridge] DMA read sync: recv_sync error\n");
                return -1;
            }
            if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
            if (msg.type == SYNC_MSG_TLP_READY) {
                /* 立即 recv_tlp 并缓存，避免 data channel 消息错位 */
                tlp_entry_t cached_tlp;
                if (g_transport->recv_tlp(g_transport, &cached_tlp) == 0) {
                    tlp_cache_push_ctx(&g_rc[0], &cached_tlp);
                } else {
                    fprintf(stderr, "[VCS Bridge] dma_wait: recv_tlp for cache failed\n");
                }
                continue;
            }
            if (msg.type == SYNC_MSG_DMA_CPL) {
                /* QEMU bridge_complete_dma_with_data sends DMA_DATA before DMA_CPL
                 * on aux; read the data first, then the completion (order must match). */
                uint32_t rx_tag, rx_dir, rx_len;
                uint64_t rx_addr;
                uint8_t tmp_buf[64];
                rx_len = (uint32_t)len;
                if (g_transport->recv_dma_data(g_transport, &rx_tag, &rx_dir,
                                                &rx_addr, tmp_buf, &rx_len) < 0) {
                    fprintf(stderr, "[VCS Bridge] DMA read sync: recv_dma_data failed\n");
                    return -1;
                }
                dma_cpl_t cpl;
                if (g_transport->recv_dma_cpl(g_transport, &cpl) < 0) {
                    fprintf(stderr, "[VCS Bridge] DMA read sync: recv_dma_cpl failed\n");
                    return -1;
                }
                if (cpl.tag != tag || cpl.status != 0) {
                    fprintf(stderr, "[VCS Bridge] DMA read: cpl tag=%u status=%u (expected tag=%u)\n",
                            cpl.tag, cpl.status, tag);
                    return -1;
                }
                int words = (len + 3) / 4;
                for (int w = 0; w < words && w < 16; w++)
                    memcpy(&data[w], tmp_buf + w * 4, 4);
                return 0;
            }
        }
        fprintf(stderr, "[VCS Bridge] DMA read sync: timeout (TCP)\n");
        return -1;
    }

    /* ---- SHM path (original) ---- */

    /* Allocate DMA buffer offset */
    static uint32_t bump_offset = 0;
    uint32_t aligned_len = ((uint32_t)len + 63) & ~63u;
    if (bump_offset + aligned_len > g_shm.dma_buf_size) {
        bump_offset = 0;
    }
    uint32_t offset = bump_offset;
    bump_offset += aligned_len;

    /* Enqueue DMA read request */
    uint32_t tag = next_tag++;
    dma_req_t req = {
        .tag = tag,
        .direction = DMA_DIR_READ,
        .host_addr = host_addr,
        .len = (uint32_t)len,
        .dma_offset = offset,
        .timestamp = 0,
    };

    if (ring_buf_enqueue(&g_shm.dma_req_ring, &req) < 0) {
        fprintf(stderr, "[VCS Bridge] DMA req ring full\n");
        return -1;
    }

    /* Wait for SYNC_MSG_DMA_CPL from QEMU */
    int max_retries = 1000;
    for (int i = 0; i < max_retries; i++) {
        sync_msg_t msg;
        int ret = sock_sync_recv_timed(g_sock_fd, &msg, 5000);
        if (ret < 0) {
            fprintf(stderr, "[VCS Bridge] DMA read sync: socket error\n");
            return -1;
        }
        if (ret == 1) {
            fprintf(stderr, "[VCS Bridge] DMA read sync: wait timeout (iter=%d tag=%u)\n", i, tag);
            continue;
        }
        if (msg.type == SYNC_MSG_DMA_CPL) {
            dma_cpl_t cpl;
            if (ring_buf_dequeue(&g_shm.dma_cpl_ring, &cpl) == 0) {
                if (cpl.tag == tag && cpl.status == 0) {
                    uint8_t *src = (uint8_t *)g_shm.dma_buf + offset;
                    int words = (len + 3) / 4;
                    for (int w = 0; w < words && w < 16; w++) {
                        memcpy(&data[w], src + w * 4, 4);
                    }
                    return 0;
                }
                fprintf(stderr, "[VCS Bridge] DMA read: cpl tag=%u status=%u (expected tag=%u)\n",
                        cpl.tag, cpl.status, tag);
                return -1;
            }
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_TLP_READY) g_pending_tlp_ready++;
    }
    fprintf(stderr, "[VCS Bridge] DMA read sync: timeout\n");
    return -1;
}

/* DPI-C: Synchronous DMA write — VCS writes data to Guest memory.
 * Blocks until QEMU completes the DMA. */
int bridge_vcs_dma_write_sync(unsigned long long host_addr,
                               const unsigned int *data, int len) {
    if (!g_initialized || len <= 0) return -1;

    /* DEBUG: MSI-X delivery visibility (0xFEE region = APIC MSI doorbell) */
    if (host_addr >= 0xFEE00000ULL && host_addr < 0xFEF00000ULL)
        fprintf(stderr, "[MSIX-DELIVER] addr=0x%llx data=0x%08x len=%d\n",
                host_addr, data ? data[0] : 0, len);

    static uint32_t next_tag = 3000;

    /* ---- TCP transport path ---- */
    if (g_transport) {
        uint32_t tag = next_tag++;

        /* Send DMA_REQ before DMA_DATA. QEMU's irq_poller peeks the aux
         * channel by type expecting DMA_REQ first; if DMA_DATA arrives first
         * it clogs the channel and the request is never dispatched to
         * cosim_dma_cb (so an MSI-X doorbell write to 0xFEE... never reaches
         * pci_dma_write and no interrupt is delivered). Same ordering as
         * bridge_dma_write_bytes. */
        dma_req_t req = {
            .tag = tag,
            .direction = DMA_DIR_WRITE,
            .host_addr = host_addr,
            .len = (uint32_t)len,
            .dma_offset = 0,  /* unused in TCP mode */
            .timestamp = 0,
        };

        if (g_transport->send_dma_req(g_transport, &req) < 0) {
            fprintf(stderr, "[VCS Bridge] DMA write sync: send_dma_req failed\n");
            return -1;
        }

        if (g_transport->send_dma_data(g_transport, tag, DMA_DIR_WRITE,
                                        host_addr, (const uint8_t *)data, (uint32_t)len) < 0) {
            fprintf(stderr, "[VCS Bridge] DMA write sync: send_dma_data failed\n");
            return -1;
        }

        /* Wait for SYNC_MSG_DMA_CPL */
        for (int i = 0; i < 1000; i++) {
            sync_msg_t msg;
            int ret = g_transport->recv_sync(g_transport, &msg);
            if (ret < 0) {
                fprintf(stderr, "[VCS Bridge] DMA write sync: recv_sync error\n");
                return -1;
            }
            if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
            if (msg.type == SYNC_MSG_TLP_READY) {
                /* 立即 recv_tlp 并缓存，避免 data channel 消息错位 */
                tlp_entry_t cached_tlp;
                if (g_transport->recv_tlp(g_transport, &cached_tlp) == 0) {
                    tlp_cache_push_ctx(&g_rc[0], &cached_tlp);
                } else {
                    fprintf(stderr, "[VCS Bridge] dma_wait: recv_tlp for cache failed\n");
                }
                continue;
            }
            if (msg.type == SYNC_MSG_DMA_CPL) {
                dma_cpl_t cpl;
                if (g_transport->recv_dma_cpl(g_transport, &cpl) < 0) {
                    fprintf(stderr, "[VCS Bridge] DMA write sync: recv_dma_cpl failed\n");
                    return -1;
                }
                if (cpl.tag == tag && cpl.status == 0)
                    return 0;
                fprintf(stderr, "[VCS Bridge] DMA write: cpl tag=%u status=%u (expected tag=%u)\n",
                        cpl.tag, cpl.status, tag);
                return -1;
            }
        }
        fprintf(stderr, "[VCS Bridge] DMA write sync: timeout (TCP)\n");
        return -1;
    }

    /* ---- SHM path (original) ---- */

    static uint32_t bump_offset = 0;
    uint32_t aligned_len = ((uint32_t)len + 63) & ~63u;
    if (bump_offset + aligned_len > g_shm.dma_buf_size) {
        bump_offset = 0;
    }
    uint32_t offset = bump_offset;
    bump_offset += aligned_len;

    uint8_t *dst = (uint8_t *)g_shm.dma_buf + offset;
    memcpy(dst, data, len);

    uint32_t tag = next_tag++;
    dma_req_t req = {
        .tag = tag,
        .direction = DMA_DIR_WRITE,
        .host_addr = host_addr,
        .len = (uint32_t)len,
        .dma_offset = offset,
        .timestamp = 0,
    };

    if (ring_buf_enqueue(&g_shm.dma_req_ring, &req) < 0) {
        fprintf(stderr, "[VCS Bridge] DMA req ring full\n");
        return -1;
    }

    int max_retries = 1000;
    for (int i = 0; i < max_retries; i++) {
        sync_msg_t msg;
        int ret = sock_sync_recv_timed(g_sock_fd, &msg, 5000);
        if (ret < 0) {
            fprintf(stderr, "[VCS Bridge] DMA write sync: socket error\n");
            return -1;
        }
        if (ret == 1) {
            fprintf(stderr, "[VCS Bridge] DMA write sync: wait timeout (iter=%d tag=%u)\n", i, tag);
            continue;
        }
        if (msg.type == SYNC_MSG_DMA_CPL) {
            dma_cpl_t cpl;
            if (ring_buf_dequeue(&g_shm.dma_cpl_ring, &cpl) == 0) {
                if (cpl.tag == tag && cpl.status == 0) {
                    return 0;
                }
                fprintf(stderr, "[VCS Bridge] DMA write: cpl tag=%u status=%u (expected tag=%u)\n",
                        cpl.tag, cpl.status, tag);
                return -1;
            }
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_TLP_READY) g_pending_tlp_ready++;
    }
    fprintf(stderr, "[VCS Bridge] DMA write sync: timeout\n");
    return -1;
}

/* fwd decl: rc_ok 定义在下方(~1265),这些新 _rc 入向函数在其前调用 */
static int rc_ok(int rc);

/* DPI-C: Per-RC synchronous DMA read — DUT (requester) reads Guest memory
 * through RC slot `rc`. Mirrors the TCP branch of bridge_vcs_dma_read_sync,
 * scoped to g_rc[rc].transport. Blocks until SYNC_MSG_DMA_CPL.
 * len 上限 64B（DPI data[16]）——超限拒绝，防 tmp_buf 溢出。 */
int bridge_vcs_dma_read_rc(int rc, unsigned long long host_addr,
                           unsigned int *data, int len) {
    if (!rc_ok(rc) || len <= 0 || len > 64) return -1;
    cosim_transport_t *tr = g_rc[rc].transport;
    if (!tr) return -1;

    static uint32_t next_tag = 4000;
    uint32_t tag = next_tag++;
    dma_req_t req = {
        .tag = tag,
        .direction = DMA_DIR_READ,
        .host_addr = host_addr,
        .len = (uint32_t)len,
        .dma_offset = 0,
        .timestamp = 0,
    };

    if (tr->send_dma_req(tr, &req) < 0) {
        fprintf(stderr, "[VCS Bridge] DMA read rc%d: send_dma_req failed\n", rc);
        return -1;
    }

    for (int i = 0; i < 1000; i++) {
        sync_msg_t msg;
        if (tr->recv_sync(tr, &msg) < 0) {
            fprintf(stderr, "[VCS Bridge] DMA read rc%d: recv_sync error\n", rc);
            return -1;
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_TLP_READY) {
            tlp_entry_t cached_tlp;
            if (tr->recv_tlp(tr, &cached_tlp) == 0)
                tlp_cache_push_ctx(&g_rc[rc], &cached_tlp);
            continue;
        }
        if (msg.type == SYNC_MSG_DMA_CPL) {
            /* QEMU bridge_complete_dma_with_data sends DMA_DATA before DMA_CPL on aux;
             * read the data first, then the completion (order must match sender). */
            uint32_t rx_tag, rx_dir, rx_len = (uint32_t)len;
            uint64_t rx_addr;
            uint8_t tmp_buf[64];
            if (tr->recv_dma_data(tr, &rx_tag, &rx_dir, &rx_addr, tmp_buf, &rx_len) < 0) {
                fprintf(stderr, "[VCS Bridge] DMA read rc%d: recv_dma_data failed\n", rc);
                return -1;
            }
            dma_cpl_t cpl;
            if (tr->recv_dma_cpl(tr, &cpl) < 0) return -1;
            if (cpl.tag != tag || cpl.status != 0) {
                fprintf(stderr, "[VCS Bridge] DMA read rc%d: cpl tag=%u status=%u (expected tag=%u)\n",
                        rc, cpl.tag, cpl.status, tag);
                return -1;
            }
            int words = (len + 3) / 4;
            for (int w = 0; w < words && w < 16; w++)
                memcpy(&data[w], tmp_buf + w * 4, 4);
            return 0;
        }
    }
    fprintf(stderr, "[VCS Bridge] DMA read rc%d: timeout\n", rc);
    return -1;
}

/* DPI-C: Per-RC synchronous DMA write — DUT (requester) writes Guest memory
 * through RC slot `rc`. Mirrors the TCP branch of bridge_vcs_dma_write_sync,
 * scoped to g_rc[rc].transport. send_dma_req MUST precede send_dma_data (see
 * bridge_vcs_dma_write_sync comment). Blocks until SYNC_MSG_DMA_CPL. */
int bridge_vcs_dma_write_rc(int rc, unsigned long long host_addr,
                            const unsigned int *data, int len) {
    if (!rc_ok(rc) || len <= 0 || len > 64) return -1;  /* 64B = DPI data[16] 上限 */
    cosim_transport_t *tr = g_rc[rc].transport;
    if (!tr) return -1;

    static uint32_t next_tag = 4500;
    uint32_t tag = next_tag++;
    dma_req_t req = {
        .tag = tag,
        .direction = DMA_DIR_WRITE,
        .host_addr = host_addr,
        .len = (uint32_t)len,
        .dma_offset = 0,
        .timestamp = 0,
    };

    if (tr->send_dma_req(tr, &req) < 0) {
        fprintf(stderr, "[VCS Bridge] DMA write rc%d: send_dma_req failed\n", rc);
        return -1;
    }
    if (tr->send_dma_data(tr, tag, DMA_DIR_WRITE, host_addr,
                          (const uint8_t *)data, (uint32_t)len) < 0) {
        fprintf(stderr, "[VCS Bridge] DMA write rc%d: send_dma_data failed\n", rc);
        return -1;
    }

    for (int i = 0; i < 1000; i++) {
        sync_msg_t msg;
        if (tr->recv_sync(tr, &msg) < 0) {
            fprintf(stderr, "[VCS Bridge] DMA write rc%d: recv_sync error\n", rc);
            return -1;
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_TLP_READY) {
            tlp_entry_t cached_tlp;
            if (tr->recv_tlp(tr, &cached_tlp) == 0)
                tlp_cache_push_ctx(&g_rc[rc], &cached_tlp);
            continue;
        }
        if (msg.type == SYNC_MSG_DMA_CPL) {
            dma_cpl_t cpl;
            if (tr->recv_dma_cpl(tr, &cpl) < 0) return -1;
            if (cpl.tag == tag && cpl.status == 0)
                return 0;
            fprintf(stderr, "[VCS Bridge] DMA write rc%d: cpl tag=%u status=%u (expected tag=%u)\n",
                    rc, cpl.tag, cpl.status, tag);
            return -1;
        }
    }
    fprintf(stderr, "[VCS Bridge] DMA write rc%d: timeout\n", rc);
    return -1;
}

/* DPI-C: VCS raises MSI interrupt */
int bridge_vcs_raise_msi(int vector) {
    msi_event_t ev = { .requester_id = 0, .vector = (uint16_t)vector, .timestamp = 0 };

    /* ---- TCP transport path ---- */
    if (g_transport) {
        return g_transport->send_msi(g_transport, &ev);
    }

    /* ---- SHM path (original) ---- */
    if (ring_buf_enqueue(&g_shm.msi_ring, &ev) < 0) {
        fprintf(stderr, "[VCS Bridge] MSI queue full (vec=%d)\n", vector);
        return -1;
    }
    return 0;
}

/* DPI-C: Precise mode — wait for QEMU's clock step request
 * Returns: 0=normal clock step (cycles_out set), other=msg type for dispatch */
int bridge_vcs_wait_clock_step(int *cycles_out) {
    /* TCP transport: precise clock mode not supported */
    if (g_transport) {
        *cycles_out = 0;
        return -1;
    }

    sync_msg_t msg;
    int ret = sock_sync_recv(g_sock_fd, &msg);
    if (ret < 0) return -1;
    if (msg.type == SYNC_MSG_CLOCK_STEP) {
        *cycles_out = (int)msg.payload;
        return 0;
    }
    *cycles_out = 0;
    return (int)msg.type;
}

/* DPI-C: Precise mode — ack N cycles advanced */
int bridge_vcs_clock_ack(int cycles) {
    /* TCP transport: precise clock mode not supported */
    if (g_transport) return -1;

    sync_msg_t msg = { .type = SYNC_MSG_CLOCK_ACK, .payload = (uint32_t)cycles };
    return sock_sync_send(g_sock_fd, &msg);
}

/* ========== Internal helpers for arbitrary-length DMA ========== */

/* Read arbitrary bytes from guest physical memory via DMA.
 * Used internally by virtqueue processing — NOT a DPI-C function. */
int bridge_dma_read_bytes(uint64_t host_addr, uint8_t *buf, uint32_t len) {
    if (!g_initialized || len == 0 || !buf) return -1;

    static uint32_t rd_tag = 5000;

    /* ---- TCP transport path ---- */
    if (g_transport) {
        uint32_t tag = rd_tag++;
        uint8_t  buf_stale_discard[4096];  /* 吞掉 stale CPL payload */
        dma_req_t req = {
            .tag = tag,
            .direction = DMA_DIR_READ,
            .host_addr = host_addr,
            .len = len,
            .dma_offset = 0,  /* unused in TCP mode */
            .timestamp = 0,
        };

        if (g_transport->send_dma_req(g_transport, &req) < 0) {
            fprintf(stderr, "[VCS Bridge] dma_read_bytes: send_dma_req failed\n");
            return -1;
        }

        for (int i = 0; i < 1000; i++) {
            sync_msg_t msg;
            int ret = g_transport->recv_sync(g_transport, &msg);
            if (ret < 0) {
                fprintf(stderr, "[VCS Bridge] dma_read_bytes: recv_sync error\n");
                return -1;
            }
            if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
            if (msg.type == SYNC_MSG_TLP_READY) {
                /* 立即 recv_tlp 并缓存，避免 data channel 消息错位 */
                tlp_entry_t cached_tlp;
                if (g_transport->recv_tlp(g_transport, &cached_tlp) == 0) {
                    tlp_cache_push_ctx(&g_rc[0], &cached_tlp);
                } else {
                    fprintf(stderr, "[VCS Bridge] dma_wait: recv_tlp for cache failed\n");
                }
                continue;
            }
            if (msg.type == SYNC_MSG_DMA_CPL) {
                /* QEMU `bridge_complete_dma_with_data` 在 aux/data_fd 上的发送
                   顺序是 ① send_dma_data  ② send_dma_cpl  ③ ctrl send_sync。
                   所以 VCS 收到 SYNC_MSG_DMA_CPL 时 aux_fd 队头是 DMA_DATA 帧，
                   第二帧才是 DMA_CPL。必须按此顺序 recv，否则 tcp_recv_hdr
                   拿到的 msg_type 不匹配期望类型，协议错位。 */
                uint32_t rx_tag, rx_dir, rx_len = sizeof(buf_stale_discard);
                uint64_t rx_addr;
                if (g_transport->recv_dma_data(g_transport, &rx_tag, &rx_dir,
                                                &rx_addr,
                                                buf_stale_discard, &rx_len) < 0) {
                    fprintf(stderr, "[VCS Bridge] dma_read_bytes: recv_dma_data failed\n");
                    return -1;
                }

                dma_cpl_t cpl;
                if (g_transport->recv_dma_cpl(g_transport, &cpl) < 0) {
                    fprintf(stderr, "[VCS Bridge] dma_read_bytes: recv_dma_cpl failed\n");
                    return -1;
                }

                if (cpl.tag != tag || cpl.status != 0) {
                    /* Stale CPL：前一个 DMA read 因 1000-loop 超时 return -1 后
                       QEMU 稍后才回复的 orphan 包。data 已读走，直接丢。 */
                    fprintf(stderr, "[VCS Bridge] dma_read_bytes: drop stale cpl tag=%u expected=%u status=%d\n",
                            cpl.tag, tag, cpl.status);
                    continue;
                }

                /* 本次请求的 data：复制到 caller 的 buf（rx_len 受 len 限制） */
                uint32_t copy_len = (rx_len < len) ? rx_len : len;
                memcpy(buf, buf_stale_discard, copy_len);
                return 0;
            }
        }
        fprintf(stderr, "[VCS Bridge] dma_read_bytes: timeout (TCP)\n");
        return -1;
    }

    /* ---- SHM path (original) ---- */

    static uint32_t rd_bump = 0;
    uint32_t aligned = (len + 63) & ~63u;
    if (rd_bump + aligned > g_shm.dma_buf_size)
        rd_bump = 0;
    uint32_t offset = rd_bump;
    rd_bump += aligned;

    uint32_t tag = rd_tag++;
    dma_req_t req = {
        .tag = tag,
        .direction = DMA_DIR_READ,
        .host_addr = host_addr,
        .len = len,
        .dma_offset = offset,
        .timestamp = 0,
    };
    if (ring_buf_enqueue(&g_shm.dma_req_ring, &req) < 0) {
        fprintf(stderr, "[VCS Bridge] dma_read_bytes: req ring full\n");
        return -1;
    }

    for (int i = 0; i < 1000; i++) {
        sync_msg_t msg;
        int ret = sock_sync_recv_timed(g_sock_fd, &msg, 5000);
        if (ret < 0) {
            fprintf(stderr, "[VCS Bridge] dma_read_bytes: socket error\n");
            return -1;
        }
        if (ret == 1) {
            fprintf(stderr, "[VCS Bridge] dma_read_bytes: DMA wait timeout (iter=%d tag=%u)\n", i, tag);
            continue;
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_DMA_CPL) {
            dma_cpl_t cpl;
            if (ring_buf_dequeue(&g_shm.dma_cpl_ring, &cpl) == 0) {
                if (cpl.tag == tag && cpl.status == 0) {
                    memcpy(buf, (uint8_t *)g_shm.dma_buf + offset, len);
                    return 0;
                }
                fprintf(stderr, "[VCS Bridge] dma_read_bytes: tag mismatch %u vs %u\n",
                        cpl.tag, tag);
                return -1;
            }
        }
        /* Track consumed TLP_READY so poll_tlp can recover them */
        if (msg.type == SYNC_MSG_TLP_READY) {
            g_pending_tlp_ready++;
        }
    }
    fprintf(stderr, "[VCS Bridge] dma_read_bytes: timeout after retries\n");
    return -1;
}

/* Write arbitrary bytes to guest physical memory via DMA. */
int bridge_dma_write_bytes(uint64_t host_addr, const uint8_t *buf, uint32_t len) {
    if (!g_initialized || len == 0 || !buf) return -1;

    static uint32_t wr_tag = 6000;

    /* ---- TCP transport path ---- */
    if (g_transport) {
        uint32_t tag = wr_tag++;

        /* 先发 DMA_REQ 再发 DMA_DATA。
         * irq_poller 用 MSG_PEEK 按类型匹配，DMA_DATA 不是 DMA_REQ 类型，
         * 如果 DMA_DATA 在前会堵住 aux channel。
         * QEMU cosim_dma_cb 收到 DMA_REQ(WRITE) 后再 recv_dma_data。 */
        dma_req_t req = {
            .tag = tag,
            .direction = DMA_DIR_WRITE,
            .host_addr = host_addr,
            .len = len,
            .dma_offset = 0,
            .timestamp = 0,
        };

        if (g_transport->send_dma_req(g_transport, &req) < 0) {
            fprintf(stderr, "[VCS Bridge] dma_write_bytes: send_dma_req failed\n");
            return -1;
        }

        if (g_transport->send_dma_data(g_transport, tag, DMA_DIR_WRITE,
                                        host_addr, buf, len) < 0) {
            fprintf(stderr, "[VCS Bridge] dma_write_bytes: send_dma_data failed\n");
            return -1;
        }

        for (int i = 0; i < 1000; i++) {
            sync_msg_t msg;
            int ret = g_transport->recv_sync(g_transport, &msg);
            if (ret < 0) {
                fprintf(stderr, "[VCS Bridge] dma_write_bytes: recv_sync error\n");
                return -1;
            }
            if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
            if (msg.type == SYNC_MSG_TLP_READY) {
                /* 立即 recv_tlp 并缓存，避免 data channel 消息错位 */
                tlp_entry_t cached_tlp;
                if (g_transport->recv_tlp(g_transport, &cached_tlp) == 0) {
                    tlp_cache_push_ctx(&g_rc[0], &cached_tlp);
                } else {
                    fprintf(stderr, "[VCS Bridge] dma_wait: recv_tlp for cache failed\n");
                }
                continue;
            }
            if (msg.type == SYNC_MSG_DMA_CPL) {
                dma_cpl_t cpl;
                if (g_transport->recv_dma_cpl(g_transport, &cpl) < 0) {
                    fprintf(stderr, "[VCS Bridge] dma_write_bytes: recv_dma_cpl failed\n");
                    return -1;
                }
                if (cpl.tag == tag && cpl.status == 0)
                    return 0;
                fprintf(stderr, "[VCS Bridge] dma_write_bytes: tag mismatch %u vs %u\n",
                        cpl.tag, tag);
                return -1;
            }
        }
        fprintf(stderr, "[VCS Bridge] dma_write_bytes: timeout (TCP)\n");
        return -1;
    }

    /* ---- SHM path (original) ---- */

    static uint32_t wr_bump = 0;
    uint32_t aligned = (len + 63) & ~63u;
    if (wr_bump + aligned > g_shm.dma_buf_size)
        wr_bump = 0;
    uint32_t offset = wr_bump;
    wr_bump += aligned;

    memcpy((uint8_t *)g_shm.dma_buf + offset, buf, len);

    uint32_t tag = wr_tag++;
    dma_req_t req = {
        .tag = tag,
        .direction = DMA_DIR_WRITE,
        .host_addr = host_addr,
        .len = len,
        .dma_offset = offset,
        .timestamp = 0,
    };
    if (ring_buf_enqueue(&g_shm.dma_req_ring, &req) < 0) {
        fprintf(stderr, "[VCS Bridge] dma_write_bytes: req ring full\n");
        return -1;
    }

    for (int i = 0; i < 1000; i++) {
        sync_msg_t msg;
        int ret = sock_sync_recv_timed(g_sock_fd, &msg, 5000);
        if (ret < 0) {
            fprintf(stderr, "[VCS Bridge] dma_write_bytes: socket error\n");
            return -1;
        }
        if (ret == 1) {
            fprintf(stderr, "[VCS Bridge] dma_write_bytes: DMA wait timeout (iter=%d tag=%u)\n", i, tag);
            continue;
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_DMA_CPL) {
            dma_cpl_t cpl;
            if (ring_buf_dequeue(&g_shm.dma_cpl_ring, &cpl) == 0) {
                if (cpl.tag == tag && cpl.status == 0)
                    return 0;
                fprintf(stderr, "[VCS Bridge] dma_write_bytes: tag mismatch\n");
                return -1;
            }
        }
        /* Track consumed TLP_READY so poll_tlp can recover them */
        if (msg.type == SYNC_MSG_TLP_READY) {
            g_pending_tlp_ready++;
        }
    }
    fprintf(stderr, "[VCS Bridge] dma_write_bytes: timeout\n");
    return -1;
}

/* ========== Array-free DPI wrappers for VCS package-scope calls ========== */

/* Static buffers for poll/send — avoids DPI-C array parameter issues
 * when called from package scope in VCS Q-2020.  Per-RC: indexed [COSIM_MAX_RCS].
 * Legacy single-RC entry points use slot [0]; multi-RC _rc(int rc) use slot rc. */
static unsigned int g_poll_data_buf[COSIM_MAX_RCS][16];
static unsigned int g_send_cpl_buf[COSIM_MAX_RCS][16];

/* Fully scalar DPI: poll TLP, store ALL results in per-RC static vars.
 * Return: 0=TLP available, 1=empty, -1=error/shutdown */
static unsigned char      g_poll_tlp_type[COSIM_MAX_RCS];
static unsigned long long g_poll_addr[COSIM_MAX_RCS];
static int                g_poll_len[COSIM_MAX_RCS];
static int                g_poll_tag[COSIM_MAX_RCS];

static int rc_ok(int rc) { return (rc >= 0 && rc < COSIM_MAX_RCS); }

/* ---- Per-RC scalar DPI (multi-RC: cosim_rc_driver passes its rc index) ---- */
int bridge_vcs_poll_tlp_scalar_rc(int rc) {
    if (!rc_ok(rc)) return -1;
    return poll_tlp_ctx(&g_rc[rc], &g_poll_tlp_type[rc], &g_poll_addr[rc],
                        g_poll_data_buf[rc], &g_poll_len[rc], &g_poll_tag[rc]);
}
int bridge_vcs_get_poll_type_rc(int rc)      { return rc_ok(rc) ? (int)g_poll_tlp_type[rc] : 0; }
int bridge_vcs_is_realized_rc(int rc)        { return rc_ok(rc) ? g_rc[rc].realized : 0; }
long long bridge_vcs_get_poll_addr_rc(int rc){ return rc_ok(rc) ? (long long)g_poll_addr[rc] : 0; }
int bridge_vcs_get_poll_len_rc(int rc)       { return rc_ok(rc) ? g_poll_len[rc] : 0; }
int bridge_vcs_get_poll_tag_rc(int rc)       { return rc_ok(rc) ? g_poll_tag[rc] : 0; }
unsigned int bridge_vcs_get_poll_data_rc(int rc, int index) {
    if (!rc_ok(rc) || index < 0 || index >= 16) return 0;
    return g_poll_data_buf[rc][index];
}
unsigned char bridge_vcs_get_poll_first_be_rc(int rc) { return rc_ok(rc) ? g_rc[rc].last_entry.first_be : 0; }
unsigned char bridge_vcs_get_poll_last_be_rc(int rc)  { return rc_ok(rc) ? g_rc[rc].last_entry.last_be  : 0; }
int bridge_vcs_get_tlp_target_bdf_rc(int rc)   { return rc_ok(rc) ? (int)g_rc[rc].last_entry.target_bdf   : 0; }
int bridge_vcs_get_tlp_requester_id_rc(int rc) { return rc_ok(rc) ? (int)g_rc[rc].last_entry.requester_id : 0; }
int bridge_vcs_poll_vf_event_rc(int rc, int *event_type, int *pf_index, int *num_vfs) {
    if (!rc_ok(rc) || !g_rc[rc].vf_event_pending) return 0;
    *event_type = g_rc[rc].vf_event.event_type;
    *pf_index   = g_rc[rc].vf_event.pf_index;
    *num_vfs    = g_rc[rc].vf_event.num_vfs;
    g_rc[rc].vf_event_pending = 0;
    return 1;
}
void bridge_vcs_set_cpl_data_rc(int rc, int index, unsigned int value) {
    if (rc_ok(rc) && index >= 0 && index < 16)
        g_send_cpl_buf[rc][index] = value;
}
int bridge_vcs_send_cpl_scalar_rc(int rc, int tag, int len) {
    if (!rc_ok(rc)) return -1;
    return send_completion_ctx(&g_rc[rc], tag, g_send_cpl_buf[rc], len);
}

/* ---- Legacy single-RC scalar DPI (= slot 0, byte-equivalent to before) ---- */
int bridge_vcs_poll_tlp_scalar(void)     { return bridge_vcs_poll_tlp_scalar_rc(0); }
int bridge_vcs_get_poll_type(void)       { return bridge_vcs_get_poll_type_rc(0); }
long long bridge_vcs_get_poll_addr(void) { return bridge_vcs_get_poll_addr_rc(0); }
int bridge_vcs_get_poll_len(void)        { return bridge_vcs_get_poll_len_rc(0); }
int bridge_vcs_get_poll_tag(void)        { return bridge_vcs_get_poll_tag_rc(0); }
unsigned int bridge_vcs_get_poll_data(int index) { return bridge_vcs_get_poll_data_rc(0, index); }
unsigned char bridge_vcs_get_poll_first_be(void) { return bridge_vcs_get_poll_first_be_rc(0); }
unsigned char bridge_vcs_get_poll_last_be(void)  { return bridge_vcs_get_poll_last_be_rc(0); }

/* BAR base address synchronization (bypass mode: config_proxy → EP stub).
 * Per-RC so two RCs' BAR programming don't clobber each other. */
static uint64_t g_bar_base[COSIM_MAX_RCS][6] = {{0}};

void bridge_vcs_set_bar_base_rc(int rc, int idx, unsigned long long base) {
    if (rc_ok(rc) && idx >= 0 && idx < 6) g_bar_base[rc][idx] = base;
}
unsigned long long bridge_vcs_get_bar_base_rc(int rc, int idx) {
    if (rc_ok(rc) && idx >= 0 && idx < 6) return g_bar_base[rc][idx];
    return 0;
}
void bridge_vcs_set_bar_base(int idx, unsigned long long base) { bridge_vcs_set_bar_base_rc(0, idx, base); }
unsigned long long bridge_vcs_get_bar_base(int idx) { return bridge_vcs_get_bar_base_rc(0, idx); }

/* Per-BDF BAR base storage for multi-function mode.
 * Indexed by [bdf_hash][bar_idx].  Simple hash: bdf & 0x1FF (max 512 functions). */
#define BDF_BAR_HASH_SIZE 512
static uint64_t g_bdf_bar_base[BDF_BAR_HASH_SIZE][6];

void bridge_vcs_set_bar_base_bdf(int bdf, int bar_idx, unsigned long long bar_addr) {
    int h = bdf & (BDF_BAR_HASH_SIZE - 1);
    if (bar_idx >= 0 && bar_idx < 6) {
        g_bdf_bar_base[h][bar_idx] = bar_addr;
        /* Also update legacy g_bar_base for BAR0 of BDF with func==0 (RC0 slot) */
        if ((bdf & 0x7) == 0)
            g_bar_base[0][bar_idx] = bar_addr;
    }
}

/* Set one word in the completion data buffer (legacy = slot 0) */
void bridge_vcs_set_cpl_data(int index, unsigned int value) {
    bridge_vcs_set_cpl_data_rc(0, index, value);
}

/* Send completion using pre-set buffer — pure scalar DPI (legacy = slot 0) */
int bridge_vcs_send_cpl_scalar(int tag, int len) {
    return bridge_vcs_send_cpl_scalar_rc(0, tag, len);
}

/* DPI-C: 关闭连接 */
void bridge_vcs_cleanup(void) {
    if (g_initialized) {
        sock_sync_close(g_sock_fd);
        cosim_shm_close(&g_shm);
        g_initialized = 0;
    }
}

/* ========== Transport-aware API (新增) ========== */

/* Per-RC transport init. Each RC gets its own g_rc[rc].transport, so two RCs
 * (distinct port_base/instance_id) coexist in one simv. SHM mode is single-RC
 * (rc must be 0) — it uses the shared g_shm/g_sock_fd globals. */
int bridge_vcs_init_ex_rc(int rc, const char *transport_type,
                           const char *shm_name, const char *sock_path,
                           const char *remote_host, int port_base, int instance_id) {
    if (!rc_ok(rc)) return -1;

    if (!transport_type || strcmp(transport_type, "shm") == 0) {
        if (rc != 0) {
            fprintf(stderr, "[VCS Bridge] SHM transport is single-RC only (rc=%d rejected)\n", rc);
            return -1;
        }
        return bridge_vcs_init(shm_name, sock_path);   /* legacy SHM path */
    }

    if (g_rc[rc].transport) return 0;   /* already initialized this RC */

    transport_cfg_t cfg = {
        .transport   = transport_type,
        .shm_name    = shm_name,
        .sock_path   = sock_path,
        .remote_host = remote_host,
        .port_base   = port_base,
        .instance_id = instance_id,
        .is_server   = 0,
    };

    g_rc[rc].transport = transport_create(&cfg);
    if (!g_rc[rc].transport) {
        fprintf(stderr, "[VCS Bridge] RC%d: failed to create %s transport\n", rc, transport_type);
        return -1;
    }

    g_rc[rc].transport->set_ready(g_rc[rc].transport);
    if (rc + 1 > g_num_rc) g_num_rc = rc + 1;
    fprintf(stderr, "[VCS Bridge] RC%d initialized: transport=%s remote=%s port=%d inst=%d\n",
            rc, transport_type, remote_host ? remote_host : "(null)", port_base, instance_id);
    return 0;
}

int bridge_vcs_init_ex(const char *transport_type,
                        const char *shm_name, const char *sock_path,
                        const char *remote_host, int port_base, int instance_id) {
    if (g_initialized || g_rc[0].transport) return 0;
    return bridge_vcs_init_ex_rc(0, transport_type, shm_name, sock_path,
                                 remote_host, port_base, instance_id);
}

void bridge_vcs_cleanup_ex_rc(int rc) {
    if (!rc_ok(rc)) return;
    if (g_rc[rc].transport) {
        g_rc[rc].transport->close(g_rc[rc].transport);
        g_rc[rc].transport = NULL;
    } else if (rc == 0) {
        bridge_vcs_cleanup();
    }
}

void bridge_vcs_cleanup_ex(void) {
    bridge_vcs_cleanup_ex_rc(0);
}
