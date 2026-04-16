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
                         unsigned int *data, int *len) {
    /* 先检查 Socket 通知 */
    sync_msg_t msg;
    int ret = sock_sync_recv(g_sock_fd, &msg);
    if (ret < 0) return -1;
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

/* DPI-C: 关闭连接 */
void bridge_vcs_cleanup(void) {
    if (g_initialized) {
        sock_sync_close(g_sock_fd);
        cosim_shm_close(&g_shm);
        g_initialized = 0;
    }
}
