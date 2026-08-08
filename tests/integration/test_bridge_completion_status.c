#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bridge_qemu.h"
#include "cosim_transport.h"
#include "cosim_types.h"

int bridge_vcs_init_ex(const char *transport_type,
                       const char *shm_name, const char *sock_path,
                       const char *remote_host, int port_base, int instance_id);
void bridge_vcs_cleanup_ex(void);
int bridge_vcs_poll_tlp_scalar(void);
int bridge_vcs_get_poll_type(void);
int bridge_vcs_get_poll_tag(void);
int bridge_vcs_send_cpl_scalar_status_rc(int rc, int tag, int len, int status);
int bridge_vcs_send_cpl_scalar_rc(int rc, int tag, int len);
int bridge_vcs_send_cpl_scalar_status(int tag, int len, int status);
int bridge_vcs_send_cpl_scalar(int tag, int len);

#define CHECK_OR_GOTO(cond, label) do {                                      \
    if (!(cond)) {                                                            \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
        goto label;                                                           \
    }                                                                         \
} while (0)

static int vcs_stub(int port_base)
{
    int initialized = 0;
    int result = 1;

    alarm(10);
    CHECK_OR_GOTO(bridge_vcs_init_ex("tcp", NULL, NULL, "127.0.0.1",
                                     port_base, 0) == 0, out);
    initialized = 1;

    CHECK_OR_GOTO(bridge_vcs_send_cpl_scalar_status_rc(
                      0, 0, 0, 3) == -1, out);

    for (int transaction = 0; transaction < 3; transaction++) {
        int completed = 0;

        for (int attempt = 0; attempt < 500; attempt++) {
            int poll_rc = bridge_vcs_poll_tlp_scalar();
            if (poll_rc == 0) {
                int tag = bridge_vcs_get_poll_tag();

                CHECK_OR_GOTO(bridge_vcs_get_poll_type() == TLP_MRD, out);
                if (transaction == 0) {
                    CHECK_OR_GOTO(bridge_vcs_send_cpl_scalar_status(
                                      tag, 0, COSIM_CPL_STATUS_UR) == 0, out);
                } else if (transaction == 1) {
                    CHECK_OR_GOTO(bridge_vcs_send_cpl_scalar_rc(
                                      0, tag, 0) == 0, out);
                } else {
                    CHECK_OR_GOTO(bridge_vcs_send_cpl_scalar(tag, 0) == 0,
                                  out);
                }
                completed = 1;
                break;
            }
            CHECK_OR_GOTO(poll_rc > 0, out);
            usleep(10000);
        }
        CHECK_OR_GOTO(completed, out);
    }
    result = 0;

out:
    if (initialized) {
        bridge_vcs_cleanup_ex();
    }
    return result;
}

static int wait_child(pid_t child)
{
    int status = 0;

    for (int attempt = 0; attempt < 500; attempt++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        }
        if (waited < 0 && errno != EINTR) {
            return 1;
        }
        usleep(10000);
    }

    kill(child, SIGKILL);
    (void)waitpid(child, &status, 0);
    return 1;
}

int main(void)
{
    static const uint8_t expected_status[] = {
        COSIM_CPL_STATUS_UR,
        COSIM_CPL_STATUS_SC,
        COSIM_CPL_STATUS_SC,
    };
    int result = 1;
    int port_base = 20000 + (int)(getpid() % 10000) * 3;
    bridge_ctx_t *ctx = NULL;
    pid_t child = fork();

    if (child < 0) {
        perror("fork");
        return 1;
    }
    if (child == 0) {
        _exit(vcs_stub(port_base));
    }

    alarm(15);
    transport_cfg_t cfg = {
        .transport = "tcp",
        .listen_addr = "127.0.0.1",
        .port_base = port_base,
        .instance_id = 0,
        .is_server = 1,
    };
    ctx = bridge_init_ex(&cfg);
    CHECK_OR_GOTO(ctx != NULL, cleanup_child);
    CHECK_OR_GOTO(bridge_connect_ex(ctx) == 0, cleanup_ctx);

    for (unsigned transaction = 0;
         transaction < sizeof(expected_status) / sizeof(expected_status[0]);
         transaction++) {
        tlp_entry_t req;
        cpl_entry_t cpl;

        memset(&req, 0, sizeof(req));
        memset(&cpl, 0, sizeof(cpl));
        req.type = TLP_MRD;
        req.addr = UINT64_C(0x12345000) + transaction * UINT64_C(0x1000);
        req.len = 4;

        CHECK_OR_GOTO(
            bridge_send_tlp_and_wait_timed(ctx, &req, &cpl, 5000) == 0,
            cleanup_ctx);
        CHECK_OR_GOTO(cpl.type == TLP_CPL, cleanup_ctx);
        CHECK_OR_GOTO(cpl.tag == req.tag, cleanup_ctx);
        CHECK_OR_GOTO(cpl.status == expected_status[transaction], cleanup_ctx);
        CHECK_OR_GOTO(cpl.len == 0, cleanup_ctx);
        CHECK_OR_GOTO(cosim_cpl_status_is_success(cpl.status) ==
                          (transaction != 0),
                      cleanup_ctx);
    }

    result = 0;

cleanup_ctx:
    bridge_destroy(ctx);
cleanup_child:
    if (result != 0) {
        kill(child, SIGTERM);
    }
    if (wait_child(child) != 0) {
        result = 1;
    }
    alarm(0);

    if (result == 0) {
        puts("bridge completion status roundtrip: PASS");
    }
    return result;
}
