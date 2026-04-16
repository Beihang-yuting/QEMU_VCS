#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "dma_manager.h"

static void test_alloc_free(void) {
    uint8_t backing[4096];
    dma_mgr_t mgr;
    dma_mgr_init(&mgr, backing, sizeof(backing));

    uint32_t off1 = dma_mgr_alloc(&mgr, 128);
    assert(off1 != DMA_MGR_INVALID);
    assert(off1 % 64 == 0);

    uint32_t off2 = dma_mgr_alloc(&mgr, 256);
    assert(off2 != DMA_MGR_INVALID);
    assert(off2 != off1);
    assert(off2 >= off1 + 128);

    dma_mgr_free(&mgr, off1, 128);
    dma_mgr_free(&mgr, off2, 256);

    uint32_t off3 = dma_mgr_alloc(&mgr, 128);
    assert(off3 != DMA_MGR_INVALID);

    printf("  PASS: test_alloc_free\n");
}

static void test_exhaustion(void) {
    uint8_t backing[512];
    dma_mgr_t mgr;
    dma_mgr_init(&mgr, backing, sizeof(backing));

    uint32_t a = dma_mgr_alloc(&mgr, 256);
    uint32_t b = dma_mgr_alloc(&mgr, 256);
    assert(a != DMA_MGR_INVALID);
    assert(b != DMA_MGR_INVALID);

    uint32_t c = dma_mgr_alloc(&mgr, 64);
    assert(c == DMA_MGR_INVALID);

    dma_mgr_free(&mgr, a, 256);
    dma_mgr_free(&mgr, b, 256);

    printf("  PASS: test_exhaustion\n");
}

static void test_ptr_from_offset(void) {
    uint8_t backing[1024];
    memset(backing, 0xCC, sizeof(backing));
    dma_mgr_t mgr;
    dma_mgr_init(&mgr, backing, sizeof(backing));

    uint32_t off = dma_mgr_alloc(&mgr, 64);
    void *p = dma_mgr_ptr(&mgr, off);
    assert(p == backing + off);

    memset(p, 0xAB, 64);
    assert(((uint8_t *)backing)[off] == 0xAB);

    printf("  PASS: test_ptr_from_offset\n");
}

int main(void) {
    printf("=== dma_manager tests ===\n");
    test_alloc_free();
    test_exhaustion();
    test_ptr_from_offset();
    printf("=== ALL PASSED ===\n");
    return 0;
}
