/* virtio_reg_test.c - Guest-side virtio register layout verification
 * Reads virtio-pci common_cfg, ISR, and device_cfg via BAR0 MMIO
 * and verifies the register values match expected defaults.
 *
 * Usage: /virtio_reg_test <BAR0_phys_addr>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>

#define PAGE_SIZE 4096

/* Virtio BAR0 offsets */
#define VIO_COMMON_OFF  0x1000
#define VIO_NOTIFY_OFF  0x2000
#define VIO_ISR_OFF     0x3000
#define VIO_DEVCFG_OFF  0x4000

static volatile void *bar0_map(int fd, uint64_t phys_addr, size_t size) {
    uint64_t page_base = phys_addr & ~(uint64_t)(PAGE_SIZE - 1);
    uint64_t page_offset = phys_addr & (PAGE_SIZE - 1);
    size_t map_size = (page_offset + size + PAGE_SIZE - 1) & ~(size_t)(PAGE_SIZE - 1);
    void *map = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page_base);
    if (map == MAP_FAILED) return NULL;
    return (volatile void *)((char *)map + page_offset);
}

static uint32_t rd32(volatile void *base, uint32_t off) {
    return *(volatile uint32_t *)((char *)base + off);
}
static uint16_t rd16(volatile void *base, uint32_t off) {
    return *(volatile uint16_t *)((char *)base + off);
}
static uint8_t rd8(volatile void *base, uint32_t off) {
    return *(volatile uint8_t *)((char *)base + off);
}
static void wr32(volatile void *base, uint32_t off, uint32_t val) {
    *(volatile uint32_t *)((char *)base + off) = val;
}
static void wr16(volatile void *base, uint32_t off, uint16_t val) {
    *(volatile uint16_t *)((char *)base + off) = val;
}
static void wr8(volatile void *base, uint32_t off, uint8_t val) {
    *(volatile uint8_t *)((char *)base + off) = val;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <BAR0_addr>\n", argv[0]);
        return 1;
    }

    uint64_t bar0_addr = strtoull(argv[1], NULL, 0);
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    /* Map full 64KB BAR */
    volatile void *bar0 = bar0_map(fd, bar0_addr, 0x10000);
    if (!bar0) { perror("mmap"); close(fd); return 1; }

    volatile void *common = (volatile void *)((char *)bar0 + VIO_COMMON_OFF);
    volatile void *devcfg = (volatile void *)((char *)bar0 + VIO_DEVCFG_OFF);

    int errors = 0;
    int tests = 0;

    printf("=== Virtio Register Test ===\n");
    printf("BAR0 = 0x%llX\n\n", (unsigned long long)bar0_addr);

    /* --- common_cfg reads --- */
    printf("[common_cfg] Reading defaults:\n");

    /* device_feature_select (offset 0x00, dword) */
    uint32_t feat_sel = rd32(common, 0x00);
    printf("  device_feature_select = %u", feat_sel);
    tests++; if (feat_sel == 0) printf(" PASS\n"); else { printf(" FAIL (expect 0)\n"); errors++; }

    /* device_feature (offset 0x04, dword) — depends on feat_sel */
    uint32_t feat = rd32(common, 0x04);
    printf("  device_feature[0]     = 0x%08X", feat);
    tests++; if (feat == 0x00010020) printf(" PASS\n"); else { printf(" FAIL (expect 0x00010020)\n"); errors++; }

    /* Read feature page 1 */
    wr32(common, 0x00, 1);  /* device_feature_select = 1 */
    feat = rd32(common, 0x04);
    printf("  device_feature[1]     = 0x%08X", feat);
    tests++; if (feat == 0x00000001) printf(" PASS (VERSION_1)\n"); else { printf(" FAIL (expect 0x00000001)\n"); errors++; }
    wr32(common, 0x00, 0);  /* restore */

    /* num_queues (offset 0x12, word) */
    uint16_t nq = rd16(common, 0x12);
    printf("  num_queues            = %u", nq);
    tests++; if (nq == 2) printf(" PASS\n"); else { printf(" FAIL (expect 2)\n"); errors++; }

    /* device_status (offset 0x14, byte) */
    uint8_t status = rd8(common, 0x14);
    printf("  device_status         = 0x%02X", status);
    tests++; if (status == 0) printf(" PASS\n"); else { printf(" FAIL (expect 0)\n"); errors++; }

    /* --- Simulate virtio negotiation --- */
    printf("\n[negotiation] Simulating virtio init:\n");

    /* Step 1: ACKNOWLEDGE */
    wr8(common, 0x14, 1);
    status = rd8(common, 0x14);
    printf("  ACKNOWLEDGE: status=0x%02X", status);
    tests++; if (status == 1) printf(" PASS\n"); else { printf(" FAIL\n"); errors++; }

    /* Step 2: DRIVER */
    wr8(common, 0x14, 1 | 2);
    status = rd8(common, 0x14);
    printf("  DRIVER:      status=0x%02X", status);
    tests++; if (status == 3) printf(" PASS\n"); else { printf(" FAIL\n"); errors++; }

    /* Step 3: Write driver features */
    wr32(common, 0x08, 0); /* driver_feature_select = 0 */
    wr32(common, 0x0C, 0x00010020); /* accept MAC + STATUS */
    wr32(common, 0x08, 1);
    wr32(common, 0x0C, 0x00000001); /* accept VERSION_1 */
    printf("  driver features written\n");

    /* Step 4: FEATURES_OK */
    wr8(common, 0x14, 1 | 2 | 8);
    status = rd8(common, 0x14);
    printf("  FEATURES_OK: status=0x%02X", status);
    tests++; if (status == 11) printf(" PASS\n"); else { printf(" FAIL\n"); errors++; }

    /* --- Queue setup --- */
    printf("\n[queue_setup] Configuring queues:\n");

    for (int q = 0; q < 2; q++) {
        wr16(common, 0x16, q);  /* queue_select */
        uint16_t qsize = rd16(common, 0x18);
        printf("  queue[%d] size=%u", q, qsize);
        tests++; if (qsize == 256) printf(" PASS\n"); else { printf(" FAIL (expect 256)\n"); errors++; }

        /* Write fake descriptor addresses */
        uint32_t fake_lo = 0x10000000 + q * 0x1000;
        wr32(common, 0x20, fake_lo);       /* queue_desc_lo */
        wr32(common, 0x24, 0);             /* queue_desc_hi */
        wr32(common, 0x28, fake_lo + 0x400); /* queue_driver_lo */
        wr32(common, 0x2C, 0);
        wr32(common, 0x30, fake_lo + 0x800); /* queue_device_lo */
        wr32(common, 0x34, 0);

        /* Enable queue */
        wr16(common, 0x1C, 1);
        uint16_t en = rd16(common, 0x1C);
        printf("  queue[%d] enable=%u", q, en);
        tests++; if (en == 1) printf(" PASS\n"); else { printf(" FAIL\n"); errors++; }

        /* Read back desc address */
        uint32_t desc_lo = rd32(common, 0x20);
        printf("  queue[%d] desc_lo=0x%08X", q, desc_lo);
        tests++; if (desc_lo == fake_lo) printf(" PASS\n"); else { printf(" FAIL\n"); errors++; }
    }

    /* Step 5: DRIVER_OK */
    wr8(common, 0x14, 1 | 2 | 4 | 8);
    status = rd8(common, 0x14);
    printf("\n  DRIVER_OK:   status=0x%02X", status);
    tests++; if (status == 15) printf(" PASS\n"); else { printf(" FAIL\n"); errors++; }

    /* --- device_cfg --- */
    printf("\n[device_cfg] Reading virtio-net config:\n");
    uint8_t mac[6];
    for (int i = 0; i < 6; i++)
        mac[i] = rd8(devcfg, i);
    printf("  MAC = %02X:%02X:%02X:%02X:%02X:%02X",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    tests++;
    if (mac[0]==0xDE && mac[1]==0xAD && mac[2]==0xBE && mac[3]==0xEF && mac[4]==0x00 && mac[5]==0x01)
        printf(" PASS\n");
    else { printf(" FAIL (expect DE:AD:BE:EF:00:01)\n"); errors++; }

    uint16_t link_status = rd16(devcfg, 0x06);
    printf("  link_status = 0x%04X", link_status);
    tests++; if (link_status == 1) printf(" PASS (link up)\n"); else { printf(" FAIL\n"); errors++; }

    /* --- ISR --- */
    printf("\n[ISR] Read ISR status:\n");
    uint32_t isr = rd32((volatile void *)((char *)bar0 + VIO_ISR_OFF), 0);
    printf("  ISR = 0x%08X (expect 0, read-clear)\n", isr);

    /* Summary */
    printf("\n=== Virtio Register Test: %d/%d passed, %s ===\n",
           tests - errors, tests, errors == 0 ? "ALL PASS" : "FAIL");

    close(fd);
    return errors ? 1 : 0;
}
