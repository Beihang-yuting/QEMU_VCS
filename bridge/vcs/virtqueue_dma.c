/* cosim-platform/bridge/vcs/virtqueue_dma.c
 * Virtqueue descriptor processing via DMA
 *
 * When guest writes a doorbell (notify), VCS testbench calls these
 * functions to:
 *   TX: Read avail ring -> fetch descriptors -> DMA read packet -> ETH SHM
 *   RX: Poll ETH SHM -> DMA write packet to guest buffer -> update used ring
 */
#include "virtqueue_dma.h"
#include "../common/eth_types.h"
#include <string.h>
#include <stdio.h>

/* External: DMA helpers from bridge_vcs.c */
extern int bridge_dma_read_bytes(uint64_t host_addr, uint8_t *buf, uint32_t len);
extern int bridge_dma_write_bytes(uint64_t host_addr, const uint8_t *buf, uint32_t len);

/* External: ETH port send/recv — raw C-level wrappers (no svGetArrayPtr) */
extern int vcs_eth_mac_send_raw(const uint8_t *data, int len);
extern int vcs_eth_mac_recv_raw(uint8_t *data, int max_len);

/* External: MSI interrupt from bridge_vcs.c */
extern int bridge_vcs_raise_msi(int vector);

/* Per-queue state */
typedef struct {
    uint64_t desc_gpa;
    uint64_t avail_gpa;
    uint64_t used_gpa;
    uint16_t size;
    uint16_t last_avail;
    uint16_t last_used;
    int      configured;
} vq_state_t;

static vq_state_t vq[2];   /* 0=RX, 1=TX */
static int tx_pkt_count = 0;
static int rx_pkt_count = 0;

/* ========== DPI-C: Configure queue ==========
 * 幂等：若参数与当前 cache 完全一致且已 configured，则直接 return。
 * 否则更新 GPA/size 并重置 last_avail/last_used（只在 GPA 真正变化时重置）。
 * 这样 SV 侧可以每次 notify 都调用 configure_vq_rings，不会因为"重复
 * configure 清零 ring 位置"破坏 virtio 语义；Guest 若在 soft-reset 后重
 * 配 vring 到新地址，此处会检测到差异并重置。 */
void vcs_vq_configure(int queue,
                       unsigned long long desc_gpa,
                       unsigned long long avail_gpa,
                       unsigned long long used_gpa,
                       int size) {
    if (queue < 0 || queue > 1) return;

    /* 参数与 cache 完全一致 → no-op */
    if (vq[queue].configured &&
        vq[queue].desc_gpa  == (uint64_t)desc_gpa &&
        vq[queue].avail_gpa == (uint64_t)avail_gpa &&
        vq[queue].used_gpa  == (uint64_t)used_gpa &&
        vq[queue].size      == (uint16_t)size) {
        return;
    }

    vq[queue].desc_gpa   = desc_gpa;
    vq[queue].avail_gpa  = avail_gpa;
    vq[queue].used_gpa   = used_gpa;
    vq[queue].size       = (uint16_t)size;
    vq[queue].last_avail = 0;
    vq[queue].last_used  = 0;
    vq[queue].configured = 1;
    fprintf(stderr, "[VQ] Queue %d (re)configured: desc=0x%llx avail=0x%llx used=0x%llx size=%d\n",
            queue, (unsigned long long)desc_gpa, (unsigned long long)avail_gpa,
            (unsigned long long)used_gpa, size);
}

/* ========== TX queue processing ========== */
int vcs_vq_process_tx(void) {
    int q = 1;
    if (!vq[q].configured) {
        fprintf(stderr, "[VQ-TX] Queue not configured\n");
        return -1;
    }

    /* Read avail ring header: flags(2) + idx(2) */
    uint8_t avail_hdr[4];
    if (bridge_dma_read_bytes(vq[q].avail_gpa, avail_hdr, 4) < 0) {
        fprintf(stderr, "[VQ-TX] Failed to read avail header\n");
        return -1;
    }
    uint16_t avail_idx;
    memcpy(&avail_idx, &avail_hdr[2], 2);

    int processed = 0;

    while (vq[q].last_avail != avail_idx) {
        /* Read avail ring entry: ring[last_avail % size] */
        uint16_t ring_pos = vq[q].last_avail % vq[q].size;
        uint64_t entry_gpa = vq[q].avail_gpa + 4 + (uint64_t)ring_pos * 2;

        uint8_t entry_buf[2];
        if (bridge_dma_read_bytes(entry_gpa, entry_buf, 2) < 0) {
            fprintf(stderr, "[VQ-TX] Failed to read avail entry\n");
            return -1;
        }
        uint16_t head_idx;
        memcpy(&head_idx, entry_buf, 2);

        /* Traverse descriptor chain */
        uint8_t pkt_buf[VQ_PKT_BUF];
        int pkt_len = 0;
        int chain_n = 0;
        uint16_t cur = head_idx;
        int has_next = 1;
        /* virtio-net header size: 12 bytes for VERSION_1 */
        int hdr_remaining = 12;

        while (has_next && chain_n < VQ_MAX_CHAIN) {
            /* Read descriptor (16 bytes) */
            uint64_t d_gpa = vq[q].desc_gpa + (uint64_t)cur * 16;
            struct virtq_desc desc;
            if (bridge_dma_read_bytes(d_gpa, (uint8_t *)&desc, 16) < 0) {
                fprintf(stderr, "[VQ-TX] Failed to read desc[%d]\n", cur);
                return -1;
            }

            fprintf(stderr, "[VQ-TX] desc[%d]: addr=0x%llx len=%u flags=0x%x next=%d\n",
                    cur, (unsigned long long)desc.addr, desc.len, desc.flags, desc.next);

            /* Skip virtio-net header bytes, then read packet data */
            uint64_t buf_addr = desc.addr;
            uint32_t buf_len = desc.len;

            if (hdr_remaining > 0) {
                if (buf_len <= (uint32_t)hdr_remaining) {
                    /* Entire descriptor is header */
                    fprintf(stderr, "[VQ-TX] Skipping header desc (%u bytes)\n", buf_len);
                    hdr_remaining -= (int)buf_len;
                    buf_len = 0;
                } else {
                    /* Partial header in this descriptor */
                    fprintf(stderr, "[VQ-TX] Skipping %d header bytes, reading %u data bytes\n",
                            hdr_remaining, buf_len - (uint32_t)hdr_remaining);
                    buf_addr += (uint32_t)hdr_remaining;
                    buf_len  -= (uint32_t)hdr_remaining;
                    hdr_remaining = 0;
                }
            }

            if (buf_len > 0) {
                uint32_t to_read = buf_len;
                if (pkt_len + (int)to_read > VQ_PKT_BUF)
                    to_read = (uint32_t)(VQ_PKT_BUF - pkt_len);
                if (bridge_dma_read_bytes(buf_addr, pkt_buf + pkt_len, to_read) < 0) {
                    fprintf(stderr, "[VQ-TX] Failed to read pkt data\n");
                    return -1;
                }
                pkt_len += (int)to_read;
            }

            has_next = (desc.flags & VIRTQ_DESC_F_NEXT) ? 1 : 0;
            cur = desc.next;
            chain_n++;
        }

        /* Forward packet to ETH SHM */
        if (pkt_len > 0) {
            /* Hex dump first 48 bytes for debugging */
            {
                int i;
                fprintf(stderr, "[VQ-TX] pkt_len=%d hex:", pkt_len);
                for (i = 0; i < pkt_len && i < 48; i++)
                    fprintf(stderr, " %02x", pkt_buf[i]);
                fprintf(stderr, "\n");
            }

            int rc = vcs_eth_mac_send_raw(pkt_buf, pkt_len);
            if (rc == 0) {
                fprintf(stderr, "[VQ-TX] Forwarded %d bytes to ETH SHM (pkt #%d)\n",
                        pkt_len, tx_pkt_count + 1);
            } else {
                fprintf(stderr, "[VQ-TX] ETH send failed (rc=%d)\n", rc);
            }
        }

        /* Write used ring entry: id(4) + len(4) */
        uint16_t used_pos = vq[q].last_used % vq[q].size;
        uint64_t used_entry_gpa = vq[q].used_gpa + 4 + (uint64_t)used_pos * 8;
        uint8_t used_entry[8];
        uint32_t id32 = (uint32_t)head_idx;
        uint32_t len32 = 0;  /* TX: device doesn't write data back */
        memcpy(&used_entry[0], &id32, 4);
        memcpy(&used_entry[4], &len32, 4);
        if (bridge_dma_write_bytes(used_entry_gpa, used_entry, 8) < 0) {
            fprintf(stderr, "[VQ-TX] Failed to write used entry\n");
            return -1;
        }

        vq[q].last_avail++;
        vq[q].last_used++;
        processed++;
        tx_pkt_count++;
    }

    /* Update used ring idx */
    if (processed > 0) {
        uint64_t used_idx_gpa = vq[q].used_gpa + 2;
        uint16_t new_idx = vq[q].last_used;
        if (bridge_dma_write_bytes(used_idx_gpa, (uint8_t *)&new_idx, 2) < 0) {
            fprintf(stderr, "[VQ-TX] Failed to update used idx\n");
            return -1;
        }
        fprintf(stderr, "[VQ-TX] Processed %d descriptors, used_idx=%d, total_tx=%d\n",
                processed, new_idx, tx_pkt_count);
    }

    return processed;
}

/* ========== RX queue processing ========== */
static int rx_poll_empty_count = 0;
int vcs_vq_process_rx(void) {
    int q = 0;
    if (!vq[q].configured) return 0;

    /* Poll ETH SHM for incoming frame */
    uint8_t frame_buf[VQ_PKT_BUF];
    int frame_len = vcs_eth_mac_recv_raw(frame_buf, VQ_PKT_BUF);
    if (frame_len <= 0) {
        rx_poll_empty_count++;
        if ((rx_poll_empty_count % 5000) == 0) {
            fprintf(stderr, "[VQ-RX] heartbeat: empty_polls=%d total_rx=%d\n",
                    rx_poll_empty_count, rx_pkt_count);
        }
        return 0;
    }
    rx_poll_empty_count = 0;

    /* Read avail ring header */
    uint8_t avail_hdr[4];
    if (bridge_dma_read_bytes(vq[q].avail_gpa, avail_hdr, 4) < 0) {
        fprintf(stderr, "[VQ-RX] Failed to read avail header\n");
        return -1;
    }
    uint16_t avail_idx;
    memcpy(&avail_idx, &avail_hdr[2], 2);

    if (vq[q].last_avail == avail_idx) {
        fprintf(stderr, "[VQ-RX] No RX buffers available (avail_idx=%d)\n", avail_idx);
        return 0;
    }

    /* Get descriptor head from avail ring */
    uint16_t ring_pos = vq[q].last_avail % vq[q].size;
    uint64_t entry_gpa = vq[q].avail_gpa + 4 + (uint64_t)ring_pos * 2;
    uint8_t entry_buf[2];
    if (bridge_dma_read_bytes(entry_gpa, entry_buf, 2) < 0)
        return -1;
    uint16_t head_idx;
    memcpy(&head_idx, entry_buf, 2);

    /* Traverse descriptor chain — write virtio-net header + packet data */
    uint16_t cur = head_idx;
    int remaining = frame_len;
    int chain_n = 0;
    int has_next = 1;
    uint32_t total_written = 0;

    /* Prepare virtio-net header (12 bytes for VERSION_1, all zeros = no offload) */
    uint8_t vnet_hdr[12];
    memset(vnet_hdr, 0, sizeof(vnet_hdr));
    int hdr_written = 0;

    while (has_next && chain_n < VQ_MAX_CHAIN) {
        uint64_t d_gpa = vq[q].desc_gpa + (uint64_t)cur * 16;
        struct virtq_desc desc;
        if (bridge_dma_read_bytes(d_gpa, (uint8_t *)&desc, 16) < 0)
            return -1;

        fprintf(stderr, "[VQ-RX] desc[%d]: addr=0x%llx len=%u flags=0x%x next=%d\n",
                cur, (unsigned long long)desc.addr, desc.len, desc.flags, desc.next);

        if (!(desc.flags & VIRTQ_DESC_F_WRITE)) {
            /* RX descriptors must be WRITE — skip read-only */
            has_next = (desc.flags & VIRTQ_DESC_F_NEXT) ? 1 : 0;
            cur = desc.next;
            chain_n++;
            continue;
        }

        if (!hdr_written) {
            /* Write virtio-net header to first writable descriptor */
            uint32_t hdr_len = (desc.len < 12) ? desc.len : 12;
            if (bridge_dma_write_bytes(desc.addr, vnet_hdr, hdr_len) < 0)
                return -1;
            total_written += hdr_len;

            /* If descriptor has room for data after header */
            uint32_t data_space = desc.len - hdr_len;
            if (data_space > 0 && remaining > 0) {
                uint32_t to_write = ((uint32_t)remaining < data_space) ?
                                    (uint32_t)remaining : data_space;
                if (bridge_dma_write_bytes(desc.addr + hdr_len,
                                           frame_buf + (frame_len - remaining),
                                           to_write) < 0)
                    return -1;
                remaining -= (int)to_write;
                total_written += to_write;
            }
            hdr_written = 1;
        } else {
            /* Subsequent descriptors: write packet data */
            if (remaining > 0) {
                uint32_t to_write = ((uint32_t)remaining < desc.len) ?
                                    (uint32_t)remaining : desc.len;
                if (bridge_dma_write_bytes(desc.addr,
                                           frame_buf + (frame_len - remaining),
                                           to_write) < 0)
                    return -1;
                remaining -= (int)to_write;
                total_written += to_write;
            }
        }

        has_next = (desc.flags & VIRTQ_DESC_F_NEXT) ? 1 : 0;
        cur = desc.next;
        chain_n++;
    }

    /* Write used ring entry */
    uint16_t used_pos = vq[q].last_used % vq[q].size;
    uint64_t used_entry_gpa = vq[q].used_gpa + 4 + (uint64_t)used_pos * 8;
    uint8_t used_entry[8];
    uint32_t id32 = (uint32_t)head_idx;
    memcpy(&used_entry[0], &id32, 4);
    memcpy(&used_entry[4], &total_written, 4);
    if (bridge_dma_write_bytes(used_entry_gpa, used_entry, 8) < 0)
        return -1;

    vq[q].last_avail++;
    vq[q].last_used++;

    /* Update used ring idx */
    uint64_t used_idx_gpa = vq[q].used_gpa + 2;
    uint16_t new_idx = vq[q].last_used;
    if (bridge_dma_write_bytes(used_idx_gpa, (uint8_t *)&new_idx, 2) < 0)
        return -1;

    rx_pkt_count++;
    fprintf(stderr, "[VQ-RX] Injected %d bytes (total_written=%u), rx_pkt #%d\n",
            frame_len, total_written, rx_pkt_count);
    /* Hex dump received frame for debugging */
    {
        int i;
        fprintf(stderr, "[VQ-RX] frame hex:");
        for (i = 0; i < frame_len && i < 48; i++)
            fprintf(stderr, " %02x", frame_buf[i]);
        fprintf(stderr, "\n");
    }

    /* NOTE: Do NOT raise MSI here — there is a race condition.
     * ISR must be set in SV (pcie_ep_stub) BEFORE the interrupt reaches QEMU,
     * otherwise the guest reads ISR=0 and drops the event.
     * tb_top.sv handles: isr_set → bridge_vcs_raise_msi(0) after this returns. */

    return 1;
}

/* ========== Counters ========== */
int vcs_vq_get_tx_count(void) { return tx_pkt_count; }
int vcs_vq_get_rx_count(void) { return rx_pkt_count; }
