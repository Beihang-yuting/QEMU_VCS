/* test_tcp_roundtrip.c — TCP 模式 QEMU-VCS TLP roundtrip
 *
 * fork() 创建两个进程:
 *   Parent = QEMU (server): send TLP + wait CPL
 *   Child  = VCS  (client): recv TLP + send CPL
 */
#define _GNU_SOURCE
#include "cosim_transport.h"
#include "cosim_types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        fflush(stderr); \
        abort(); \
    } \
} while (0)

#define TCP_TEST_PORT 19200
#define NUM_ROUNDTRIPS 10

static int run_vcs(void) {
    usleep(200000);

    transport_cfg_t cfg = {
        .transport   = "tcp",
        .remote_host = "127.0.0.1",
        .port_base   = TCP_TEST_PORT,
        .instance_id = 0,
        .is_server   = 0,
    };
    cosim_transport_t *t = transport_create(&cfg);
    if (!t) {
        fprintf(stderr, "[VCS] transport_create failed\n");
        return 1;
    }
    t->set_ready(t);

    for (int i = 0; i < NUM_ROUNDTRIPS; i++) {
        sync_msg_t msg;
        CHECK(t->recv_sync(t, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_TLP_READY);

        tlp_entry_t tlp;
        CHECK(t->recv_tlp(t, &tlp) == 0);
        CHECK(tlp.type == TLP_MRD);
        CHECK(tlp.tag == (uint8_t)i);

        cpl_entry_t cpl;
        memset(&cpl, 0, sizeof(cpl));
        cpl.type = TLP_CPL;
        cpl.tag = tlp.tag;
        cpl.status = 0;
        cpl.len = 4;
        uint32_t val = 0xA0000000 + (uint32_t)i;
        memcpy(cpl.data, &val, 4);

        CHECK(t->send_cpl(t, &cpl) == 0);

        sync_msg_t ack = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        CHECK(t->send_sync(t, &ack) == 0);
    }

    t->close(t);
    return 0;
}

static int run_qemu(void) {
    transport_cfg_t cfg = {
        .transport   = "tcp",
        .listen_addr = "127.0.0.1",
        .port_base   = TCP_TEST_PORT,
        .instance_id = 0,
        .is_server   = 1,
    };
    cosim_transport_t *t = transport_create(&cfg);
    if (!t) {
        fprintf(stderr, "[QEMU] transport_create failed\n");
        return 1;
    }
    t->set_ready(t);

    for (int i = 0; i < NUM_ROUNDTRIPS; i++) {
        tlp_entry_t tlp;
        memset(&tlp, 0, sizeof(tlp));
        tlp.type = TLP_MRD;
        tlp.tag = (uint8_t)i;
        tlp.len = 4;
        tlp.addr = (uint64_t)(0x1000 + i * 4);

        CHECK(t->send_tlp(t, &tlp) == 0);

        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        CHECK(t->send_sync(t, &msg) == 0);

        sync_msg_t ack;
        CHECK(t->recv_sync(t, &ack) == 0);
        CHECK(ack.type == SYNC_MSG_CPL_READY);

        cpl_entry_t cpl;
        CHECK(t->recv_cpl(t, &cpl) == 0);
        CHECK(cpl.tag == (uint8_t)i);

        uint32_t val;
        memcpy(&val, cpl.data, 4);
        CHECK(val == 0xA0000000 + (uint32_t)i);

        fprintf(stderr, "[QEMU] roundtrip %d/%d OK\n", i + 1, NUM_ROUNDTRIPS);
    }

    t->close(t);
    return 0;
}

int main(void) {
    printf("=== TCP TLP Roundtrip Integration Test (%d rounds) ===\n\n", NUM_ROUNDTRIPS);

    pid_t pid = fork();
    CHECK(pid >= 0);

    if (pid == 0) {
        int rc = run_vcs();
        _exit(rc);
    }

    int rc_qemu = run_qemu();

    int status;
    waitpid(pid, &status, 0);
    int rc_vcs = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

    printf("\n=== Result: QEMU=%d VCS=%d ===\n", rc_qemu, rc_vcs);
    return (rc_qemu || rc_vcs) ? 1 : 0;
}
