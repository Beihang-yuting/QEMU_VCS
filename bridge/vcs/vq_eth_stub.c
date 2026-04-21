/* vq_eth_stub.c — stub implementations for virtqueue + eth_mac DPI functions
 * These are not needed for P1 VIP smoke test but must link. */

#include <stdio.h>

void vcs_vq_configure(int queue, long long desc_gpa, long long avail_gpa,
                      long long used_gpa, int size) {
    (void)queue; (void)desc_gpa; (void)avail_gpa; (void)used_gpa; (void)size;
}

int vcs_vq_process_tx(void) { return 0; }
int vcs_vq_process_rx(void) { return 0; }
int vcs_vq_get_tx_count(void) { return 0; }
int vcs_vq_get_rx_count(void) { return 0; }

int vcs_eth_mac_init_dpi(const char *shm_name, int role, int create_shm) {
    (void)shm_name; (void)role; (void)create_shm;
    return 0;
}

int vcs_eth_mac_send_frame_dpi(const unsigned char *data, int len) {
    (void)data; (void)len;
    return 0;
}

int vcs_eth_mac_poll_frame_dpi(unsigned char *data, int max_len) {
    (void)data; (void)max_len;
    return 0;
}

void vcs_eth_mac_close_dpi(void) {}

int vcs_eth_mac_peer_ready_dpi(void) { return 0; }

/* eth_mac_send_raw — called from legacy tb_top.sv eth path */
int vcs_eth_mac_send_raw(const unsigned char *frame, int len) {
    (void)frame; (void)len;
    return 0;
}
