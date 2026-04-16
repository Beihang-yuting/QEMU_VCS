#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <sys/wait.h>
#include "bridge_qemu.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "irq_poller.h"
#include "cosim_types.h"

static const char *SHM_NAME = "/cosim_test_msi_rt";
static const char *SOCK_PATH = "/tmp/cosim_test_msi_rt.sock";

static volatile int msi_count = 0;
static volatile uint32_t last_vector = 0xFFFF;

static void msi_callback(uint32_t vector, void *user) {
    (void)user;
    last_vector = vector;
    __atomic_fetch_add(&msi_count, 1, __ATOMIC_SEQ_CST);
}

static void vcs_stub(void) {
    usleep(100000);
    cosim_shm_t shm;
    assert(cosim_shm_open(&shm, SHM_NAME) == 0);
    int sock = sock_sync_connect(SOCK_PATH);
    assert(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    for (uint32_t v = 0; v < 3; v++) {
        msi_event_t ev = { .vector = v, .timestamp = 1000 + v };
        assert(ring_buf_enqueue(&shm.msi_ring, &ev) == 0);
        usleep(50000);  /* give poller time to process */
    }

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test_msi_delivery(void) {
    msi_count = 0;
    pid_t pid = fork();
    if (pid == 0) { vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(SHM_NAME, SOCK_PATH);
    assert(ctx);
    assert(bridge_connect(ctx) == 0);

    irq_poller_t *poller = irq_poller_start(&ctx->shm, NULL, msi_callback, NULL);
    assert(poller);

    for (int i = 0; i < 50 && __atomic_load_n(&msi_count, __ATOMIC_SEQ_CST) < 3; i++)
        usleep(50000);
    assert(__atomic_load_n(&msi_count, __ATOMIC_SEQ_CST) == 3);
    assert(last_vector == 2);

    irq_poller_stop(poller);
    bridge_destroy(ctx);

    int status;
    waitpid(pid, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    printf("  PASS: test_msi_delivery\n");
}

int main(void) {
    printf("=== msi_roundtrip tests ===\n");
    test_msi_delivery();
    printf("=== ALL PASSED ===\n");
    return 0;
}
