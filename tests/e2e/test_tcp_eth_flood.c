/* test_tcp_eth_flood.c — ETH 帧吞吐量压力测试
 *
 * 用法:
 *   Server (TX): ./test_tcp_eth_flood --server --port 9200 [-s 1500] [-t 10] [-i 1] [-b]
 *   Client (RX): ./test_tcp_eth_flood --client --host 10.11.10.53 --port 9200 [-s 1500] [-t 10] [-i 1] [-b]
 *
 * 参数:
 *   -s SIZE      帧大小 (字节, 默认 1500)
 *   -t DURATION  测试时长 (秒, 默认 10)
 *   -i INTERVAL  报告间隔 (秒, 默认 1)
 *   -b           双向模式 (默认单向: server→client)
 *
 * 测试内容:
 *   1. Server 持续发送 ETH 帧, Client 接收并统计
 *   2. 每隔 INTERVAL 秒输出吞吐量 (Mbps, Kpps)
 *   3. 结束时输出总结: 总吞吐量, 延迟统计, 丢帧率
 */
#define _GNU_SOURCE
#include "cosim_transport.h"
#include "cosim_types.h"
#include "eth_types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <signal.h>

/* GCC 4.8 兼容: 用 __sync builtins 替代 stdatomic */
#if __STDC_VERSION__ >= 201112L && !defined(__STDC_NO_ATOMICS__)
#include <stdatomic.h>
#define ATOMIC_LOAD(p)       atomic_load(p)
#define ATOMIC_STORE(p, v)   atomic_store(p, v)
#define ATOMIC_ADD(p, v)     atomic_fetch_add(p, v)
typedef atomic_int           atomic_flag_t;
typedef atomic_uint_fast64_t atomic_u64_t;
#else
#define ATOMIC_LOAD(p)       __sync_add_and_fetch(p, 0)
#define ATOMIC_STORE(p, v)   do { __sync_synchronize(); *(p) = (v); __sync_synchronize(); } while(0)
#define ATOMIC_ADD(p, v)     __sync_fetch_and_add(p, v)
typedef volatile int         atomic_flag_t;
typedef volatile uint64_t    atomic_u64_t;
#endif

static atomic_flag_t g_running = 1;

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

typedef struct {
    cosim_transport_t *transport;
    uint16_t frame_size;
    int duration_sec;
    int interval_sec;
    int bidir;
} test_cfg_t;

typedef struct {
    atomic_u64_t tx_frames;
    atomic_u64_t tx_bytes;
    atomic_u64_t rx_frames;
    atomic_u64_t rx_bytes;
    atomic_u64_t rx_errors;
    atomic_u64_t lat_sum_us;
    atomic_u64_t lat_min_us;
    atomic_u64_t lat_max_us;
} stats_t;

static stats_t g_stats;

static void stats_init(void) {
    ATOMIC_STORE(&g_stats.tx_frames, 0);
    ATOMIC_STORE(&g_stats.tx_bytes, 0);
    ATOMIC_STORE(&g_stats.rx_frames, 0);
    ATOMIC_STORE(&g_stats.rx_bytes, 0);
    ATOMIC_STORE(&g_stats.rx_errors, 0);
    ATOMIC_STORE(&g_stats.lat_sum_us, 0);
    ATOMIC_STORE(&g_stats.lat_min_us, UINT64_MAX);
    ATOMIC_STORE(&g_stats.lat_max_us, 0);
}

static void sigint_handler(int sig) {
    (void)sig;
    ATOMIC_STORE(&g_running, 0);
}

/* TX 线程: 持续发送 ETH 帧 */
static void *tx_thread(void *arg) {
    test_cfg_t *cfg = (test_cfg_t *)arg;
    cosim_transport_t *t = cfg->transport;
    uint16_t fsize = cfg->frame_size;
    uint32_t seq = 0;

    eth_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.len = fsize;

    /* 填充数据模式 */
    for (uint16_t i = 0; i < fsize && i < ETH_FRAME_MAX_DATA; i++)
        frame.data[i] = (uint8_t)(i & 0xFF);

    while (ATOMIC_LOAD(&g_running)) {
        frame.seq = ++seq;
        frame.timestamp_ns = now_ns();

        if (t->send_eth(t, &frame) != 0) {
            break;
        }

        ATOMIC_ADD(&g_stats.tx_frames, 1);
        ATOMIC_ADD(&g_stats.tx_bytes, (uint64_t)fsize);
    }

    return NULL;
}

/* RX 线程: 接收 ETH 帧并统计 */
static void *rx_thread(void *arg) {
    test_cfg_t *cfg = (test_cfg_t *)arg;
    cosim_transport_t *t = cfg->transport;

    while (ATOMIC_LOAD(&g_running)) {
        eth_frame_t frame;
        int rc = t->recv_eth(t, &frame, 500000000ULL); /* 500ms timeout */
        if (rc != 0) {
            if (ATOMIC_LOAD(&g_running))
                continue; /* timeout, retry */
            break;
        }

        uint64_t rx_time = now_ns();
        uint64_t lat_us = 0;
        if (rx_time > frame.timestamp_ns)
            lat_us = (rx_time - frame.timestamp_ns) / 1000;

        ATOMIC_ADD(&g_stats.rx_frames, 1);
        ATOMIC_ADD(&g_stats.rx_bytes, (uint64_t)frame.len);
        ATOMIC_ADD(&g_stats.lat_sum_us, lat_us);

        /* 更新 min/max (非精确, CAS 开销太大, 近似即可) */
        uint64_t cur_min = ATOMIC_LOAD(&g_stats.lat_min_us);
        if (lat_us < cur_min)
            ATOMIC_STORE(&g_stats.lat_min_us, lat_us);

        uint64_t cur_max = ATOMIC_LOAD(&g_stats.lat_max_us);
        if (lat_us > cur_max)
            ATOMIC_STORE(&g_stats.lat_max_us, lat_us);

        /* 验证数据完整性 (抽样检查前16字节) */
        int ok = 1;
        for (uint16_t i = 0; i < 16 && i < frame.len; i++) {
            if (frame.data[i] != (uint8_t)(i & 0xFF)) {
                ok = 0;
                break;
            }
        }
        if (!ok)
            ATOMIC_ADD(&g_stats.rx_errors, 1);
    }

    return NULL;
}

/* 报告线程: 定期输出统计 */
static void *report_thread(void *arg) {
    test_cfg_t *cfg = (test_cfg_t *)arg;
    int interval = cfg->interval_sec;
    int elapsed = 0;

    uint64_t prev_tx_frames = 0, prev_tx_bytes = 0;
    uint64_t prev_rx_frames = 0, prev_rx_bytes = 0;

    while (ATOMIC_LOAD(&g_running)) {
        sleep((unsigned)interval);
        elapsed += interval;

        uint64_t tx_f = ATOMIC_LOAD(&g_stats.tx_frames);
        uint64_t tx_b = ATOMIC_LOAD(&g_stats.tx_bytes);
        uint64_t rx_f = ATOMIC_LOAD(&g_stats.rx_frames);
        uint64_t rx_b = ATOMIC_LOAD(&g_stats.rx_bytes);

        uint64_t d_tx_f = tx_f - prev_tx_frames;
        uint64_t d_tx_b = tx_b - prev_tx_bytes;
        uint64_t d_rx_f = rx_f - prev_rx_frames;
        uint64_t d_rx_b = rx_b - prev_rx_bytes;

        double tx_mbps = (double)(d_tx_b * 8) / ((double)interval * 1000000.0);
        double rx_mbps = (double)(d_rx_b * 8) / ((double)interval * 1000000.0);
        double tx_kpps = (double)d_tx_f / ((double)interval * 1000.0);
        double rx_kpps = (double)d_rx_f / ((double)interval * 1000.0);

        printf("[%3ds] TX: %.1f Mbps (%.1f Kpps, %lu frames) | "
               "RX: %.1f Mbps (%.1f Kpps, %lu frames)\n",
               elapsed, tx_mbps, tx_kpps, (unsigned long)d_tx_f,
               rx_mbps, rx_kpps, (unsigned long)d_rx_f);
        fflush(stdout);

        prev_tx_frames = tx_f;
        prev_tx_bytes = tx_b;
        prev_rx_frames = rx_f;
        prev_rx_bytes = rx_b;
    }

    return NULL;
}

static void print_summary(uint64_t total_us) {
    uint64_t tx_f = ATOMIC_LOAD(&g_stats.tx_frames);
    uint64_t tx_b = ATOMIC_LOAD(&g_stats.tx_bytes);
    uint64_t rx_f = ATOMIC_LOAD(&g_stats.rx_frames);
    uint64_t rx_b = ATOMIC_LOAD(&g_stats.rx_bytes);
    uint64_t rx_err = ATOMIC_LOAD(&g_stats.rx_errors);
    uint64_t lat_sum = ATOMIC_LOAD(&g_stats.lat_sum_us);
    uint64_t lat_min = ATOMIC_LOAD(&g_stats.lat_min_us);
    uint64_t lat_max = ATOMIC_LOAD(&g_stats.lat_max_us);

    double total_sec = (double)total_us / 1000000.0;
    double tx_mbps = (double)(tx_b * 8) / (total_sec * 1000000.0);
    double rx_mbps = (double)(rx_b * 8) / (total_sec * 1000000.0);

    printf("\n=== 测试总结 (%.1f 秒) ===\n", total_sec);
    printf("TX: %lu 帧, %lu 字节, %.1f Mbps\n",
           (unsigned long)tx_f, (unsigned long)tx_b, tx_mbps);
    printf("RX: %lu 帧, %lu 字节, %.1f Mbps\n",
           (unsigned long)rx_f, (unsigned long)rx_b, rx_mbps);

    if (rx_f > 0) {
        double avg_lat = (double)lat_sum / (double)rx_f;
        if (lat_min == UINT64_MAX) lat_min = 0;
        printf("延迟: avg=%.0f us, min=%lu us, max=%lu us\n",
               avg_lat, (unsigned long)lat_min, (unsigned long)lat_max);
    }

    if (tx_f > 0) {
        double loss = 100.0 * (double)(tx_f - rx_f) / (double)tx_f;
        printf("丢帧: %lu / %lu (%.2f%%)\n",
               (unsigned long)(tx_f - rx_f), (unsigned long)tx_f, loss);
    }

    if (rx_err > 0)
        printf("数据校验错误: %lu\n", (unsigned long)rx_err);

    printf("=========================\n");
}

static int run_server(int port, test_cfg_t *cfg) {
    printf("[Server] 启动 ETH 吞吐量测试, 帧大小=%u, 时长=%ds\n",
           cfg->frame_size, cfg->duration_sec);

    transport_cfg_t tcfg = {
        .transport   = "tcp",
        .listen_addr = "0.0.0.0",
        .port_base   = port,
        .instance_id = 0,
        .is_server   = 1,
    };
    cosim_transport_t *t = transport_create(&tcfg);
    if (!t) {
        fprintf(stderr, "[Server] transport_create 失败\n");
        return 1;
    }
    t->set_ready(t);
    cfg->transport = t;
    printf("[Server] Client 已连接, 开始测试...\n\n");

    stats_init();
    uint64_t t0 = now_us();

    pthread_t tid_tx, tid_rx, tid_rpt;
    pthread_create(&tid_rpt, NULL, report_thread, cfg);
    pthread_create(&tid_tx, NULL, tx_thread, cfg);

    if (cfg->bidir)
        pthread_create(&tid_rx, NULL, rx_thread, cfg);

    sleep((unsigned)cfg->duration_sec);
    ATOMIC_STORE(&g_running, 0);

    pthread_join(tid_tx, NULL);
    if (cfg->bidir)
        pthread_join(tid_rx, NULL);
    pthread_join(tid_rpt, NULL);

    uint64_t total_us = now_us() - t0;
    print_summary(total_us);

    t->close(t);
    return 0;
}

static int run_client(const char *host, int port, test_cfg_t *cfg) {
    printf("[Client] 连接到 %s:%d, 帧大小=%u, 时长=%ds\n",
           host, port, cfg->frame_size, cfg->duration_sec);

    transport_cfg_t tcfg = {
        .transport   = "tcp",
        .remote_host = host,
        .port_base   = port,
        .instance_id = 0,
        .is_server   = 0,
    };
    cosim_transport_t *t = transport_create(&tcfg);
    if (!t) {
        fprintf(stderr, "[Client] transport_create 失败\n");
        return 1;
    }
    t->set_ready(t);
    cfg->transport = t;
    printf("[Client] 已连接, 开始接收...\n\n");

    stats_init();
    uint64_t t0 = now_us();

    pthread_t tid_rx, tid_tx, tid_rpt;
    pthread_create(&tid_rpt, NULL, report_thread, cfg);
    pthread_create(&tid_rx, NULL, rx_thread, cfg);

    if (cfg->bidir)
        pthread_create(&tid_tx, NULL, tx_thread, cfg);

    sleep((unsigned)cfg->duration_sec);
    ATOMIC_STORE(&g_running, 0);

    pthread_join(tid_rx, NULL);
    if (cfg->bidir)
        pthread_join(tid_tx, NULL);
    pthread_join(tid_rpt, NULL);

    uint64_t total_us = now_us() - t0;
    print_summary(total_us);

    t->close(t);
    return 0;
}

int main(int argc, char *argv[]) {
    int is_server = 0, is_client = 0;
    const char *host = "127.0.0.1";
    int port = 9200;

    test_cfg_t cfg = {
        .frame_size   = 1500,
        .duration_sec = 10,
        .interval_sec = 1,
        .bidir        = 0,
    };

    signal(SIGINT, sigint_handler);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--server") == 0) is_server = 1;
        else if (strcmp(argv[i], "--client") == 0) is_client = 1;
        else if (strcmp(argv[i], "--host") == 0 && i + 1 < argc) host = argv[++i];
        else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) port = atoi(argv[++i]);
        else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) cfg.frame_size = (uint16_t)atoi(argv[++i]);
        else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) cfg.duration_sec = atoi(argv[++i]);
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) cfg.interval_sec = atoi(argv[++i]);
        else if (strcmp(argv[i], "-b") == 0) cfg.bidir = 1;
    }

    if (!is_server && !is_client) {
        fprintf(stderr, "用法:\n");
        fprintf(stderr, "  %s --server [--port PORT] [-s SIZE] [-t SEC] [-i SEC] [-b]\n", argv[0]);
        fprintf(stderr, "  %s --client --host HOST [--port PORT] [-s SIZE] [-t SEC] [-i SEC] [-b]\n", argv[0]);
        fprintf(stderr, "\n选项:\n");
        fprintf(stderr, "  -s SIZE      帧大小 (字节, 默认 1500)\n");
        fprintf(stderr, "  -t DURATION  测试时长 (秒, 默认 10)\n");
        fprintf(stderr, "  -i INTERVAL  报告间隔 (秒, 默认 1)\n");
        fprintf(stderr, "  -b           双向模式\n");
        return 1;
    }

    printf("=== ETH 帧吞吐量压力测试 ===\n");
    printf("模式: %s, 端口: %d, 帧大小: %u, 时长: %ds%s\n\n",
           is_server ? "SERVER(TX)" : "CLIENT(RX)", port,
           cfg.frame_size, cfg.duration_sec,
           cfg.bidir ? ", 双向" : "");

    if (is_server) return run_server(port, &cfg);
    else return run_client(host, port, &cfg);
}
