#ifndef ETH_MAC_DPI_H
#define ETH_MAC_DPI_H

#include <stdint.h>

/* DPI-C shim used by the VCS-side ETH MAC RTL.
 *
 * Call flow on VCS side (pseudocode):
 *
 *     vcs_eth_mac_init_dpi("/cosim-eth0", 0, 1);   // role=A, create=1
 *     // RTL MAC TX path calls:
 *     vcs_eth_mac_send_frame_dpi(data_ptr, len);
 *     // RTL MAC RX polling (each cycle or on idle):
 *     int got = vcs_eth_mac_poll_frame_dpi(buf, max_len);
 *     if (got > 0) { ... feed into MAC RX pipeline ... }
 *     // On reset:
 *     vcs_eth_mac_close_dpi();
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Open a port. role = 0 (A) or 1 (B). create != 0 if this side creates the SHM. */
int  vcs_eth_mac_init_dpi(const char *shm_name, int role, int create);

/* Send a frame. Returns 0 on success, -1 ring full, -2 FC blocked, -3 dropped.
 * data is svOpenArrayHandle when called via VCS DPI-C. */
int  vcs_eth_mac_send_frame_dpi(const void *data, int len);

/* Poll one frame non-blocking. Returns received length (>0) or 0 if empty,
 * -1 on error. data is svOpenArrayHandle from VCS DPI-C. */
int  vcs_eth_mac_poll_frame_dpi(const void *data, int max_len);

/* Link status helpers. */
void vcs_eth_mac_link_up_dpi(void);
void vcs_eth_mac_link_down_dpi(void);
int  vcs_eth_mac_peer_ready_dpi(void);

/* Configure link model (semantics mirror link_model_t fields). Can be called
 * any time; runtime state is not reset. */
void vcs_eth_mac_configure_link_dpi(
    uint32_t drop_rate_ppm,
    int      burst_drop_len,
    uint32_t rate_mbps,
    uint64_t latency_ns,
    uint32_t fc_window
);

/* Tear down the port and unlink the SHM if we created it. */
void vcs_eth_mac_close_dpi(void);

#ifdef __cplusplus
}
#endif

#endif
