#include "eth_mac_dpi.h"
#include "eth_port.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "svdpi.h"

/* The DPI-C shim owns a single eth_port per VCS process. VCS typically needs
 * only one ETH instance at a time (the simulated MAC), so a singleton
 * is sufficient. */
static eth_port_t g_port;
static int        g_opened = 0;

int vcs_eth_mac_init_dpi(const char *shm_name, int role, int create)
{
    if (g_opened) {
        fprintf(stderr, "vcs_eth_mac_init_dpi: already opened\n");
        return -1;
    }
    if (role != 0 && role != 1) return -1;
    memset(&g_port, 0, sizeof(g_port));
    if (eth_port_open(&g_port, shm_name, (eth_role_t)role, create) != 0) {
        return -1;
    }
    g_opened = 1;
    return 0;
}

int vcs_eth_mac_send_frame_dpi(const void *data, int len)
{
    if (!g_opened || !data || len <= 0 || len > (int)ETH_FRAME_MAX_DATA) return -1;
    const uint8_t *ptr = (const uint8_t *)svGetArrayPtr((void *)(uintptr_t)data);
    if (!ptr) return -1;
    eth_frame_t f = {0};
    f.len = (uint16_t)len;
    memcpy(f.data, ptr, (size_t)len);
    return eth_port_send(&g_port, &f, 0);
}

int vcs_eth_mac_poll_frame_dpi(const void *data, int max_len)
{
    if (!g_opened || !data || max_len <= 0) return -1;
    uint8_t *ptr = (uint8_t *)svGetArrayPtr((void *)(uintptr_t)data);
    if (!ptr) return -1;
    eth_frame_t f;
    int rc = eth_port_recv(&g_port, &f, 0);
    if (rc != 0) return 0;  /* empty */
    eth_port_tx_complete(&g_port);
    int copy = f.len < (uint16_t)max_len ? f.len : max_len;
    memcpy(ptr, f.data, (size_t)copy);
    return copy;
}

void vcs_eth_mac_link_up_dpi(void)
{
    if (g_opened && g_port.shm.ctrl) g_port.shm.ctrl->link_up = 1;
}

void vcs_eth_mac_link_down_dpi(void)
{
    if (g_opened && g_port.shm.ctrl) g_port.shm.ctrl->link_up = 0;
}

int vcs_eth_mac_peer_ready_dpi(void)
{
    if (!g_opened) return 0;
    return eth_shm_peer_ready(&g_port.shm, g_port.role);
}

void vcs_eth_mac_configure_link_dpi(uint32_t drop_rate_ppm,
                                     int burst_drop_len,
                                     uint32_t rate_mbps,
                                     uint64_t latency_ns,
                                     uint32_t fc_window)
{
    if (!g_opened) return;
    g_port.link.drop_rate_ppm  = drop_rate_ppm;
    g_port.link.burst_drop_len = (uint16_t)(burst_drop_len < 0 ? 0 : burst_drop_len);
    g_port.link.rate_mbps      = rate_mbps;
    g_port.link.latency_ns     = latency_ns;
    g_port.link.fc_window      = fc_window;
}

/* Raw C-level send/recv — called from virtqueue_dma.c (no svGetArrayPtr) */
int vcs_eth_mac_send_raw(const uint8_t *data, int len)
{
    if (!g_opened || !data || len <= 0 || len > (int)ETH_FRAME_MAX_DATA) return -1;
    eth_frame_t f = {0};
    f.len = (uint16_t)len;
    memcpy(f.data, data, (size_t)len);
    return eth_port_send(&g_port, &f, 0);
}

int vcs_eth_mac_recv_raw(uint8_t *data, int max_len)
{
    if (!g_opened || !data || max_len <= 0) return -1;
    eth_frame_t f;
    int rc = eth_port_recv(&g_port, &f, 0);
    if (rc != 0) return 0;  /* empty */
    eth_port_tx_complete(&g_port);
    int copy = f.len < (uint16_t)max_len ? f.len : max_len;
    memcpy(data, f.data, (size_t)copy);
    return copy;
}

void vcs_eth_mac_close_dpi(void)
{
    if (!g_opened) return;
    eth_port_close(&g_port);
    memset(&g_port, 0, sizeof(g_port));
    g_opened = 0;
}
