#define _GNU_SOURCE
/* test_qemu_integration.c — QEMU 侧综合集成测试
 *
 * 用 fork+stub 模拟 VCS 侧，全面验证 QEMU bridge 在两种模式下的行为：
 *
 *   Test 1: Fast 模式 — TLP 发送/接收 + timestamp 传递
 *   Test 2: 模式切换 — Fast → Precise 握手
 *   Test 3: Precise 模式 — 多轮 clock step/ack + sim_time_ns 累加
 *   Test 4: Precise 模式 — TLP timestamp 随 sim_time_ns 推进
 *   Test 5: DMA 请求 + MSI 事件 timestamp 一致性
 *   Test 6: TLP 吞吐量压测 (Fast 模式)
 *
 * Build: cmake --build build -- test_qemu_integration
 * Run:   ./build/tests/integration/test_qemu_integration
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/wait.h>
#include "bridge_qemu.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "irq_poller.h"
#include "cosim_types.h"

/* NDEBUG-safe assert: never compiled away */
#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        fflush(stderr); \
        abort(); \
    } \
} while (0)

/* ========== helpers ========== */

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void wait_vcs_ready(bridge_ctx_t *ctx) {
    for (int i = 0; i < 200; i++) {
        if (atomic_load(&ctx->shm.ctrl->vcs_ready))
            return;
        usleep(10000);
    }
    fprintf(stderr, "TIMEOUT: VCS ready\n");
    abort();
}

static int run_child(pid_t pid) {
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

/* ================================================================
 * Test 1: Fast 模式 TLP roundtrip + timestamp
 * ================================================================ */
static const char *T1_SHM = "/cosim_qi_t1";
static const char *T1_SOCK = "/tmp/cosim_qi_t1.sock";

static void t1_vcs_stub(void) {
    usleep(80000);
    cosim_shm_t shm;
    CHECK(cosim_shm_open(&shm, T1_SHM) == 0);
    int sock = sock_sync_connect(T1_SOCK);
    CHECK(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    /* 接收 5 个 TLP，检验 timestamp 递增，回复 CPL */
    for (int i = 0; i < 5; i++) {
        sync_msg_t msg;
        CHECK(sock_sync_recv(sock, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_TLP_READY);

        tlp_entry_t tlp;
        CHECK(ring_buf_dequeue(&shm.req_ring, &tlp) == 0);

        /* 验证 timestamp > 0 (Fast 模式 QEMU 填入的 wall-clock) */
        CHECK(tlp.timestamp > 0);

        cpl_entry_t cpl;
        memset(&cpl, 0, sizeof(cpl));
        cpl.type = TLP_CPL;
        cpl.tag = tlp.tag;
        cpl.status = 0;
        cpl.len = 4;
        /* 把 tlp 的 timestamp 原样放进 cpl.data 前 8 字节，方便 QEMU 侧做延迟测量 */
        memcpy(cpl.data, &tlp.timestamp, sizeof(uint64_t));
        cpl.timestamp = tlp.timestamp + 500; /* 模拟 VCS 处理 500ns */

        CHECK(ring_buf_enqueue(&shm.cpl_ring, &cpl) == 0);
        sync_msg_t reply = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        sock_sync_send(sock, &reply);
    }

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test1_fast_mode_tlp_timestamp(void) {
    pid_t pid = fork();
    if (pid == 0) { t1_vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(T1_SHM, T1_SOCK);
    CHECK(ctx);
    CHECK(bridge_connect(ctx) == 0);
    wait_vcs_ready(ctx);

    /* 确认默认是 Fast 模式 */
    CHECK(bridge_get_mode(ctx) == COSIM_MODE_FAST);

    uint64_t prev_ts = 0;
    uint64_t lat_sum = 0;
    for (int i = 0; i < 5; i++) {
        tlp_entry_t req;
        memset(&req, 0, sizeof(req));
        req.type = TLP_MRD;
        req.addr = 0xFE000000 + (uint64_t)(i * 4);
        req.len = 4;
        req.timestamp = now_ns(); /* QEMU 填 wall-clock */

        cpl_entry_t cpl;
        CHECK(bridge_send_tlp_and_wait(ctx, &req, &cpl) == 0);
        CHECK(cpl.status == 0);

        /* CPL timestamp 应该 > 发送 timestamp */
        CHECK(cpl.timestamp > req.timestamp);
        /* TLP timestamp 应该递增 */
        CHECK(req.timestamp > prev_ts);
        prev_ts = req.timestamp;

        uint64_t lat = cpl.timestamp - req.timestamp;
        lat_sum += lat;
    }

    printf("  [Test1] Fast mode TLP roundtrip: 5 TLPs, avg VCS latency = %lu ns\n",
           (unsigned long)(lat_sum / 5));

    bridge_destroy(ctx);
    CHECK(run_child(pid) == 0);
    printf("  PASS: test1_fast_mode_tlp_timestamp\n");
}

/* ================================================================
 * Test 2: 模式切换 Fast → Precise
 * ================================================================ */
static const char *T2_SHM = "/cosim_qi_t2";
static const char *T2_SOCK = "/tmp/cosim_qi_t2.sock";

static void t2_vcs_stub(void) {
    usleep(80000);
    cosim_shm_t shm;
    CHECK(cosim_shm_open(&shm, T2_SHM) == 0);
    int sock = sock_sync_connect(T2_SOCK);
    CHECK(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    /* 等 MODE_SWITCH 消息 */
    sync_msg_t msg;
    CHECK(sock_sync_recv(sock, &msg) == 0);
    CHECK(msg.type == SYNC_MSG_MODE_SWITCH);
    CHECK(msg.payload == COSIM_MODE_PRECISE);

    /* 模拟 VCS 切换模式 */
    usleep(10000); /* 模拟切换延迟 */
    shm.ctrl->mode = COSIM_MODE_PRECISE;
    atomic_store(&shm.ctrl->mode_switch_pending, 0);

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test2_mode_switch(void) {
    pid_t pid = fork();
    if (pid == 0) { t2_vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(T2_SHM, T2_SOCK);
    CHECK(ctx);
    CHECK(bridge_connect(ctx) == 0);
    wait_vcs_ready(ctx);

    CHECK(bridge_get_mode(ctx) == COSIM_MODE_FAST);

    /* 请求切换到 Precise */
    CHECK(bridge_request_mode_switch(ctx, COSIM_MODE_PRECISE) == 0);

    /* 等 VCS 完成切换 */
    for (int i = 0; i < 100; i++) {
        if (bridge_get_mode(ctx) == COSIM_MODE_PRECISE)
            break;
        usleep(10000);
    }
    CHECK(bridge_get_mode(ctx) == COSIM_MODE_PRECISE);
    CHECK(atomic_load(&ctx->shm.ctrl->mode_switch_pending) == 0);

    printf("  [Test2] Mode switch: Fast -> Precise OK\n");

    bridge_destroy(ctx);
    CHECK(run_child(pid) == 0);
    printf("  PASS: test2_mode_switch\n");
}

/* ================================================================
 * Test 3: Precise 模式多轮 clock sync
 * ================================================================ */
static const char *T3_SHM = "/cosim_qi_t3";
static const char *T3_SOCK = "/tmp/cosim_qi_t3.sock";

#define T3_CLOCK_ROUNDS   100
#define T3_CYCLES_PER_STEP 50

static void t3_vcs_stub(void) {
    usleep(80000);
    cosim_shm_t shm;
    CHECK(cosim_shm_open(&shm, T3_SHM) == 0);
    int sock = sock_sync_connect(T3_SOCK);
    CHECK(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    /* 接收 MODE_SWITCH */
    sync_msg_t msg;
    CHECK(sock_sync_recv(sock, &msg) == 0);
    CHECK(msg.type == SYNC_MSG_MODE_SWITCH);
    shm.ctrl->mode = COSIM_MODE_PRECISE;
    atomic_store(&shm.ctrl->mode_switch_pending, 0);

    /* 处理 T3_CLOCK_ROUNDS 次 clock step */
    for (int i = 0; i < T3_CLOCK_ROUNDS; i++) {
        CHECK(sock_sync_recv(sock, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_CLOCK_STEP);
        CHECK(msg.payload == T3_CYCLES_PER_STEP);

        /* 每个 cycle = 10ns (100MHz) */
        uint64_t advance_ns = (uint64_t)msg.payload * 10;
        atomic_fetch_add(&shm.ctrl->sim_time_ns, advance_ns);

        sync_msg_t ack = { .type = SYNC_MSG_CLOCK_ACK, .payload = msg.payload };
        sock_sync_send(sock, &ack);
    }

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test3_precise_clock_sync(void) {
    pid_t pid = fork();
    if (pid == 0) { t3_vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(T3_SHM, T3_SOCK);
    CHECK(ctx);
    CHECK(bridge_connect(ctx) == 0);
    wait_vcs_ready(ctx);

    /* 切到 Precise */
    CHECK(bridge_request_mode_switch(ctx, COSIM_MODE_PRECISE) == 0);
    for (int i = 0; i < 100 && bridge_get_mode(ctx) != COSIM_MODE_PRECISE; i++)
        usleep(10000);
    CHECK(bridge_get_mode(ctx) == COSIM_MODE_PRECISE);

    uint64_t start_time = atomic_load(&ctx->shm.ctrl->sim_time_ns);
    uint64_t wall_start = now_ns();

    for (int i = 0; i < T3_CLOCK_ROUNDS; i++) {
        CHECK(bridge_advance_clock(ctx, T3_CYCLES_PER_STEP) == 0);
    }

    uint64_t wall_elapsed = now_ns() - wall_start;
    uint64_t end_time = atomic_load(&ctx->shm.ctrl->sim_time_ns);
    uint64_t expected_advance = (uint64_t)T3_CLOCK_ROUNDS * T3_CYCLES_PER_STEP * 10;
    CHECK(end_time - start_time == expected_advance);

    double sim_us = (double)expected_advance / 1000.0;
    double wall_us = (double)wall_elapsed / 1000.0;
    double sync_rate = sim_us / wall_us;
    double avg_step_us = wall_us / T3_CLOCK_ROUNDS;

    printf("  [Test3] Precise clock sync: %d rounds x %d cycles\n",
           T3_CLOCK_ROUNDS, T3_CYCLES_PER_STEP);
    printf("          sim_time advanced: %lu ns (%.1f us)\n",
           (unsigned long)expected_advance, sim_us);
    printf("          wall time: %.1f us\n", wall_us);
    printf("          avg step latency: %.2f us/step\n", avg_step_us);
    printf("          sim/wall ratio: %.4f\n", sync_rate);

    bridge_destroy(ctx);
    CHECK(run_child(pid) == 0);
    printf("  PASS: test3_precise_clock_sync\n");
}

/* ================================================================
 * Test 4: Precise 模式下 TLP timestamp 随 sim_time 推进
 * ================================================================ */
static const char *T4_SHM = "/cosim_qi_t4";
static const char *T4_SOCK = "/tmp/cosim_qi_t4.sock";

static void t4_vcs_stub(void) {
    usleep(80000);
    cosim_shm_t shm;
    CHECK(cosim_shm_open(&shm, T4_SHM) == 0);
    int sock = sock_sync_connect(T4_SOCK);
    CHECK(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    /* MODE_SWITCH */
    sync_msg_t msg;
    CHECK(sock_sync_recv(sock, &msg) == 0);
    CHECK(msg.type == SYNC_MSG_MODE_SWITCH);
    shm.ctrl->mode = COSIM_MODE_PRECISE;
    atomic_store(&shm.ctrl->mode_switch_pending, 0);

    /* 交替处理: CLOCK_STEP 和 TLP */
    for (int round = 0; round < 5; round++) {
        /* clock step */
        CHECK(sock_sync_recv(sock, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_CLOCK_STEP);
        atomic_fetch_add(&shm.ctrl->sim_time_ns, (uint64_t)msg.payload * 10);
        sync_msg_t ack = { .type = SYNC_MSG_CLOCK_ACK, .payload = msg.payload };
        sock_sync_send(sock, &ack);

        /* TLP */
        CHECK(sock_sync_recv(sock, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_TLP_READY);

        tlp_entry_t tlp;
        CHECK(ring_buf_dequeue(&shm.req_ring, &tlp) == 0);

        uint64_t cur_sim = atomic_load(&shm.ctrl->sim_time_ns);
        cpl_entry_t cpl;
        memset(&cpl, 0, sizeof(cpl));
        cpl.type = TLP_CPL;
        cpl.tag = tlp.tag;
        cpl.status = 0;
        cpl.len = 4;
        cpl.data[0] = (uint8_t)(round + 1);
        cpl.timestamp = cur_sim; /* VCS 用当前 sim_time 标记 CPL */

        CHECK(ring_buf_enqueue(&shm.cpl_ring, &cpl) == 0);
        sync_msg_t reply = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        sock_sync_send(sock, &reply);
    }

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test4_precise_tlp_timestamp(void) {
    pid_t pid = fork();
    if (pid == 0) { t4_vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(T4_SHM, T4_SOCK);
    CHECK(ctx);
    CHECK(bridge_connect(ctx) == 0);
    wait_vcs_ready(ctx);

    CHECK(bridge_request_mode_switch(ctx, COSIM_MODE_PRECISE) == 0);
    for (int i = 0; i < 100 && bridge_get_mode(ctx) != COSIM_MODE_PRECISE; i++)
        usleep(10000);
    CHECK(bridge_get_mode(ctx) == COSIM_MODE_PRECISE);

    uint64_t prev_cpl_ts = 0;
    for (int round = 0; round < 5; round++) {
        /* 先推进时钟 100 cycles = 1000ns */
        CHECK(bridge_advance_clock(ctx, 100) == 0);

        uint64_t cur_sim = atomic_load(&ctx->shm.ctrl->sim_time_ns);

        /* 发 TLP */
        tlp_entry_t req;
        memset(&req, 0, sizeof(req));
        req.type = TLP_MRD;
        req.addr = 0xFE001000 + (uint64_t)(round * 4);
        req.len = 4;
        req.timestamp = cur_sim; /* 用 sim_time 而非 wall-clock */

        cpl_entry_t cpl;
        CHECK(bridge_send_tlp_and_wait(ctx, &req, &cpl) == 0);

        /* CPL timestamp = sim_time at VCS 处理时，应 >= req.timestamp */
        CHECK(cpl.timestamp >= req.timestamp);
        /* 每轮推进 1000ns，CPL timestamp 应单调递增 */
        CHECK(cpl.timestamp > prev_cpl_ts);
        prev_cpl_ts = cpl.timestamp;

        printf("  [Test4] round %d: sim_time=%lu ns, cpl_ts=%lu ns\n",
               round, (unsigned long)cur_sim, (unsigned long)cpl.timestamp);
    }

    bridge_destroy(ctx);
    CHECK(run_child(pid) == 0);
    printf("  PASS: test4_precise_tlp_timestamp\n");
}

/* ================================================================
 * Test 5: DMA + MSI 在 Precise 模式下的 timestamp
 * ================================================================ */
static const char *T5_SHM = "/cosim_qi_t5";
static const char *T5_SOCK = "/tmp/cosim_qi_t5.sock";

static volatile int t5_dma_count = 0;
static volatile int t5_msi_count = 0;
static uint64_t t5_dma_timestamps[4];
static uint64_t t5_msi_timestamps[4];

static void t5_dma_cb(const dma_req_t *req, void *user) {
    (void)user;
    int idx = __atomic_fetch_add(&t5_dma_count, 1, __ATOMIC_SEQ_CST);
    if (idx < 4) t5_dma_timestamps[idx] = req->timestamp;
}

static void t5_msi_cb(uint32_t vector, void *user) {
    cosim_shm_t *shm = user;
    int idx = __atomic_fetch_add(&t5_msi_count, 1, __ATOMIC_SEQ_CST);
    if (idx < 4) t5_msi_timestamps[idx] = atomic_load(&shm->ctrl->sim_time_ns);
    (void)vector;
}

static void t5_vcs_stub(void) {
    usleep(80000);
    cosim_shm_t shm;
    CHECK(cosim_shm_open(&shm, T5_SHM) == 0);
    int sock = sock_sync_connect(T5_SOCK);
    CHECK(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    /* MODE_SWITCH */
    sync_msg_t msg;
    CHECK(sock_sync_recv(sock, &msg) == 0);
    CHECK(msg.type == SYNC_MSG_MODE_SWITCH);
    shm.ctrl->mode = COSIM_MODE_PRECISE;
    atomic_store(&shm.ctrl->mode_switch_pending, 0);

    /* 交替推进时钟，发 DMA 和 MSI */
    for (int i = 0; i < 4; i++) {
        /* CLOCK_STEP */
        CHECK(sock_sync_recv(sock, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_CLOCK_STEP);
        uint64_t advance = (uint64_t)msg.payload * 10;
        atomic_fetch_add(&shm.ctrl->sim_time_ns, advance);
        sync_msg_t ack = { .type = SYNC_MSG_CLOCK_ACK, .payload = msg.payload };
        sock_sync_send(sock, &ack);

        uint64_t cur_sim = atomic_load(&shm.ctrl->sim_time_ns);

        /* 发 DMA request，带上当前 sim_time */
        dma_req_t dma = {
            .tag = (uint32_t)i,
            .direction = DMA_DIR_WRITE,
            .host_addr = 0x2000 + (uint64_t)(i * 64),
            .len = 16,
            .dma_offset = 0,
            .timestamp = cur_sim,
        };
        CHECK(ring_buf_enqueue(&shm.dma_req_ring, &dma) == 0);

        /* 发 MSI 事件 */
        msi_event_t msi = { .vector = (uint32_t)i, .timestamp = cur_sim };
        CHECK(ring_buf_enqueue(&shm.msi_ring, &msi) == 0);

        usleep(30000); /* 等 poller 处理 */
    }

    sleep(1);
    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test5_dma_msi_timestamp(void) {
    t5_dma_count = 0;
    t5_msi_count = 0;
    memset(t5_dma_timestamps, 0, sizeof(t5_dma_timestamps));
    memset(t5_msi_timestamps, 0, sizeof(t5_msi_timestamps));

    pid_t pid = fork();
    if (pid == 0) { t5_vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(T5_SHM, T5_SOCK);
    CHECK(ctx);
    CHECK(bridge_connect(ctx) == 0);
    wait_vcs_ready(ctx);

    irq_poller_t *poller = irq_poller_start(&ctx->shm, t5_dma_cb, t5_msi_cb, &ctx->shm);
    CHECK(poller);

    CHECK(bridge_request_mode_switch(ctx, COSIM_MODE_PRECISE) == 0);
    for (int i = 0; i < 100 && bridge_get_mode(ctx) != COSIM_MODE_PRECISE; i++)
        usleep(10000);
    CHECK(bridge_get_mode(ctx) == COSIM_MODE_PRECISE);

    /* 推 4 轮时钟，每轮 200 cycles = 2000ns */
    for (int i = 0; i < 4; i++) {
        CHECK(bridge_advance_clock(ctx, 200) == 0);
        usleep(50000); /* 等 VCS stub 发 DMA/MSI */
    }

    /* 等待 poller 接收完 */
    for (int i = 0; i < 50; i++) {
        if (__atomic_load_n(&t5_dma_count, __ATOMIC_SEQ_CST) >= 4 &&
            __atomic_load_n(&t5_msi_count, __ATOMIC_SEQ_CST) >= 4)
            break;
        usleep(50000);
    }
    CHECK(__atomic_load_n(&t5_dma_count, __ATOMIC_SEQ_CST) >= 4);
    CHECK(__atomic_load_n(&t5_msi_count, __ATOMIC_SEQ_CST) >= 4);

    /* DMA timestamps 应单调递增（每轮 +2000ns） */
    printf("  [Test5] DMA + MSI timestamps in Precise mode:\n");
    for (int i = 0; i < 4; i++) {
        printf("          round %d: dma_ts=%lu ns, msi_sim_time=%lu ns\n",
               i, (unsigned long)t5_dma_timestamps[i],
               (unsigned long)t5_msi_timestamps[i]);
        if (i > 0) {
            CHECK(t5_dma_timestamps[i] > t5_dma_timestamps[i - 1]);
        }
    }

    irq_poller_stop(poller);
    bridge_destroy(ctx);
    CHECK(run_child(pid) == 0);
    printf("  PASS: test5_dma_msi_timestamp\n");
}

/* ================================================================
 * Test 6: Fast 模式 TLP 吞吐量压测
 * ================================================================ */
static const char *T6_SHM = "/cosim_qi_t6";
static const char *T6_SOCK = "/tmp/cosim_qi_t6.sock";

#define T6_ROUNDS  1000

static void t6_vcs_stub(void) {
    usleep(80000);
    cosim_shm_t shm;
    CHECK(cosim_shm_open(&shm, T6_SHM) == 0);
    int sock = sock_sync_connect(T6_SOCK);
    CHECK(sock >= 0);
    atomic_store(&shm.ctrl->vcs_ready, 1);

    for (int i = 0; i < T6_ROUNDS; i++) {
        sync_msg_t msg;
        if (sock_sync_recv(sock, &msg) != 0) break;
        if (msg.type == SYNC_MSG_SHUTDOWN) break;
        CHECK(msg.type == SYNC_MSG_TLP_READY);

        tlp_entry_t tlp;
        CHECK(ring_buf_dequeue(&shm.req_ring, &tlp) == 0);

        cpl_entry_t cpl;
        memset(&cpl, 0, sizeof(cpl));
        cpl.type = TLP_CPL;
        cpl.tag = tlp.tag;
        cpl.status = 0;
        cpl.len = 4;
        cpl.data[0] = 0xAA;
        cpl.timestamp = tlp.timestamp;

        CHECK(ring_buf_enqueue(&shm.cpl_ring, &cpl) == 0);
        sync_msg_t reply = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        sock_sync_send(sock, &reply);
    }

    sock_sync_close(sock);
    cosim_shm_close(&shm);
}

static void test6_fast_throughput(void) {
    pid_t pid = fork();
    if (pid == 0) { t6_vcs_stub(); _exit(0); }

    bridge_ctx_t *ctx = bridge_init(T6_SHM, T6_SOCK);
    CHECK(ctx);
    CHECK(bridge_connect(ctx) == 0);
    wait_vcs_ready(ctx);

    uint64_t t_start = now_ns();
    uint64_t lat_min = UINT64_MAX, lat_max = 0, lat_sum = 0;

    for (int i = 0; i < T6_ROUNDS; i++) {
        tlp_entry_t req;
        memset(&req, 0, sizeof(req));
        req.type = TLP_MWR;
        req.addr = 0xFE002000;
        req.len = 4;
        req.data[0] = (uint8_t)(i & 0xFF);
        req.timestamp = now_ns();

        cpl_entry_t cpl;
        CHECK(bridge_send_tlp_and_wait(ctx, &req, &cpl) == 0);

        uint64_t lat = now_ns() - req.timestamp;
        lat_sum += lat;
        if (lat < lat_min) lat_min = lat;
        if (lat > lat_max) lat_max = lat;
    }

    uint64_t t_elapsed = now_ns() - t_start;
    double elapsed_ms = (double)t_elapsed / 1e6;
    double ops_per_sec = (double)T6_ROUNDS / ((double)t_elapsed / 1e9);
    double avg_lat_us = (double)lat_sum / (double)T6_ROUNDS / 1000.0;

    printf("  [Test6] Fast mode TLP throughput:\n");
    printf("          %d roundtrips in %.1f ms\n", T6_ROUNDS, elapsed_ms);
    printf("          %.0f ops/sec\n", ops_per_sec);
    printf("          latency: avg=%.1f us, min=%.1f us, max=%.1f us\n",
           avg_lat_us, (double)lat_min / 1000.0, (double)lat_max / 1000.0);

    bridge_destroy(ctx);
    CHECK(run_child(pid) == 0);
    printf("  PASS: test6_fast_throughput\n");
}

/* ================================================================ */
int main(void) {
    setlinebuf(stdout);
    printf("=== QEMU Integration Tests ===\n\n");

    test1_fast_mode_tlp_timestamp();
    printf("\n");
    test2_mode_switch();
    printf("\n");
    test3_precise_clock_sync();
    printf("\n");
    test4_precise_tlp_timestamp();
    printf("\n");
    test5_dma_msi_timestamp();
    printf("\n");
    test6_fast_throughput();

    printf("\n=== ALL 6 TESTS PASSED ===\n");
    return 0;
}
