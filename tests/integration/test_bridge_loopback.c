#include <stdio.h>
#include <assert.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include "bridge_qemu.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "cosim_types.h"

static const char *SHM_NAME = "/cosim_test_bridge";
static const char *SOCK_PATH = "/tmp/cosim_test_bridge.sock";

static void vcs_stub(void) {
    usleep(100000);
    cosim_shm_t shm;
    int ret = cosim_shm_open(&shm, SHM_NAME);
    assert(ret == 0);
    int sock = sock_sync_connect(SOCK_PATH);
    assert(sock >= 0);

    atomic_store(&shm.ctrl->vcs_ready, 1);

    sync_msg_t msg;
    ret = sock_sync_recv(sock, &msg);
    assert(ret == 0);
    assert(msg.type == SYNC_MSG_TLP_READY);

    tlp_entry_t tlp;
    ret = ring_buf_dequeue(&shm.req_ring, &tlp);
    assert(ret == 0);
    assert(tlp.type == TLP_MRD);
    assert(tlp.addr == 0xFE000020);

    cpl_entry_t cpl;
    memset(&cpl, 0, sizeof(cpl));
    cpl.type = TLP_CPL;
    cpl.tag = tlp.tag;
    cpl.status = 0;
    cpl.len = 4;
    cpl.data[0] = 0xBE;
    cpl.data[1] = 0xBA;
    cpl.data[2] = 0xFE;
    cpl.data[3] = 0xCA;

    ret = ring_buf_enqueue(&shm.cpl_ring, &cpl);
    assert(ret == 0);

    sync_msg_t reply = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
    sock_sync_send(sock, &reply);

    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test_mmio_read_roundtrip(void) {
    pid_t pid = fork();
    if (pid == 0) {
        vcs_stub();
        _exit(0);
    }

    bridge_ctx_t *ctx = bridge_init(SHM_NAME, SOCK_PATH);
    assert(ctx != NULL);

    int ret = bridge_connect(ctx);
    assert(ret == 0);

    while (!atomic_load(&ctx->shm.ctrl->vcs_ready)) {
        usleep(10000);
    }

    tlp_entry_t req;
    memset(&req, 0, sizeof(req));
    req.type = TLP_MRD;
    req.addr = 0xFE000020;
    req.len = 4;

    cpl_entry_t cpl;
    ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    assert(ret == 0);
    assert(cpl.status == 0);
    assert(cpl.tag == req.tag);

    uint32_t val = cpl.data[0] | (cpl.data[1] << 8) | (cpl.data[2] << 16) | (cpl.data[3] << 24);
    assert(val == 0xCAFEBABE);

    bridge_destroy(ctx);

    int status;
    waitpid(pid, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    printf("  PASS: test_mmio_read_roundtrip\n");
}

int main(void) {
    printf("=== bridge_loopback tests ===\n");
    test_mmio_read_roundtrip();
    printf("=== ALL PASSED ===\n");
    return 0;
}
