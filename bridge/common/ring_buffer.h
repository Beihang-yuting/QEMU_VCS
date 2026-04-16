#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <stdint.h>
#include <stdatomic.h>
#include <stdbool.h>

typedef struct {
    uint8_t        *data;
    uint32_t        element_size;
    uint32_t        capacity;
    atomic_uint_least32_t head;
    atomic_uint_least32_t tail;
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
