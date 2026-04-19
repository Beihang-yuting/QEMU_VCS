/* dma_test.c - Guest-side DMA test helper
 * Allocates a page, fills it with known pattern, writes the physical address
 * to EP stub register so VCS can DMA-read it, then verifies DMA-write back.
 *
 * EP Stub DMA register map (added for Phase 0):
 *   0x50  DMA_ADDR_LO    - low 32 bits of guest physical address
 *   0x54  DMA_ADDR_HI    - high 32 bits of guest physical address
 *   0x58  DMA_LEN        - length in bytes
 *   0x5C  DMA_DOORBELL   - write 1=start DMA read test, 2=start DMA write test
 *   0x60  DMA_STATUS     - 0=idle, 1=pass, 2=fail
 *
 * Usage: /dma_test <BAR0_phys_addr>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>

#define PAGE_SIZE 4096
#define DMA_TEST_SIZE 64

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
        fprintf(stderr, "Usage: %s <BAR0_addr>\n", argv[0]);
        return 1;
    }

    uint64_t bar0_addr = strtoull(argv[1], NULL, 0);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    volatile uint32_t *bar0 = mmio_map(fd, bar0_addr, 0x200);
    if (!bar0) {
        close(fd);
        return 1;
    }

    printf("DMA Test: BAR0=0x%llX\n", (unsigned long long)bar0_addr);

    /* Allocate a page for DMA data */
    void *dma_buf = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (dma_buf == MAP_FAILED) {
        perror("mmap dma_buf");
        close(fd);
        return 1;
    }

    /* Touch the page to ensure it's mapped */
    memset(dma_buf, 0, PAGE_SIZE);

    /* Get physical address via pagemap */
    int pm_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pm_fd < 0) {
        perror("open pagemap");
        close(fd);
        return 1;
    }

    uint64_t virt_pfn = (uint64_t)dma_buf / PAGE_SIZE;
    uint64_t pm_entry;
    if (pread(pm_fd, &pm_entry, 8, virt_pfn * 8) != 8) {
        perror("pread pagemap");
        close(pm_fd);
        close(fd);
        return 1;
    }
    close(pm_fd);

    if (!(pm_entry & (1ULL << 63))) {
        fprintf(stderr, "ERROR: page not present in pagemap\n");
        close(fd);
        return 1;
    }

    uint64_t phys_pfn = pm_entry & ((1ULL << 55) - 1);
    uint64_t phys_addr = phys_pfn * PAGE_SIZE;
    printf("  DMA buffer: virt=%p phys=0x%llX\n", dma_buf, (unsigned long long)phys_addr);

    /* ======== Test 1: DMA Read (VCS reads from guest) ======== */
    printf("\n=== Test 1: DMA Read (VCS reads from guest memory) ===\n");

    /* Fill buffer with pattern: byte[i] = 0xA0 + i */
    uint8_t *buf = (uint8_t *)dma_buf;
    for (int i = 0; i < DMA_TEST_SIZE; i++) {
        buf[i] = (uint8_t)(0xA0 + (i & 0x3F));
    }
    printf("  [1] Buffer filled with pattern (0xA0+i)\n");

    /* Tell EP stub the guest physical address and length */
    reg_write(bar0, 0x50, (uint32_t)(phys_addr & 0xFFFFFFFF));
    reg_write(bar0, 0x54, (uint32_t)(phys_addr >> 32));
    reg_write(bar0, 0x58, DMA_TEST_SIZE);
    printf("  [2] DMA addr=0x%llX len=%d written to EP regs\n",
           (unsigned long long)phys_addr, DMA_TEST_SIZE);

    /* Trigger DMA read test */
    reg_write(bar0, 0x5C, 1);
    printf("  [3] DMA_DOORBELL=1 (trigger DMA read test)\n");

    /* Poll DMA_STATUS */
    uint32_t status;
    for (int i = 0; i < 100; i++) {
        status = reg_read(bar0, 0x60);
        if (status != 0) break;
        usleep(10000);  /* 10ms */
    }
    printf("  [4] DMA_STATUS = %u (%s)\n", status,
           status == 1 ? "PASS" : status == 2 ? "FAIL" : "timeout");

    int test1_pass = (status == 1);

    /* ======== Test 2: DMA Write (VCS writes to guest) ======== */
    printf("\n=== Test 2: DMA Write (VCS writes to guest memory) ===\n");

    /* Clear buffer */
    memset(dma_buf, 0, DMA_TEST_SIZE);
    printf("  [1] Buffer cleared\n");

    /* Reset status */
    reg_write(bar0, 0x60, 0);

    /* Trigger DMA write test */
    reg_write(bar0, 0x5C, 2);
    printf("  [2] DMA_DOORBELL=2 (trigger DMA write test)\n");

    /* Poll DMA_STATUS */
    for (int i = 0; i < 100; i++) {
        status = reg_read(bar0, 0x60);
        if (status != 0) break;
        usleep(10000);
    }
    printf("  [3] DMA_STATUS = %u\n", status);

    /* Verify VCS wrote expected pattern: byte[i] = 0xB0 + i */
    int errors = 0;
    for (int i = 0; i < DMA_TEST_SIZE; i++) {
        uint8_t expected = (uint8_t)(0xB0 + (i & 0x3F));
        if (buf[i] != expected) {
            if (errors < 5)
                printf("  MISMATCH byte[%d]: got 0x%02X expect 0x%02X\n",
                       i, buf[i], expected);
            errors++;
        }
    }
    if (errors == 0)
        printf("  [4] Pattern verify: PASS (%d bytes)\n", DMA_TEST_SIZE);
    else
        printf("  [4] Pattern verify: FAIL (%d mismatches)\n", errors);

    int test2_pass = (status == 1 && errors == 0);

    printf("\n=== DMA Test Summary: %s ===\n",
           (test1_pass && test2_pass) ? "ALL PASS" : "FAIL");

    close(fd);
    return (test1_pass && test2_pass) ? 0 : 1;
}
