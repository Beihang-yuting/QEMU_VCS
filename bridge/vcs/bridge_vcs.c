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

/* 全局状态（VCS 进程内单实例） */
static cosim_shm_t g_shm;
static int g_sock_fd = -1;
static int g_initialized = 0;
static cosim_transport_t *g_transport = NULL;

/* P3: Topology state (populated by SV testbench via DPI-C before simulation) */
static topology_resp_t g_topology;
static int g_topology_ready = 0;

/* Counter for TLP_READY messages consumed during DMA waits (SHM mode only). */
static int g_pending_tlp_ready = 0;

/* Pending VF event from QEMU (set by poll_tlp when VF_EVENT sync arrives) */
static int g_vf_event_pending = 0;
static vf_event_t g_vf_event;

/* TLP cache: TCP 模式 DMA read 期间消费的 TLP_READY 会立即 recv_tlp 缓存在此，
 * poll_tlp 优先从缓存读取，避免 pending 计数与 data channel 错位。 */
#define TLP_CACHE_SIZE 1024
static tlp_entry_t g_tlp_cache[TLP_CACHE_SIZE];
static int g_tlp_cache_head = 0;
static int g_tlp_cache_tail = 0;

static int tlp_cache_push(const tlp_entry_t *e) {
    int next = (g_tlp_cache_head + 1) % TLP_CACHE_SIZE;
    if (next == g_tlp_cache_tail) {
        fprintf(stderr, "[VCS Bridge] TLP cache full! dropping TLP\n");
        return -1;
    }
    g_tlp_cache[g_tlp_cache_head] = *e;
    g_tlp_cache_head = next;
    return 0;
}

static int tlp_cache_pop(tlp_entry_t *e) {
    if (g_tlp_cache_head == g_tlp_cache_tail) return -1;
    *e = g_tlp_cache[g_tlp_cache_tail];
    g_tlp_cache_tail = (g_tlp_cache_tail + 1) % TLP_CACHE_SIZE;
    return 0;
}

static int tlp_cache_count(void) {
    return (g_tlp_cache_head - g_tlp_cache_tail + TLP_CACHE_SIZE) % TLP_CACHE_SIZE;
}

/* Debug heartbeat counter — prints status every N poll iterations */
static int g_poll_count = 0;

/* Cache of last dequeued TLP entry for bridge_vcs_poll_tlp_ext */
static tlp_entry_t g_last_entry;

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

/* Internal: Handle a QUERY_TOPOLOGY request from QEMU */
static int bridge_vcs_handle_topology_query(void) {
    if (!g_topology_ready) {
        fprintf(stderr, "[VCS Bridge] handle_topology_query: topology not ready\n");
        return -1;
    }

    if (g_transport) {
        /* TCP mode: send sync ack first, then topology payload.
         * Both go on ctrl_fd; QEMU recv_sync reads the sync header first,
         * then recv_topology reads the topology header+payload. */
        sync_msg_t resp = { .type = SYNC_MSG_TOPOLOGY_RESP, .payload = 0 };
        if (g_transport->send_sync(g_transport, &resp) < 0) {
            fprintf(stderr, "[VCS Bridge] handle_topology_query: send_sync failed\n");
            return -1;
        }
        if (g_transport->send_topology(g_transport, &g_topology) < 0) {
            fprintf(stderr, "[VCS Bridge] handle_topology_query: send_topology failed\n");
            return -1;
        }
        return 0;
    }

    /* SHM mode: write topology to ctrl region, then send sync ack */
    uint8_t *dst = (uint8_t *)g_shm.ctrl + sizeof(cosim_ctrl_t);
    memcpy(dst, &g_topology, sizeof(g_topology));
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
int bridge_vcs_poll_tlp(unsigned char *tlp_type, unsigned long long *addr,
                         unsigned int *data, int *len, int *tag) {
    g_poll_count++;

    /* ---- TCP transport path ----
     *
     * 分层策略解决 QEMU 实时 vs VCS 仿真时间不匹配：
     *   Phase 1: 从 TLP 缓存取（DMA 期间缓存的 TLP，零延迟）
     *   Phase 2: 非阻塞批量 drain ctrl_fd（读取所有已到达的 TLP_READY）
     *   Phase 3: 缓存非空则返回一个
     *   Phase 4: 带超时等待（适配跨机 TCP 延迟，避免丢失在途消息）
     */
    if (g_transport) {
        tlp_entry_t entry;
        sync_msg_t msg;
        int ret;

        /* Phase 1: TLP 缓存优先 */
        if (tlp_cache_pop(&entry) == 0)
            goto return_entry;

        /* Phase 2: 非阻塞批量 drain — 一次读完 ctrl_fd 中所有 TLP_READY */
        for (;;) {
            ret = g_transport->recv_sync_timed(g_transport, &msg, 0);
            if (ret < 0) return -1;
            if (ret == 1) break;  /* ctrl_fd 为空，drain 完成 */
            if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
            if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
                bridge_vcs_handle_topology_query();
                continue;
            }
            if (msg.type == SYNC_MSG_TLP_READY) {
                if (g_transport->recv_tlp(g_transport, &entry) == 0)
                    tlp_cache_push(&entry);
                continue;
            }
            if (msg.type == SYNC_MSG_VF_EVENT) {
                g_vf_event.event_type = (uint8_t)(msg.payload & 0xFF);
                g_vf_event.pf_index   = (uint8_t)((msg.payload >> 8) & 0xFF);
                g_vf_event.num_vfs    = (uint16_t)((msg.payload >> 16) & 0xFFFF);
                g_vf_event_pending = 1;
                continue;
            }
            /* 非 TLP_READY 消息在 poll 中不应出现，记录并跳过 */
            fprintf(stderr, "[VCS poll] unexpected msg.type=%d in drain, discarding\n", msg.type);
        }

        /* Phase 3: drain 后缓存可能有 TLP */
        if (tlp_cache_pop(&entry) == 0)
            goto return_entry;

        /* Phase 4: 自适应超时等待 — 跨机 TCP 传输延迟可达数毫秒。
         * 刚收到过 TLP 时用短超时（1ms）快速响应后续包；
         * 连续空 poll 后递增到较长超时（50ms）减少 CPU 空转；
         * 收到 TLP 后重置为短超时。 */
        {
            static int empty_streak = 0;
            int timeout_ms = (empty_streak < 5) ? 1 :
                             (empty_streak < 20) ? 5 : 50;
            ret = g_transport->recv_sync_timed(g_transport, &msg, timeout_ms);
            if (ret < 0) return -1;
            if (ret == 1) {
                empty_streak++;
                return 1;  /* 超时，无新 TLP */
            }
            empty_streak = 0;  /* 收到数据，重置 */
        }
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
            bridge_vcs_handle_topology_query();
            return 1;  /* no TLP this iteration, let SV loop re-enter */
        }
        if (msg.type == SYNC_MSG_VF_EVENT) {
            g_vf_event.event_type = (uint8_t)(msg.payload & 0xFF);
            g_vf_event.pf_index   = (uint8_t)((msg.payload >> 8) & 0xFF);
            g_vf_event.num_vfs    = (uint16_t)((msg.payload >> 16) & 0xFFFF);
            g_vf_event_pending = 1;
            return 1;
        }
        if (msg.type == SYNC_MSG_TLP_READY) {
            if (g_transport->recv_tlp(g_transport, &entry) < 0) return 1;
            goto return_entry;
        }
        fprintf(stderr, "[VCS poll] unexpected msg.type=%d after wait, discarding\n", msg.type);
        return 1;

    return_entry:
        g_last_entry = entry;
        *tlp_type = entry.type;
        *addr = entry.addr;
        *len = entry.len;
        *tag = entry.tag;
        int words = (entry.len + 3) / 4;
        for (int i = 0; i < words && i < 16; i++)
            memcpy(&data[i], &entry.data[i * 4], 4);
        return 0;
    }

    /* ---- SHM path (original) ---- */

    /* If TLP_READY messages were consumed during DMA waits, dequeue
     * directly from the SHM ring without waiting for socket notification. */
    if (g_pending_tlp_ready > 0) {
        tlp_entry_t entry;
        int dret = ring_buf_dequeue(&g_shm.req_ring, &entry);
        if (dret == 0) {
            g_pending_tlp_ready--;
            g_last_entry = entry;
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
        g_pending_tlp_ready = 0;
    }

    /* Check Socket with 0ms timeout (non-blocking) — VCS Q-2020 segfaults
     * when $finish fires during a blocking poll/select syscall on Linux 6.17.
     * SV-side #delay provides the pacing instead. */
    sync_msg_t msg;
    int ret = sock_sync_recv_timed(g_sock_fd, &msg, 0);
    if (ret < 0) return -1;
    if (ret == 1) return 1;  /* timeout — no TLP, allow RX poll */
    if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
        bridge_vcs_handle_topology_query();
        return 1;  /* handled, no TLP this iteration */
    }
    if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
    if (msg.type == SYNC_MSG_VF_EVENT) {
        g_vf_event.event_type = (uint8_t)(msg.payload & 0xFF);
        g_vf_event.pf_index   = (uint8_t)((msg.payload >> 8) & 0xFF);
        g_vf_event.num_vfs    = (uint16_t)((msg.payload >> 16) & 0xFFFF);
        g_vf_event_pending = 1;
        return 1; /* no TLP, but VF event is pending for SV to pick up */
    }
    if (msg.type != SYNC_MSG_TLP_READY) {
        return 1; /* 非 TLP 消息，返回空 */
    }

    /* 从请求队列出队 */
    tlp_entry_t entry;
    ret = ring_buf_dequeue(&g_shm.req_ring, &entry);
    if (ret < 0) return 1;

    g_last_entry = entry;
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

/* DPI-C: 发送 Completion */
int bridge_vcs_send_completion(int tag, const unsigned int *data, int len) {
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
    if (g_transport) {
        if (g_transport->send_cpl(g_transport, &cpl) < 0) {
            fprintf(stderr, "[VCS Bridge] send_cpl failed\n");
            return -1;
        }
        sync_msg_t msg = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        return g_transport->send_sync(g_transport, &msg);
    }

    /* ---- SHM path (original) ---- */
    int ret = ring_buf_enqueue(&g_shm.cpl_ring, &cpl);
    if (ret < 0) {
        fprintf(stderr, "[VCS Bridge] Completion queue full\n");
        return -1;
    }

    /* 通知 QEMU */
    sync_msg_t msg = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
    return sock_sync_send(g_sock_fd, &msg);
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
                    tlp_cache_push(&cached_tlp);
                } else {
                    fprintf(stderr, "[VCS Bridge] dma_wait: recv_tlp for cache failed\n");
                }
                continue;
            }
            if (msg.type == SYNC_MSG_DMA_CPL) {
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
                /* Receive data from QEMU via transport */
                uint32_t rx_tag, rx_dir, rx_len;
                uint64_t rx_addr;
                uint8_t tmp_buf[64];
                /* Use a stack buffer large enough for typical DPI calls (up to 16 words = 64 bytes) */
                rx_len = (uint32_t)len;
                if (g_transport->recv_dma_data(g_transport, &rx_tag, &rx_dir,
                                                &rx_addr, tmp_buf, &rx_len) < 0) {
                    fprintf(stderr, "[VCS Bridge] DMA read sync: recv_dma_data failed\n");
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

    static uint32_t next_tag = 3000;

    /* ---- TCP transport path ---- */
    if (g_transport) {
        uint32_t tag = next_tag++;

        /* Send data first so QEMU has it when processing the request */
        if (g_transport->send_dma_data(g_transport, tag, DMA_DIR_WRITE,
                                        host_addr, (const uint8_t *)data, (uint32_t)len) < 0) {
            fprintf(stderr, "[VCS Bridge] DMA write sync: send_dma_data failed\n");
            return -1;
        }

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
                    tlp_cache_push(&cached_tlp);
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
                    tlp_cache_push(&cached_tlp);
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
                    tlp_cache_push(&cached_tlp);
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
 * when called from package scope in VCS Q-2020. */
static unsigned int g_poll_data_buf[16];
static unsigned int g_send_cpl_buf[16];

/* Fully scalar DPI: poll TLP, store ALL results in static vars.
 * Return: 0=TLP available, 1=empty, -1=error/shutdown */
static unsigned char  g_poll_tlp_type;
static unsigned long long g_poll_addr;
static int            g_poll_len;
static int            g_poll_tag;

int bridge_vcs_poll_tlp_scalar(void) {
    return bridge_vcs_poll_tlp(&g_poll_tlp_type, &g_poll_addr,
                                g_poll_data_buf, &g_poll_len, &g_poll_tag);
}

/* Getters — no output parameters, just return values */
int bridge_vcs_get_poll_type(void)  { return (int)g_poll_tlp_type; }
long long bridge_vcs_get_poll_addr(void) { return (long long)g_poll_addr; }
int bridge_vcs_get_poll_len(void)   { return g_poll_len; }
int bridge_vcs_get_poll_tag(void)   { return g_poll_tag; }

/* Get one word from the last polled TLP data */
unsigned int bridge_vcs_get_poll_data(int index) {
    if (index < 0 || index >= 16) return 0;
    return g_poll_data_buf[index];
}

/* FirstBE / LastBE getters from last polled TLP */
unsigned char bridge_vcs_get_poll_first_be(void) { return g_last_entry.first_be; }
unsigned char bridge_vcs_get_poll_last_be(void)  { return g_last_entry.last_be; }

/* BAR base address synchronization (bypass mode: config_proxy → EP stub) */
static uint64_t g_bar_base[6] = {0};

void bridge_vcs_set_bar_base(int idx, unsigned long long base) {
    if (idx >= 0 && idx < 6) g_bar_base[idx] = base;
}

unsigned long long bridge_vcs_get_bar_base(int idx) {
    if (idx >= 0 && idx < 6) return g_bar_base[idx];
    return 0;
}

/* Per-BDF BAR base storage for multi-function mode.
 * Indexed by [bdf_hash][bar_idx].  Simple hash: bdf & 0x1FF (max 512 functions). */
#define BDF_BAR_HASH_SIZE 512
static uint64_t g_bdf_bar_base[BDF_BAR_HASH_SIZE][6];

void bridge_vcs_set_bar_base_bdf(int bdf, int bar_idx, unsigned long long bar_addr) {
    int h = bdf & (BDF_BAR_HASH_SIZE - 1);
    if (bar_idx >= 0 && bar_idx < 6) {
        g_bdf_bar_base[h][bar_idx] = bar_addr;
        /* Also update legacy g_bar_base for BAR0 of BDF with func==0 */
        if ((bdf & 0x7) == 0)
            g_bar_base[bar_idx] = bar_addr;
    }
}

/* Set one word in the completion data buffer */
void bridge_vcs_set_cpl_data(int index, unsigned int value) {
    if (index >= 0 && index < 16)
        g_send_cpl_buf[index] = value;
}

/* Send completion using pre-set buffer — pure scalar DPI */
int bridge_vcs_send_cpl_scalar(int tag, int len) {
    return bridge_vcs_send_completion(tag, g_send_cpl_buf, len);
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
