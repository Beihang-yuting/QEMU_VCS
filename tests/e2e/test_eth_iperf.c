/* test_eth_iperf.c — ETH SHM throughput benchmark (iperf-style)
 *
 * Uses fork() to run Role-A (TX) and Role-B (RX) in one process pair,
 * communicating through the ETH SHM ring buffer with link_model applied.
 *
 * Usage:
 *   ./test_eth_iperf [OPTIONS]
 *     -s SIZE    frame payload size in bytes (default: 1500)
 *     -t DUR     test duration in seconds (default: 5)
 *     -i INTV    report interval in seconds (default: 1)
 *     -r RATE    rate limit in Mbps (0 = unlimited, default: 0)
 *     -d DROP    drop rate in ppm (default: 0)
 *     -l LAT     one-way latency in us (default: 0)
 *     -w WIN     flow-control window (0 = unlimited, default: 0)
 *
 * Build:
 *   gcc -o build/test_eth_iperf tests/e2e/test_eth_iperf.c \
 *       bridge/common/eth_shm.c bridge/common/link_model.c \
 *       bridge/eth/eth_port.c \
 *       -I bridge/common -I bridge/eth -D_GNU_SOURCE -lrt -lpthread -std=c99
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>

#include "eth_port.h"
#include "eth_types.h"
#include "link_model.h"

/* ---------- helpers ---------- */

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static volatile sig_atomic_t g_stop = 0;
static void handle_sig(int s) { (void)s; g_stop = 1; }

/* ---------- TX (Role A) ---------- */

static int run_tx(const char *shm_name, uint32_t frame_size, int duration_sec,
                  int interval_sec, uint32_t rate_mbps, uint32_t drop_ppm,
                  uint64_t latency_ns, uint32_t fc_window)
{
    eth_port_t port;
    memset(&port, 0, sizeof(port));
    port.link.rate_mbps      = rate_mbps;
    port.link.drop_rate_ppm  = drop_ppm;
    port.link.latency_ns     = latency_ns;
    port.link.fc_window      = fc_window;

    if (eth_port_open(&port, shm_name, ETH_ROLE_A, /*create=*/1) != 0) {
        fprintf(stderr, "[TX] eth_port_open failed\n");
        return 1;
    }

    /* Wait for RX peer */
    int wait = 200;
    while (!eth_shm_peer_ready(&port.shm, ETH_ROLE_A) && wait-- > 0)
        usleep(10000);
    if (wait <= 0) {
        fprintf(stderr, "[TX] Timeout waiting for RX peer\n");
        eth_port_close(&port);
        return 1;
    }

    /* Prepare frame template */
    eth_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    if (frame_size > ETH_FRAME_MAX_DATA)
        frame_size = ETH_FRAME_MAX_DATA;
    frame.len = (uint16_t)frame_size;
    for (uint32_t i = 0; i < frame_size; i++)
        frame.data[i] = (uint8_t)(i & 0xFF);

    printf("[TX] Starting: frame=%u bytes, duration=%ds, rate=%u Mbps, "
           "drop=%u ppm, latency=%lu us, fc_window=%u\n",
           frame_size, duration_sec, rate_mbps, drop_ppm,
           (unsigned long)(latency_ns / 1000), fc_window);

    uint64_t t_start    = now_ns();
    uint64_t t_end      = t_start + (uint64_t)duration_sec * 1000000000ULL;
    uint64_t t_interval = t_start + (uint64_t)interval_sec * 1000000000ULL;

    uint64_t total_bytes  = 0;
    uint64_t total_frames = 0;
    uint64_t intv_bytes   = 0;
    uint64_t intv_frames  = 0;
    uint64_t send_fail    = 0;
    int      intv_num     = 0;

    while (!g_stop) {
        uint64_t t = now_ns();
        if (t >= t_end)
            break;

        int ret = eth_port_send(&port, &frame, t);
        if (ret == 0) {
            total_bytes  += frame_size;
            total_frames += 1;
            intv_bytes   += frame_size;
            intv_frames  += 1;
        } else if (ret == -1) {
            /* ring full — backoff */
            usleep(10);
            send_fail++;
        } else if (ret == -2) {
            /* FC blocked */
            usleep(100);
            send_fail++;
        } else {
            /* dropped by link model — count but continue */
            send_fail++;
        }

        /* Interval report */
        if (t >= t_interval) {
            double elapsed_s = (double)(t - (t_interval - (uint64_t)interval_sec * 1000000000ULL)) / 1e9;
            double mbps = (double)(intv_bytes * 8) / (elapsed_s * 1e6);
            double kpps = (double)intv_frames / (elapsed_s * 1000.0);
            printf("[TX] %2d-%2ds: %10.2f Mbps  %8.1f Kpps  (%lu frames)\n",
                   intv_num * interval_sec, (intv_num + 1) * interval_sec,
                   mbps, kpps, (unsigned long)intv_frames);
            intv_bytes  = 0;
            intv_frames = 0;
            intv_num++;
            t_interval += (uint64_t)interval_sec * 1000000000ULL;
        }
    }

    /* Summary */
    uint64_t t_total = now_ns() - t_start;
    double total_s = (double)t_total / 1e9;
    double avg_mbps = (double)(total_bytes * 8) / (total_s * 1e6);
    double avg_kpps = (double)total_frames / (total_s * 1000.0);

    printf("\n[TX] ========== Summary ==========\n");
    printf("[TX] Duration:    %.2f s\n", total_s);
    printf("[TX] Sent:        %lu frames, %lu bytes\n",
           (unsigned long)total_frames, (unsigned long)total_bytes);
    printf("[TX] Throughput:  %.2f Mbps\n", avg_mbps);
    printf("[TX] Rate:        %.1f Kpps\n", avg_kpps);
    printf("[TX] Send fails:  %lu (ring full / FC / drop)\n", (unsigned long)send_fail);
    printf("[TX] ================================\n");
    fflush(stdout);

    /* Send a zero-length sentinel to signal end */
    eth_frame_t sentinel;
    memset(&sentinel, 0, sizeof(sentinel));
    sentinel.len = 0;
    for (int i = 0; i < 50; i++) {
        if (eth_port_send(&port, &sentinel, now_ns()) == 0)
            break;
        usleep(10000);
    }

    usleep(2000000); /* 2s — let RX drain and print summary */
    eth_port_close(&port);
    return 0;
}

/* ---------- RX (Role B) ---------- */

static int run_rx(const char *shm_name, int duration_sec, int interval_sec)
{
    eth_port_t port;
    memset(&port, 0, sizeof(port));

    /* Wait a bit for TX to create SHM */
    usleep(50000);

    if (eth_port_open(&port, shm_name, ETH_ROLE_B, /*create=*/0) != 0) {
        fprintf(stderr, "[RX] eth_port_open failed\n");
        return 1;
    }

    setlinebuf(stdout);  /* line-buffered so fork child output is visible */
    printf("[RX] Ready, waiting for frames...\n");

    uint64_t t_start    = now_ns();
    uint64_t t_deadline = t_start + (uint64_t)(duration_sec + 3) * 1000000000ULL;
    uint64_t t_interval = t_start + (uint64_t)interval_sec * 1000000000ULL;

    uint64_t total_bytes  = 0;
    uint64_t total_frames = 0;
    uint64_t intv_bytes   = 0;
    uint64_t intv_frames  = 0;
    uint64_t ooo_count    = 0;  /* out-of-order */
    uint32_t last_seq     = 0;
    int      first_frame  = 1;
    int      intv_num     = 0;
    uint64_t first_rx_ns  = 0;
    uint64_t lat_sum_ns   = 0;
    uint64_t lat_max_ns   = 0;
    uint64_t lat_count    = 0;

    eth_frame_t frame;

    while (!g_stop) {
        uint64_t t = now_ns();
        if (t >= t_deadline)
            break;

        int ret = eth_port_recv(&port, &frame, 10000000ULL /* 10ms */);
        if (ret != 0)
            goto check_interval;

        /* Sentinel → exit */
        if (frame.len == 0)
            break;

        t = now_ns();
        if (first_frame) {
            first_rx_ns = t;
            first_frame = 0;
        }

        total_bytes  += frame.len;
        total_frames += 1;
        intv_bytes   += frame.len;
        intv_frames  += 1;

        /* Sequence check */
        if (frame.seq < last_seq && last_seq != 0)
            ooo_count++;
        last_seq = frame.seq;

        /* Latency (if sender stamped) */
        if (frame.timestamp_ns > 0 && t > frame.timestamp_ns) {
            uint64_t lat = t - frame.timestamp_ns;
            lat_sum_ns += lat;
            if (lat > lat_max_ns)
                lat_max_ns = lat;
            lat_count++;
        }

        eth_port_tx_complete(&port);

check_interval:
        t = now_ns();
        if (t >= t_interval) {
            double elapsed_s = (double)(t - (t_interval - (uint64_t)interval_sec * 1000000000ULL)) / 1e9;
            double mbps = (double)(intv_bytes * 8) / (elapsed_s * 1e6);
            double kpps = (double)intv_frames / (elapsed_s * 1000.0);
            printf("[RX] %2d-%2ds: %10.2f Mbps  %8.1f Kpps  (%lu frames)\n",
                   intv_num * interval_sec, (intv_num + 1) * interval_sec,
                   mbps, kpps, (unsigned long)intv_frames);
            intv_bytes  = 0;
            intv_frames = 0;
            intv_num++;
            t_interval += (uint64_t)interval_sec * 1000000000ULL;
        }
    }

    /* Summary */
    uint64_t t_total = (first_rx_ns > 0) ? (now_ns() - first_rx_ns) : 1;
    double total_s = (double)t_total / 1e9;
    double avg_mbps = (double)(total_bytes * 8) / (total_s * 1e6);
    double avg_kpps = (double)total_frames / (total_s * 1000.0);
    double avg_lat_us = (lat_count > 0) ? (double)lat_sum_ns / (double)lat_count / 1000.0 : 0;
    double max_lat_us = (double)lat_max_ns / 1000.0;

    printf("\n[RX] ========== Summary ==========\n");
    printf("[RX] Duration:      %.2f s\n", total_s);
    printf("[RX] Received:      %lu frames, %lu bytes\n",
           (unsigned long)total_frames, (unsigned long)total_bytes);
    printf("[RX] Throughput:    %.2f Mbps\n", avg_mbps);
    printf("[RX] Rate:          %.1f Kpps\n", avg_kpps);
    printf("[RX] Latency avg:   %.1f us\n", avg_lat_us);
    printf("[RX] Latency max:   %.1f us\n", max_lat_us);
    printf("[RX] Out-of-order:  %lu\n", (unsigned long)ooo_count);
    printf("[RX] ================================\n");
    fflush(stdout);

    eth_port_close(&port);
    return 0;
}

/* ---------- main ---------- */

int main(int argc, char *argv[])
{
    uint32_t frame_size  = 1500;
    int      duration    = 5;
    int      interval    = 1;
    uint32_t rate_mbps   = 0;
    uint32_t drop_ppm    = 0;
    uint64_t latency_us  = 0;
    uint32_t fc_window   = 0;
    const char *shm_name = "/cosim_iperf";

    int opt;
    while ((opt = getopt(argc, argv, "s:t:i:r:d:l:w:n:h")) != -1) {
        switch (opt) {
        case 's': frame_size = (uint32_t)atoi(optarg); break;
        case 't': duration   = atoi(optarg);            break;
        case 'i': interval   = atoi(optarg);            break;
        case 'r': rate_mbps  = (uint32_t)atoi(optarg);  break;
        case 'd': drop_ppm   = (uint32_t)atoi(optarg);  break;
        case 'l': latency_us = (uint64_t)atoi(optarg);  break;
        case 'w': fc_window  = (uint32_t)atoi(optarg);  break;
        case 'n': shm_name   = optarg;                  break;
        case 'h':
        default:
            fprintf(stderr,
                "Usage: %s [-s frame_size] [-t duration_s] [-i interval_s]\n"
                "          [-r rate_mbps] [-d drop_ppm] [-l latency_us]\n"
                "          [-w fc_window] [-n shm_name]\n", argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);

    /* Clean up stale SHM */
    eth_shm_unlink(shm_name);

    printf("=== ETH SHM iperf benchmark ===\n");
    printf("Frame size: %u bytes\n", frame_size);
    printf("Duration:   %d s\n", duration);
    printf("Rate limit: %u Mbps (0=unlimited)\n", rate_mbps);
    printf("Drop rate:  %u ppm\n", drop_ppm);
    printf("Latency:    %lu us\n", (unsigned long)latency_us);
    printf("FC window:  %u (0=unlimited)\n", fc_window);
    printf("SHM:        %s\n", shm_name);
    printf("===============================\n\n");

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }

    if (pid == 0) {
        /* Child = RX */
        int rc = run_rx(shm_name, duration, interval);
        _exit(rc);
    }

    /* Parent = TX */
    int tx_rc = run_tx(shm_name, frame_size, duration, interval,
                       rate_mbps, drop_ppm, latency_us * 1000, fc_window);

    int status = 0;
    waitpid(pid, &status, 0);
    int rx_rc = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

    /* Final cleanup */
    eth_shm_unlink(shm_name);

    printf("\n=== Benchmark complete (TX=%d, RX=%d) ===\n", tx_rc, rx_rc);
    return (tx_rc || rx_rc) ? 1 : 0;
}
