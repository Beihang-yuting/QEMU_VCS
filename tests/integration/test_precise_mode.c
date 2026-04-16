#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <sys/wait.h>
#include "bridge_qemu.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "cosim_types.h"

static const char *SHM_NAME = "/cosim_test_precise";
static const char *SOCK_PATH = "/tmp/cosim_test_precise.sock";

static void vcs_stub(void) {
    usleep(100000);
    cosim_shm_t shm;
    assert(cosim_shm_open(&shm, SHM_NAME) == 0);
    int sock = sock_sync_connect(SOCK_PATH);
    assert(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    /* Wait for mode switch */
    sync_msg_t msg;
    int ret = sock_sync_recv(sock, &msg);
    assert(ret == 0);
    assert(msg.type == SYNC_MSG_MODE_SWITCH);
    assert(msg.payload == COSIM_MODE_PRECISE);
    shm.ctrl->mode = COSIM_MODE_PRECISE;
    atomic_store(&shm.ctrl->mode_switch_pending, 0);

    /* Handle 3 clock steps */
    for (int i = 0; i < 3; i++) {
        ret = sock_sync_recv(sock, &msg);
        assert(ret == 0);
        assert(msg.type == SYNC_MSG_CLOCK_STEP);
        assert(msg.payload == 100);

        atomic_fetch_add(&shm.ctrl->sim_time_ns, 1000);

        sync_msg_t ack = { .type = SYNC_MSG_CLOCK_ACK, .payload = 100 };
        sock_sync_send(sock, &ack);
    }

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test_precise_clock_sync(void) {
    pid_t pid = fork();
    if (pid == 0) { vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(SHM_NAME, SOCK_PATH);
    assert(ctx);
    assert(bridge_connect(ctx) == 0);
    while (!atomic_load(&ctx->shm.ctrl->vcs_ready)) usleep(10000);

    /* Request mode switch */
    assert(bridge_request_mode_switch(ctx, COSIM_MODE_PRECISE) == 0);
    /* Wait for VCS to ack by setting mode */
    for (int i = 0; i < 50 && ctx->shm.ctrl->mode != COSIM_MODE_PRECISE; i++)
        usleep(50000);
    assert(ctx->shm.ctrl->mode == COSIM_MODE_PRECISE);

    /* Advance clock 3 times */
    uint64_t start_time = atomic_load(&ctx->shm.ctrl->sim_time_ns);
    for (int i = 0; i < 3; i++) {
        assert(bridge_advance_clock(ctx, 100) == 0);
    }
    uint64_t end_time = atomic_load(&ctx->shm.ctrl->sim_time_ns);
    assert(end_time - start_time == 3 * 1000);

    bridge_destroy(ctx);

    int status;
    waitpid(pid, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    printf("  PASS: test_precise_clock_sync\n");
}

int main(void) {
    printf("=== precise_mode tests ===\n");
    test_precise_clock_sync();
    printf("=== ALL PASSED ===\n");
    return 0;
}
