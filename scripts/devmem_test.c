/* devmem_test.c - Minimal devmem for QEMU guest MMIO testing
 * Reads/writes physical addresses via /dev/mem mmap
 * Statically linked for use in minimal initramfs
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>

#define PAGE_SIZE 4096

static uint32_t mmio_read32(int fd, uint64_t phys_addr) {
    uint64_t page_base = phys_addr & ~(PAGE_SIZE - 1);
    uint64_t page_offset = phys_addr & (PAGE_SIZE - 1);

    void *map = mmap(NULL, PAGE_SIZE, PROT_READ, MAP_SHARED, fd, page_base);
    if (map == MAP_FAILED) {
        perror("mmap read");
        return 0xFFFFFFFF;
    }
    uint32_t val = *(volatile uint32_t *)((char *)map + page_offset);
    munmap(map, PAGE_SIZE);
    return val;
}

static void mmio_write32(int fd, uint64_t phys_addr, uint32_t val) {
    uint64_t page_base = phys_addr & ~(PAGE_SIZE - 1);
    uint64_t page_offset = phys_addr & (PAGE_SIZE - 1);

    void *map = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page_base);
    if (map == MAP_FAILED) {
        perror("mmap write");
        return;
    }
    *(volatile uint32_t *)((char *)map + page_offset) = val;
    munmap(map, PAGE_SIZE);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <phys_addr> [value_to_write]\n", argv[0]);
        return 1;
    }

    uint64_t addr = strtoull(argv[1], NULL, 0);
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    if (argc >= 3) {
        uint32_t val = strtoul(argv[2], NULL, 0);
        mmio_write32(fd, addr, val);
    } else {
        uint32_t val = mmio_read32(fd, addr);
        printf("0x%08X\n", val);
    }

    close(fd);
    return 0;
}
