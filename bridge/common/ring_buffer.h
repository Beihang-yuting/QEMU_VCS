#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <stdint.h>
#include "compat_atomic.h"
#include <stdbool.h>

/* Header stored at the start of the shared-memory buffer; head/tail live here
 * so they are visible to every process that maps the same region. */
typedef struct {
    atomic_uint_least32_t head;
    atomic_uint_least32_t tail;
    uint32_t              capacity;     /* total slots (power-of-2 not required) */
    uint32_t              element_size;
} ring_buf_hdr_t;

/* Process-local handle; all mutable state is in the shared header. */
typedef struct {
    ring_buf_hdr_t *hdr;   /* points into shared memory */
    uint8_t        *data;  /* element storage, immediately after hdr in shm */
} ring_buf_t;

int ring_buf_init(ring_buf_t *rb, void *buf, uint32_t buf_size, uint32_t element_size);
int ring_buf_attach(ring_buf_t *rb, void *buf, uint32_t buf_size, uint32_t element_size);
int ring_buf_enqueue(ring_buf_t *rb, const void *element);
int ring_buf_dequeue(ring_buf_t *rb, void *element);
bool     ring_buf_is_empty(const ring_buf_t *rb);
bool     ring_buf_is_full(const ring_buf_t *rb);
uint32_t ring_buf_count(const ring_buf_t *rb);
uint32_t ring_buf_capacity(const ring_buf_t *rb);

#endif /* RING_BUFFER_H */
