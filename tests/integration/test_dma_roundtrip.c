#include <stdio.h>
#include <assert.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include "bridge_qemu.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "irq_poller.h"
#include "dma_manager.h"
#include "cosim_types.h"

static const char *SHM_NAME = "/cosim_test_dma_rt";
static const char *SOCK_PATH = "/tmp/cosim_test_dma_rt.sock";

static volatile int dma_received = 0;
static dma_req_t received_req;
static uint8_t received_data[64];

static void dma_callback(const dma_req_t *req, void *user) {
    cosim_shm_t *shm = user;
    received_req = *req;
    uint8_t *src = (uint8_t *)shm->dma_buf + req->dma_offset;
    memcpy(received_data, src, req->len);
    __atomic_store_n(&dma_received, 1, __ATOMIC_SEQ_CST);
}

static void vcs_stub(void) {
    usleep(100000);
    cosim_shm_t shm;
    assert(cosim_shm_open(&shm, SHM_NAME) == 0);
    int sock = sock_sync_connect(SOCK_PATH);
    assert(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    dma_mgr_t mgr;
    dma_mgr_init(&mgr, shm.dma_buf, shm.dma_buf_size);
    uint32_t off = dma_mgr_alloc(&mgr, 64);
    assert(off != DMA_MGR_INVALID);

    uint8_t *dma_buf = (uint8_t *)shm.dma_buf + off;
    for (int i = 0; i < 64; i++) dma_buf[i] = (uint8_t)(0x80 + i);

    dma_req_t req = {
        .tag = 7,
        .direction = DMA_DIR_WRITE,
        .host_addr = 0x1000,
        .len = 64,
        .dma_offset = off,
        .timestamp = 0,
    };
    assert(ring_buf_enqueue(&shm.dma_req_ring, &req) == 0);

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test_dma_write_from_device(void) {
    dma_received = 0;
    pid_t pid = fork();
    if (pid == 0) { vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(SHM_NAME, SOCK_PATH);
    assert(ctx);
    assert(bridge_connect(ctx) == 0);

    irq_poller_t *poller = irq_poller_start(&ctx->shm, dma_callback, NULL, &ctx->shm);
    assert(poller);

    for (int i = 0; i < 50 && !__atomic_load_n(&dma_received, __ATOMIC_SEQ_CST); i++)
        usleep(50000);
    assert(__atomic_load_n(&dma_received, __ATOMIC_SEQ_CST));
    assert(received_req.tag == 7);
    assert(received_req.direction == DMA_DIR_WRITE);
    assert(received_req.host_addr == 0x1000);
    assert(received_req.len == 64);

    for (int i = 0; i < 64; i++) {
        assert(received_data[i] == (uint8_t)(0x80 + i));
    }

    irq_poller_stop(poller);
    bridge_destroy(ctx);

    int status;
    waitpid(pid, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    printf("  PASS: test_dma_write_from_device\n");
}

int main(void) {
    printf("=== dma_roundtrip tests ===\n");
    test_dma_write_from_device();
    printf("=== ALL PASSED ===\n");
    return 0;
}
