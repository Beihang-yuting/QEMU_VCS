/* nic_tx_test.c - Guest-side NIC TX simulation test
 * Writes packet data to EP stub's TX buffer via MMIO,
 * triggers TX doorbell, and verifies completion.
 *
 * Usage: /nic_tx_test <BAR0_phys_addr> [packet_size] [num_packets]
 *   packet_size: 16-256 bytes (default 64)
 *   num_packets: 1-10 (default 3)
 *
 * EP Stub register map:
 *   0x00-0x3C   general regs
 *   0x40        TX_LEN
 *   0x44        TX_DOORBELL (write=trigger, read=tx_count)
 *   0x48        TX_STATUS (0=idle, 1=done)
 *   0x100-0x1FC TX_BUF[0..63] (256 bytes)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>

#define PAGE_SIZE 4096

/* Map a physical region and return pointer to start */
static volatile uint32_t *mmio_map(int fd, uint64_t phys_addr, size_t size) {
    uint64_t page_base = phys_addr & ~(uint64_t)(PAGE_SIZE - 1);
    uint64_t page_offset = phys_addr & (PAGE_SIZE - 1);
    size_t map_size = page_offset + size;
    map_size = (map_size + PAGE_SIZE - 1) & ~(size_t)(PAGE_SIZE - 1);

    void *map = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page_base);
    if (map == MAP_FAILED) {
        perror("mmap");
        return NULL;
    }
    return (volatile uint32_t *)((char *)map + page_offset);
}

static uint32_t reg_read(volatile uint32_t *base, uint32_t offset) {
    return base[offset / 4];
}

static void reg_write(volatile uint32_t *base, uint32_t offset, uint32_t val) {
    base[offset / 4] = val;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <BAR0_addr> [pkt_size] [num_pkts]\n", argv[0]);
        return 1;
    }

    uint64_t bar0_addr = strtoull(argv[1], NULL, 0);
    int pkt_size = (argc >= 3) ? atoi(argv[2]) : 64;
    int num_pkts = (argc >= 4) ? atoi(argv[3]) : 3;

    if (pkt_size < 4) pkt_size = 4;
    if (pkt_size > 256) pkt_size = 256;
    if (num_pkts < 1) num_pkts = 1;
    if (num_pkts > 10) num_pkts = 10;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    /* Map BAR0: need at least 0x200 bytes (TX_BUF ends at 0x1FC+4) */
    volatile uint32_t *bar0 = mmio_map(fd, bar0_addr, 0x200);
    if (!bar0) {
        close(fd);
        return 1;
    }

    printf("NIC TX Test: BAR0=0x%llX pkt_size=%d num_pkts=%d\n",
           (unsigned long long)bar0_addr, pkt_size, num_pkts);

    /* Verify basic register access first */
    uint32_t reg0 = reg_read(bar0, 0x00);
    printf("  Sanity check: reg[0] = 0x%08X\n", reg0);

    /* Read baseline tx_count (EP stub counter is cumulative across invocations) */
    uint32_t base_count = reg_read(bar0, 0x44);
    printf("  Baseline TX_COUNT = %u\n", base_count);

    int pass_count = 0;

    for (int p = 0; p < num_pkts; p++) {
        printf("\n--- Packet %d/%d (size=%d) ---\n", p + 1, num_pkts, pkt_size);

        /* Step 1: Fill TX buffer with pattern: byte[i] = (i & 0xFF) */
        int words = (pkt_size + 3) / 4;
        for (int i = 0; i < words; i++) {
            uint32_t word = 0;
            for (int b = 0; b < 4; b++) {
                int byte_idx = i * 4 + b;
                if (byte_idx < pkt_size) {
                    word |= (uint32_t)(byte_idx & 0xFF) << (b * 8);
                }
            }
            reg_write(bar0, 0x100 + i * 4, word);
        }
        printf("  [1] TX buffer filled (%d words)\n", words);

        /* Step 2: Write TX_LEN */
        reg_write(bar0, 0x40, (uint32_t)pkt_size);
        printf("  [2] TX_LEN = %d\n", pkt_size);

        /* Step 3: Write TX_DOORBELL to trigger send */
        reg_write(bar0, 0x44, 1);
        printf("  [3] TX_DOORBELL written (trigger send)\n");

        /* Step 4: Read TX_STATUS */
        uint32_t status = reg_read(bar0, 0x48);
        printf("  [4] TX_STATUS = %u (%s)\n", status, status == 1 ? "done" : "unexpected");

        /* Step 5: Read TX_DOORBELL (returns tx_count) */
        uint32_t count = reg_read(bar0, 0x44);
        uint32_t expected_count = base_count + (uint32_t)(p + 1);
        printf("  [5] TX_COUNT = %u (expect %u)\n", count, expected_count);

        if (status == 1 && count == expected_count) {
            printf("  RESULT: PASS\n");
            pass_count++;
        } else {
            printf("  RESULT: FAIL\n");
        }
    }

    printf("\n=== NIC TX Test Summary: %d/%d passed ===\n", pass_count, num_pkts);

    close(fd);
    return (pass_count == num_pkts) ? 0 : 1;
}
