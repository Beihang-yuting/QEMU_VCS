/* test_eth_bidir.c — 双向 ETH SHM 吞吐量测试
 *
 * 模拟两个 QEMU+VCS 节点通过 ETH SHM 互打：
 *   进程 A (Role A) ←→ 进程 B (Role B)
 * 每个进程内 TX 线程 + RX 线程同时工作，测双向吞吐。
 *
 * Usage:
 *   ./test_eth_bidir [OPTIONS]
 *     -s SIZE    frame payload size (default: 1500)
 *     -t DUR     duration in seconds (default: 5)
 *     -i INTV    report interval in seconds (default: 1)
 *     -r RATE    rate limit Mbps per direction (0=unlimited, default: 0)
 *     -d DROP    drop rate ppm (default: 0)
 *     -l LAT     one-way latency us (default: 0)
 *
 * Build:
 *   gcc -o build/test_eth_bidir tests/e2e/test_eth_bidir.c \
 *       bridge/common/eth_shm.c bridge/common/link_model.c \
 *       bridge/eth/eth_port.c \
 *       -I bridge/common -I bridge/eth -D_GNU_SOURCE -lrt -lpthread -std=c99 -O2
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <sys/wait.h>

#include "eth_port.h"
#include "eth_types.h"
#include "link_model.h"

/* ---------- shared config ---------- */
typedef struct {
    uint32_t frame_size;
    int      duration_sec;
    int      interval_sec;
    uint32_t rate_mbps;
    uint32_t drop_ppm;
    uint64_t latency_ns;
} bidir_cfg_t;

/* ---------- per-direction stats ---------- */
typedef struct {
    uint64_t total_bytes;
    uint64_t total_frames;
    uint64_t send_fail;
    uint64_t ooo_count;
    uint64_t lat_sum_ns;
    uint64_t lat_max_ns;
    uint64_t lat_count;
} bidir_stats_t;

/* ---------- thread context ---------- */
typedef struct {
    eth_port_t   *port;
    bidir_cfg_t  *cfg;
    bidir_stats_t stats;
    const char   *label;    /* e.g. "A-TX", "B-RX" */
} thread_ctx_t;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static volatile sig_atomic_t g_stop = 0;
static void handle_sig(int s) { (void)s; g_stop = 1; }

/* ---------- TX thread ---------- */
static void *tx_thread(void *arg) {
    thread_ctx_t *ctx = (thread_ctx_t *)arg;
    eth_port_t   *port = ctx->port;
    bidir_cfg_t  *cfg  = ctx->cfg;

    eth_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    uint32_t sz = cfg->frame_size;
    if (sz > ETH_FRAME_MAX_DATA) sz = ETH_FRAME_MAX_DATA;
    frame.len = (uint16_t)sz;
    for (uint32_t i = 0; i < sz; i++)
        frame.data[i] = (uint8_t)(i & 0xFF);

    uint64_t t_start = now_ns();
    uint64_t t_end   = t_start + (uint64_t)cfg->duration_sec * 1000000000ULL;
    uint64_t t_intv  = t_start + (uint64_t)cfg->interval_sec * 1000000000ULL;
    int intv_num = 0;
    uint64_t intv_bytes = 0, intv_frames = 0;

    while (!g_stop) {
        uint64_t t = now_ns();
        if (t >= t_end) break;

        int ret = eth_port_send(port, &frame, t);
        if (ret == 0) {
            ctx->stats.total_bytes  += sz;
            ctx->stats.total_frames += 1;
            intv_bytes  += sz;
            intv_frames += 1;
        } else if (ret == -1) {
            usleep(5);
            ctx->stats.send_fail++;
        } else {
            ctx->stats.send_fail++;
        }

        /* interval report */
        if (t >= t_intv) {
            double elapsed = (double)(t - (t_intv - (uint64_t)cfg->interval_sec * 1000000000ULL)) / 1e9;
            double mbps = (double)(intv_bytes * 8) / (elapsed * 1e6);
            double kpps = (double)intv_frames / (elapsed * 1000.0);
            printf("[%s] %2d-%2ds: %10.2f Mbps  %8.1f Kpps  (%lu frames)\n",
                   ctx->label, intv_num * cfg->interval_sec,
                   (intv_num + 1) * cfg->interval_sec,
                   mbps, kpps, (unsigned long)intv_frames);
            intv_bytes = intv_frames = 0;
            intv_num++;
            t_intv += (uint64_t)cfg->interval_sec * 1000000000ULL;
        }
    }

    /* sentinel */
    eth_frame_t sentinel;
    memset(&sentinel, 0, sizeof(sentinel));
    sentinel.len = 0;
    for (int i = 0; i < 50; i++) {
        if (eth_port_send(port, &sentinel, now_ns()) == 0) break;
        usleep(10000);
    }
    return NULL;
}

/* ---------- RX thread ---------- */
static void *rx_thread(void *arg) {
    thread_ctx_t *ctx = (thread_ctx_t *)arg;
    eth_port_t   *port = ctx->port;
    bidir_cfg_t  *cfg  = ctx->cfg;

    uint64_t t_start = now_ns();
    uint64_t t_deadline = t_start + (uint64_t)(cfg->duration_sec + 3) * 1000000000ULL;
    uint64_t t_intv  = t_start + (uint64_t)cfg->interval_sec * 1000000000ULL;
    int intv_num = 0;
    uint64_t intv_bytes = 0, intv_frames = 0;
    uint32_t last_seq = 0;

    eth_frame_t frame;
    while (!g_stop) {
        uint64_t t = now_ns();
        if (t >= t_deadline) break;

        int ret = eth_port_recv(port, &frame, 5000000ULL /* 5ms */);
        if (ret != 0) goto check_intv;

        if (frame.len == 0) break; /* sentinel */

        t = now_ns();
        ctx->stats.total_bytes  += frame.len;
        ctx->stats.total_frames += 1;
        intv_bytes  += frame.len;
        intv_frames += 1;

        if (frame.seq < last_seq && last_seq != 0)
            ctx->stats.ooo_count++;
        last_seq = frame.seq;

        if (frame.timestamp_ns > 0 && t > frame.timestamp_ns) {
            uint64_t lat = t - frame.timestamp_ns;
            ctx->stats.lat_sum_ns += lat;
            if (lat > ctx->stats.lat_max_ns)
                ctx->stats.lat_max_ns = lat;
            ctx->stats.lat_count++;
        }

check_intv:
        t = now_ns();
        if (t >= t_intv) {
            double elapsed = (double)(t - (t_intv - (uint64_t)cfg->interval_sec * 1000000000ULL)) / 1e9;
            double mbps = (double)(intv_bytes * 8) / (elapsed * 1e6);
            double kpps = (double)intv_frames / (elapsed * 1000.0);
            printf("[%s] %2d-%2ds: %10.2f Mbps  %8.1f Kpps  (%lu frames)\n",
                   ctx->label, intv_num * cfg->interval_sec,
                   (intv_num + 1) * cfg->interval_sec,
                   mbps, kpps, (unsigned long)intv_frames);
            intv_bytes = intv_frames = 0;
            intv_num++;
            t_intv += (uint64_t)cfg->interval_sec * 1000000000ULL;
        }
    }
    return NULL;
}

/* ---------- one node (runs as a process) ---------- */
static int run_node(const char *shm_name, eth_role_t role, bidir_cfg_t *cfg)
{
    const char *name = (role == ETH_ROLE_A) ? "A" : "B";
    int create = (role == ETH_ROLE_A) ? 1 : 0;

    setlinebuf(stdout);

    eth_port_t port;
    memset(&port, 0, sizeof(port));
    port.link.rate_mbps     = cfg->rate_mbps;
    port.link.drop_rate_ppm = cfg->drop_ppm;
    port.link.latency_ns    = cfg->latency_ns;

    if (!create) usleep(50000); /* let A create SHM first */

    if (eth_port_open(&port, shm_name, role, create) != 0) {
        fprintf(stderr, "[%s] eth_port_open failed\n", name);
        return 1;
    }

    /* wait for peer */
    int wait = 200;
    while (!eth_shm_peer_ready(&port.shm, role) && wait-- > 0)
        usleep(10000);
    if (wait <= 0) {
        fprintf(stderr, "[%s] Timeout waiting for peer\n", name);
        eth_port_close(&port);
        return 1;
    }

    printf("[%s] Peer connected, starting bidir test...\n", name);

    char tx_label[8], rx_label[8];
    snprintf(tx_label, sizeof(tx_label), "%s-TX", name);
    snprintf(rx_label, sizeof(rx_label), "%s-RX", name);

    thread_ctx_t tx_ctx = { .port = &port, .cfg = cfg, .label = tx_label };
    thread_ctx_t rx_ctx = { .port = &port, .cfg = cfg, .label = rx_label };
    memset(&tx_ctx.stats, 0, sizeof(tx_ctx.stats));
    memset(&rx_ctx.stats, 0, sizeof(rx_ctx.stats));

    uint64_t t0 = now_ns();

    pthread_t tx_tid, rx_tid;
    pthread_create(&tx_tid, NULL, tx_thread, &tx_ctx);
    pthread_create(&rx_tid, NULL, rx_thread, &rx_ctx);
    pthread_join(tx_tid, NULL);
    pthread_join(rx_tid, NULL);

    double elapsed = (double)(now_ns() - t0) / 1e9;
    double tx_mbps = (double)(tx_ctx.stats.total_bytes * 8) / (elapsed * 1e6);
    double rx_mbps = (double)(rx_ctx.stats.total_bytes * 8) / (elapsed * 1e6);
    double tx_kpps = (double)tx_ctx.stats.total_frames / (elapsed * 1000.0);
    double rx_kpps = (double)rx_ctx.stats.total_frames / (elapsed * 1000.0);
    double avg_lat = (rx_ctx.stats.lat_count > 0)
        ? (double)rx_ctx.stats.lat_sum_ns / (double)rx_ctx.stats.lat_count / 1000.0 : 0;
    double max_lat = (double)rx_ctx.stats.lat_max_ns / 1000.0;

    printf("\n[%s] ========== Summary ==========\n", name);
    printf("[%s] Duration:       %.2f s\n", name, elapsed);
    printf("[%s] TX sent:        %lu frames (%lu bytes) -> %.2f Mbps, %.1f Kpps\n",
           name, (unsigned long)tx_ctx.stats.total_frames,
           (unsigned long)tx_ctx.stats.total_bytes, tx_mbps, tx_kpps);
    printf("[%s] TX send fails:  %lu\n", name, (unsigned long)tx_ctx.stats.send_fail);
    printf("[%s] RX received:    %lu frames (%lu bytes) -> %.2f Mbps, %.1f Kpps\n",
           name, (unsigned long)rx_ctx.stats.total_frames,
           (unsigned long)rx_ctx.stats.total_bytes, rx_mbps, rx_kpps);
    printf("[%s] RX latency:     avg=%.1f us, max=%.1f us\n", name, avg_lat, max_lat);
    printf("[%s] RX out-of-order: %lu\n", name, (unsigned long)rx_ctx.stats.ooo_count);
    printf("[%s] Bidir total:    %.2f Mbps (TX+RX)\n", name, tx_mbps + rx_mbps);
    printf("[%s] ================================\n", name);
    fflush(stdout);

    usleep(2000000);
    eth_port_close(&port);
    return 0;
}

/* ---------- main ---------- */
int main(int argc, char *argv[])
{
    bidir_cfg_t cfg = {
        .frame_size   = 1500,
        .duration_sec = 5,
        .interval_sec = 1,
        .rate_mbps    = 0,
        .drop_ppm     = 0,
        .latency_ns   = 0,
    };
    const char *shm_name = "/cosim_bidir";

    int opt;
    while ((opt = getopt(argc, argv, "s:t:i:r:d:l:n:h")) != -1) {
        switch (opt) {
        case 's': cfg.frame_size   = (uint32_t)atoi(optarg); break;
        case 't': cfg.duration_sec = atoi(optarg);            break;
        case 'i': cfg.interval_sec = atoi(optarg);            break;
        case 'r': cfg.rate_mbps    = (uint32_t)atoi(optarg);  break;
        case 'd': cfg.drop_ppm     = (uint32_t)atoi(optarg);  break;
        case 'l': cfg.latency_ns   = (uint64_t)atoi(optarg) * 1000; break;
        case 'n': shm_name         = optarg;                  break;
        case 'h':
        default:
            fprintf(stderr,
                "Usage: %s [-s size] [-t dur] [-i intv] [-r rate_mbps]\n"
                "          [-d drop_ppm] [-l latency_us] [-n shm_name]\n", argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    signal(SIGINT,  handle_sig);
    signal(SIGTERM, handle_sig);

    eth_shm_unlink(shm_name);

    printf("=== ETH SHM Bidirectional Benchmark ===\n");
    printf("Frame size: %u bytes\n", cfg.frame_size);
    printf("Duration:   %d s\n", cfg.duration_sec);
    printf("Rate limit: %u Mbps/dir (0=unlimited)\n", cfg.rate_mbps);
    printf("Drop rate:  %u ppm\n", cfg.drop_ppm);
    printf("Latency:    %lu us\n", (unsigned long)(cfg.latency_ns / 1000));
    printf("SHM:        %s  (DEPTH=%u, ~%.1f MB)\n", shm_name,
           (unsigned)ETH_FRAME_RING_DEPTH,
           2.0 * ETH_FRAME_RING_DEPTH * sizeof(eth_frame_t) / 1048576.0);
    printf("========================================\n\n");

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }

    if (pid == 0) {
        /* child = Node B */
        int rc = run_node(shm_name, ETH_ROLE_B, &cfg);
        _exit(rc);
    }

    /* parent = Node A */
    int rc_a = run_node(shm_name, ETH_ROLE_A, &cfg);

    int status = 0;
    waitpid(pid, &status, 0);
    int rc_b = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

    eth_shm_unlink(shm_name);
    printf("\n=== Benchmark complete (A=%d, B=%d) ===\n", rc_a, rc_b);
    return (rc_a || rc_b) ? 1 : 0;
}
