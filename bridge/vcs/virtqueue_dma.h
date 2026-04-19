/* cosim-platform/bridge/vcs/virtqueue_dma.h
 * Virtqueue descriptor processing via DMA — header
 *
 * Called from VCS testbench when guest writes a doorbell (notify).
 * Processes TX queue descriptors, reads packet data via DMA,
 * forwards to ETH SHM, updates used ring.
 */
#ifndef VIRTQUEUE_DMA_H
#define VIRTQUEUE_DMA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Virtqueue descriptor (virtio spec 1.x, packed layout) */
struct virtq_desc {
    uint64_t addr;     /* Guest physical address */
    uint32_t len;      /* Buffer length */
    uint16_t flags;    /* NEXT, WRITE, INDIRECT */
    uint16_t next;     /* Next descriptor index (if NEXT set) */
};

#define VIRTQ_DESC_F_NEXT       1
#define VIRTQ_DESC_F_WRITE      2
#define VIRTQ_DESC_F_INDIRECT   4

#define VQ_MAX_SIZE    256
#define VQ_MAX_CHAIN   16
#define VQ_PKT_BUF     9216   /* jumbo frame support */

/* DPI-C: Configure queue ring addresses (called after DRIVER_OK) */
void vcs_vq_configure(int queue,
                       unsigned long long desc_gpa,
                       unsigned long long avail_gpa,
                       unsigned long long used_gpa,
                       int size);

/* DPI-C: Process TX queue — read descriptors, extract packets, forward to ETH.
 * Returns number of packets processed, or -1 on error. */
int vcs_vq_process_tx(void);

/* DPI-C: Process RX queue — poll ETH SHM for incoming frames,
 * write packet data to guest buffers via DMA, update used ring.
 * Returns number of packets injected, or -1 on error. */
int vcs_vq_process_rx(void);

/* DPI-C: Get TX/RX packet counters */
int vcs_vq_get_tx_count(void);
int vcs_vq_get_rx_count(void);

#ifdef __cplusplus
}
#endif

#endif /* VIRTQUEUE_DMA_H */
