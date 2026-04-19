/* cosim-platform/bridge/vcs/bridge_vcs.c
 * VCS 侧 DPI-C 函数实现，被 SystemVerilog testbench 调用
 */
#include "shm_layout.h"
#include "cosim_types.h"
#include "../qemu/sock_sync.h"
#include <string.h>
#include <stdio.h>

/* 全局状态（VCS 进程内单实例） */
static cosim_shm_t g_shm;
static int g_sock_fd = -1;
static int g_initialized = 0;

/* Counter for TLP_READY messages consumed during DMA waits. */
static int g_pending_tlp_ready = 0;

/* Debug heartbeat counter — prints status every N poll iterations */
static int g_poll_count = 0;

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

/* DPI-C: 轮询请求队列，获取一个 TLP
 * 返回: 0=成功取到, 1=队列空（无新事务）, -1=错误
 */
int bridge_vcs_poll_tlp(unsigned char *tlp_type, unsigned long long *addr,
                         unsigned int *data, int *len, int *tag) {
    g_poll_count++;
    if ((g_poll_count % 5000) == 0) {
        fprintf(stderr, "[VCS Bridge] heartbeat: poll_count=%d pending_tlp=%d\n",
                g_poll_count, g_pending_tlp_ready);
    }

    /* If TLP_READY messages were consumed during DMA waits, dequeue
     * directly from the SHM ring without waiting for socket notification. */
    if (g_pending_tlp_ready > 0) {
        tlp_entry_t entry;
        int dret = ring_buf_dequeue(&g_shm.req_ring, &entry);
        if (dret == 0) {
            g_pending_tlp_ready--;
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

    /* Check Socket with 1ms timeout (non-blocking for RX polling) */
    sync_msg_t msg;
    int ret = sock_sync_recv_timed(g_sock_fd, &msg, 1);
    if (ret < 0) return -1;
    if (ret == 1) return 1;  /* timeout — no TLP, allow RX poll */
    if (msg.type != SYNC_MSG_TLP_READY) {
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        return 1; /* 非 TLP 消息，返回空 */
    }

    /* 从请求队列出队 */
    tlp_entry_t entry;
    ret = ring_buf_dequeue(&g_shm.req_ring, &entry);
    if (ret < 0) return 1;

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

/* DPI-C: 发送 Completion */
int bridge_vcs_send_completion(int tag, const unsigned int *data, int len) {
    cpl_entry_t cpl;
    memset(&cpl, 0, sizeof(cpl));
    cpl.type = TLP_CPL;
    cpl.tag = (unsigned char)tag;
    cpl.status = 0;
    cpl.len = len;

    int bytes = (len < COSIM_TLP_DATA_SIZE) ? len : COSIM_TLP_DATA_SIZE;
    int words = (bytes + 3) / 4;
    for (int i = 0; i < words; i++) {
        memcpy(&cpl.data[i * 4], &data[i], 4);
    }

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
    msi_event_t ev = { .vector = (uint32_t)vector, .timestamp = 0 };
    if (ring_buf_enqueue(&g_shm.msi_ring, &ev) < 0) {
        fprintf(stderr, "[VCS Bridge] MSI queue full (vec=%d)\n", vector);
        return -1;
    }
    return 0;
}

/* DPI-C: Precise mode — wait for QEMU's clock step request
 * Returns: 0=normal clock step (cycles_out set), other=msg type for dispatch */
int bridge_vcs_wait_clock_step(int *cycles_out) {
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
    sync_msg_t msg = { .type = SYNC_MSG_CLOCK_ACK, .payload = (uint32_t)cycles };
    return sock_sync_send(g_sock_fd, &msg);
}

/* ========== Internal helpers for arbitrary-length DMA ========== */

/* Read arbitrary bytes from guest physical memory via DMA.
 * Used internally by virtqueue processing — NOT a DPI-C function. */
int bridge_dma_read_bytes(uint64_t host_addr, uint8_t *buf, uint32_t len) {
    if (!g_initialized || len == 0 || !buf) return -1;

    static uint32_t rd_tag = 5000;
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

/* DPI-C: 关闭连接 */
void bridge_vcs_cleanup(void) {
    if (g_initialized) {
        sock_sync_close(g_sock_fd);
        cosim_shm_close(&g_shm);
        g_initialized = 0;
    }
}
