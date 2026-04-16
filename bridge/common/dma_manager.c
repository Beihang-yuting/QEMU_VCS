#include "dma_manager.h"
#include <string.h>

void dma_mgr_init(dma_mgr_t *mgr, void *base, uint32_t total_size) {
    mgr->base = (uint8_t *)base;
    mgr->total_size = total_size;
    atomic_store(&mgr->next_free, 0);
    atomic_store(&mgr->used_bytes, 0);
}

uint32_t dma_mgr_alloc(dma_mgr_t *mgr, uint32_t size) {
    if (size == 0) return DMA_MGR_INVALID;
    uint32_t aligned = (size + DMA_MGR_ALIGN - 1) & ~(DMA_MGR_ALIGN - 1);

    uint32_t old_off, new_off;
    do {
        old_off = atomic_load(&mgr->next_free);
        new_off = old_off + aligned;
        if (new_off > mgr->total_size) return DMA_MGR_INVALID;
    } while (!atomic_compare_exchange_weak(&mgr->next_free, &old_off, new_off));

    atomic_fetch_add(&mgr->used_bytes, aligned);
    return old_off;
}

void dma_mgr_free(dma_mgr_t *mgr, uint32_t offset, uint32_t size) {
    (void)offset;
    uint32_t aligned = (size + DMA_MGR_ALIGN - 1) & ~(DMA_MGR_ALIGN - 1);
    atomic_fetch_sub(&mgr->used_bytes, aligned);
}

void *dma_mgr_ptr(dma_mgr_t *mgr, uint32_t offset) {
    if (offset >= mgr->total_size) return NULL;
    return mgr->base + offset;
}
