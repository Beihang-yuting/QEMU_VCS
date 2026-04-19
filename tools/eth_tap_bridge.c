/* cosim-platform/tools/eth_tap_bridge.c
 * TAP <-> ETH SHM bridge daemon
 *
 * Bridges frames between a Linux TAP device and the CoSim ETH shared memory.
 * This allows the QEMU guest (via VCS virtqueue) to communicate with the
 * host network stack.
 *
 * Usage:
 *   sudo ./eth_tap_bridge [-s /cosim_eth0] [-t cosim0] [-i 10.0.0.1/24]
 *
 * The bridge runs as Role B on the ETH SHM (VCS is Role A).
 * Data flow:
 *   Guest TX -> VCS -> ETH SHM (a_to_b) -> this bridge -> TAP -> host stack
 *   Host stack -> TAP -> this bridge -> ETH SHM (b_to_a) -> VCS -> Guest RX
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <time.h>

#include "eth_port.h"

static volatile int g_running = 1;
static void sig_handler(int sig) { (void)sig; g_running = 0; }

/* Open a TAP device. Returns fd on success, -1 on error. */
static int tap_open(const char *dev_name, char *actual_name, size_t name_len)
{
    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) {
        perror("open /dev/net/tun");
        return -1;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;  /* TAP mode, no packet info header */
    if (dev_name && dev_name[0])
        strncpy(ifr.ifr_name, dev_name, IFNAMSIZ - 1);

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("ioctl TUNSETIFF");
        close(fd);
        return -1;
    }

    if (actual_name)
        snprintf(actual_name, name_len, "%s", ifr.ifr_name);

    /* Set non-blocking */
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    return fd;
}

/* Configure IP address on the TAP device */
static int tap_configure(const char *dev_name, const char *ip_cidr)
{
    char cmd[256];
    int rc;

    snprintf(cmd, sizeof(cmd), "ip addr add %s dev %s 2>/dev/null", ip_cidr, dev_name);
    rc = system(cmd);

    snprintf(cmd, sizeof(cmd), "ip link set %s up", dev_name);
    rc = system(cmd);
    (void)rc;

    fprintf(stderr, "[TAP-BRIDGE] Configured %s with %s\n", dev_name, ip_cidr);
    return 0;
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void print_usage(const char *prog)
{
    fprintf(stderr, "Usage: %s [options]\n"
            "  -s <shm_name>   ETH SHM name (default: /cosim_eth0)\n"
            "  -t <tap_name>   TAP device name (default: cosim0)\n"
            "  -i <ip/mask>    IP address for TAP (default: 10.0.0.1/24)\n"
            "  -n              Don't configure IP (TAP only)\n"
            "  -h              Show this help\n", prog);
}

int main(int argc, char *argv[])
{
    const char *shm_name = "/cosim_eth0";
    const char *tap_name = "cosim0";
    const char *ip_cidr = "10.0.0.1/24";
    int configure_ip = 1;
    int opt;

    while ((opt = getopt(argc, argv, "s:t:i:nh")) != -1) {
        switch (opt) {
        case 's': shm_name = optarg; break;
        case 't': tap_name = optarg; break;
        case 'i': ip_cidr = optarg; break;
        case 'n': configure_ip = 0; break;
        case 'h':
        default:
            print_usage(argv[0]);
            return (opt == 'h') ? 0 : 1;
        }
    }

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    /* Open TAP device */
    char actual_tap[IFNAMSIZ];
    int tap_fd = tap_open(tap_name, actual_tap, sizeof(actual_tap));
    if (tap_fd < 0) {
        fprintf(stderr, "[TAP-BRIDGE] Failed to open TAP device '%s'\n", tap_name);
        return 1;
    }
    fprintf(stderr, "[TAP-BRIDGE] TAP device: %s (fd=%d)\n", actual_tap, tap_fd);

    if (configure_ip)
        tap_configure(actual_tap, ip_cidr);

    /* Open ETH SHM as Role B (VCS is Role A, already created SHM) */
    eth_port_t port;
    memset(&port, 0, sizeof(port));
    if (eth_port_open(&port, shm_name, ETH_ROLE_B, 0) != 0) {
        fprintf(stderr, "[TAP-BRIDGE] Failed to open ETH SHM '%s' (is VCS running?)\n",
                shm_name);
        close(tap_fd);
        return 1;
    }
    fprintf(stderr, "[TAP-BRIDGE] ETH SHM connected: %s (role=B)\n", shm_name);

    /* Wait for peer (VCS/Role A) to be ready */
    fprintf(stderr, "[TAP-BRIDGE] Waiting for VCS peer...\n");
    while (g_running && !eth_shm_peer_ready(&port.shm, ETH_ROLE_B)) {
        usleep(100000);  /* 100ms */
    }
    if (!g_running) goto cleanup;
    fprintf(stderr, "[TAP-BRIDGE] VCS peer ready, starting bridge loop\n");

    /* Main bridge loop */
    uint64_t shm_to_tap = 0, tap_to_shm = 0;
    uint64_t last_stats = now_ns();

    while (g_running) {
        int did_work = 0;

        /* Direction 1: ETH SHM -> TAP (Guest TX -> Host) */
        eth_frame_t frame;
        while (eth_port_recv(&port, &frame, 0) == 0) {
            eth_port_tx_complete(&port);
            ssize_t nw = write(tap_fd, frame.data, frame.len);
            if (nw < 0 && errno != EAGAIN) {
                perror("[TAP-BRIDGE] TAP write");
            } else if (nw > 0) {
                shm_to_tap++;
                did_work = 1;
            }
        }

        /* Direction 2: TAP -> ETH SHM (Host -> Guest RX) */
        uint8_t buf[ETH_FRAME_MAX_DATA];
        ssize_t nr = read(tap_fd, buf, sizeof(buf));
        if (nr > 0) {
            eth_frame_t out;
            memset(&out, 0, sizeof(out));
            out.len = (uint16_t)nr;
            memcpy(out.data, buf, (size_t)nr);
            int rc = eth_port_send(&port, &out, now_ns());
            if (rc == 0) {
                tap_to_shm++;
                did_work = 1;
            } else if (rc == -1) {
                fprintf(stderr, "[TAP-BRIDGE] SHM TX ring full, dropping frame\n");
            }
        }

        /* Stats every 5 seconds */
        uint64_t now = now_ns();
        if (now - last_stats > 5000000000ULL) {
            fprintf(stderr, "[TAP-BRIDGE] Stats: SHM->TAP=%lu  TAP->SHM=%lu\n",
                    shm_to_tap, tap_to_shm);
            last_stats = now;
        }

        if (!did_work) {
            usleep(100);  /* 100us poll backoff */
        }
    }

cleanup:
    fprintf(stderr, "\n[TAP-BRIDGE] Shutting down (SHM->TAP=%lu TAP->SHM=%lu)\n",
            shm_to_tap, tap_to_shm);
    eth_port_close(&port);
    close(tap_fd);
    return 0;
}
