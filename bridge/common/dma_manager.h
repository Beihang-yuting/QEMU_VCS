#ifndef DMA_MANAGER_H
#define DMA_MANAGER_H

#include <stdint.h>
#include <stdatomic.h>

#define DMA_MGR_ALIGN       64
#define DMA_MGR_INVALID     0xFFFFFFFFU

typedef struct {
    uint8_t              *base;
    uint32_t              total_size;
    atomic_uint_least32_t next_free;
    atomic_uint_least32_t used_bytes;
} dma_mgr_t;

void dma_mgr_init(dma_mgr_t *mgr, void *base, uint32_t total_size);
uint32_t dma_mgr_alloc(dma_mgr_t *mgr, uint32_t size);
void dma_mgr_free(dma_mgr_t *mgr, uint32_t offset, uint32_t size);
void *dma_mgr_ptr(dma_mgr_t *mgr, uint32_t offset);

#endif
