/* test_vcs_e2e.c
 * 端到端集成测试：模拟 QEMU 端，通过 SHM+Socket 与 VCS simv 通信
 * 测试流程：
 *   1. 创建 SHM 和 Socket
 *   2. 等待 VCS simv 连接
 *   3. 发送 MRd TLP（读寄存器）
 *   4. 接收 Completion，验证数据
 *   5. 发送 MWr TLP（写寄存器）
 *   6. 再次 MRd 验证写入
 */
#define _GNU_SOURCE
#include "shm_layout.h"
#include "cosim_types.h"
#include "sock_sync.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#define SHM_NAME "/cosim_e2e_test"
#define SOCK_PATH "/tmp/cosim_e2e_test.sock"

static int test_count = 0;
static int pass_count = 0;

#define CHECK(cond, msg) do { \
    test_count++; \
    if (cond) { pass_count++; printf("  PASS: %s\n", msg); } \
    else { printf("  FAIL: %s\n", msg); } \
} while(0)

int main(void) {
    printf("=== VCS E2E Integration Test ===\n");
    printf("SHM: %s  Socket: %s\n\n", SHM_NAME, SOCK_PATH);

    /* Step 1: 创建 SHM */
    cosim_shm_t shm;
    int ret = cosim_shm_create(&shm, SHM_NAME);
    if (ret < 0) {
        fprintf(stderr, "Failed to create SHM\n");
        return 1;
    }
    printf("[QEMU-SIM] SHM created\n");

    /* Step 2: 创建 Socket，等待 VCS 连接 */
    unlink(SOCK_PATH);
    int listen_fd = sock_sync_listen(SOCK_PATH);
    if (listen_fd < 0) {
        fprintf(stderr, "Failed to listen on socket\n");
        cosim_shm_close(&shm);
        shm_unlink(SHM_NAME);
        return 1;
    }
    printf("[QEMU-SIM] Waiting for VCS to connect...\n");
    fflush(stdout);

    int conn_fd = sock_sync_accept(listen_fd);
    if (conn_fd < 0) {
        fprintf(stderr, "Failed to accept connection\n");
        sock_sync_close(listen_fd);
        cosim_shm_close(&shm);
        shm_unlink(SHM_NAME);
        return 1;
    }
    printf("[QEMU-SIM] VCS connected!\n\n");

    /* Step 3: MRd — 读寄存器 0 (addr=0x00, 期望 0xDEAD0000) */
    printf("[Test 1] MRd register 0 (expect 0xDEAD0000)\n");
    {
        tlp_entry_t req = {0};
        req.type = TLP_MRD;
        req.addr = 0x00;
        req.len = 4;
        req.tag = 1;

        ret = ring_buf_enqueue(&shm.req_ring, &req);
        CHECK(ret == 0, "enqueue MRd TLP");

        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        sock_sync_send(conn_fd, &msg);

        sync_msg_t reply;
        ret = sock_sync_recv(conn_fd, &reply);
        CHECK(ret == 0 && reply.type == SYNC_MSG_CPL_READY, "recv CPL notification");

        cpl_entry_t cpl;
        ret = ring_buf_dequeue(&shm.cpl_ring, &cpl);
        CHECK(ret == 0, "dequeue completion");

        uint32_t val;
        memcpy(&val, cpl.data, 4);
        printf("  Read value: 0x%08X\n", val);
        CHECK(val == 0xDEAD0000, "register 0 value == 0xDEAD0000");
    }

    /* Step 4: MWr — 写寄存器 0 (addr=0x00, 写入 0x12345678) */
    printf("\n[Test 2] MWr register 0 (write 0x12345678)\n");
    {
        tlp_entry_t req = {0};
        req.type = TLP_MWR;
        req.addr = 0x00;
        req.len = 4;
        uint32_t wval = 0x12345678;
        memcpy(req.data, &wval, 4);

        ret = ring_buf_enqueue(&shm.req_ring, &req);
        CHECK(ret == 0, "enqueue MWr TLP");

        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        sock_sync_send(conn_fd, &msg);

        /* MWr 无 completion，等一小会让 VCS 处理 */
        usleep(10000);
    }

    /* Step 5: MRd — 再次读寄存器 0 (期望 0x12345678) */
    printf("\n[Test 3] MRd register 0 after write (expect 0x12345678)\n");
    {
        tlp_entry_t req = {0};
        req.type = TLP_MRD;
        req.addr = 0x00;
        req.len = 4;
        req.tag = 2;

        ret = ring_buf_enqueue(&shm.req_ring, &req);
        CHECK(ret == 0, "enqueue MRd TLP");

        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        sock_sync_send(conn_fd, &msg);

        sync_msg_t reply;
        ret = sock_sync_recv(conn_fd, &reply);
        CHECK(ret == 0 && reply.type == SYNC_MSG_CPL_READY, "recv CPL notification");

        cpl_entry_t cpl;
        ret = ring_buf_dequeue(&shm.cpl_ring, &cpl);
        CHECK(ret == 0, "dequeue completion");

        uint32_t val;
        memcpy(&val, cpl.data, 4);
        printf("  Read value: 0x%08X\n", val);
        CHECK(val == 0x12345678, "register 0 value == 0x12345678 after write");
    }

    /* Step 6: MRd — 读寄存器 5 (addr=0x14, 期望 0xDEAD0005) */
    printf("\n[Test 4] MRd register 5 (expect 0xDEAD0005)\n");
    {
        tlp_entry_t req = {0};
        req.type = TLP_MRD;
        req.addr = 0x14;
        req.len = 4;
        req.tag = 3;

        ret = ring_buf_enqueue(&shm.req_ring, &req);
        CHECK(ret == 0, "enqueue MRd TLP");

        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
        sock_sync_send(conn_fd, &msg);

        sync_msg_t reply;
        ret = sock_sync_recv(conn_fd, &reply);
        CHECK(ret == 0 && reply.type == SYNC_MSG_CPL_READY, "recv CPL notification");

        cpl_entry_t cpl;
        ret = ring_buf_dequeue(&shm.cpl_ring, &cpl);
        CHECK(ret == 0, "dequeue completion");

        uint32_t val;
        memcpy(&val, cpl.data, 4);
        printf("  Read value: 0x%08X\n", val);
        CHECK(val == 0xDEAD0005, "register 5 value == 0xDEAD0005");
    }

    /* 通知 VCS 关闭 */
    {
        sync_msg_t msg = { .type = SYNC_MSG_SHUTDOWN, .payload = 0 };
        sock_sync_send(conn_fd, &msg);
    }

    /* 清理 */
    sock_sync_close(conn_fd);
    sock_sync_close(listen_fd);
    cosim_shm_close(&shm);
    shm_unlink(SHM_NAME);
    unlink(SOCK_PATH);

    printf("\n=== Results: %d/%d passed ===\n", pass_count, test_count);
    return (pass_count == test_count) ? 0 : 1;
}
