#include "ring_buffer.h"
#include <string.h>

int ring_buf_init(ring_buf_t *rb, void *buf, uint32_t buf_size, uint32_t element_size) {
    if (!rb || !buf || element_size == 0) return -1;
    uint32_t capacity = buf_size / element_size;
    if (capacity < 2) return -1;
    rb->data = (uint8_t *)buf;
    rb->element_size = element_size;
    rb->capacity = capacity;
    atomic_store(&rb->head, 0);
    atomic_store(&rb->tail, 0);
    return 0;
}

int ring_buf_attach(ring_buf_t *rb, void *buf, uint32_t buf_size, uint32_t element_size) {
    if (!rb || !buf || element_size == 0) return -1;
    uint32_t capacity = buf_size / element_size;
    if (capacity < 2) return -1;
    rb->data = (uint8_t *)buf;
    rb->element_size = element_size;
    rb->capacity = capacity;
    /* NOTE: does NOT reset head/tail — caller owns existing state */
    return 0;
}

int ring_buf_enqueue(ring_buf_t *rb, const void *element) {
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_relaxed);
    uint32_t next_tail = (tail + 1) % rb->capacity;
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    if (next_tail == head) return -1;  /* full */
    memcpy(rb->data + tail * rb->element_size, element, rb->element_size);
    atomic_store_explicit(&rb->tail, next_tail, memory_order_release);
    return 0;
}

int ring_buf_dequeue(ring_buf_t *rb, void *element) {
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    if (head == tail) return -1;  /* empty */
    memcpy(element, rb->data + head * rb->element_size, rb->element_size);
    uint32_t next_head = (head + 1) % rb->capacity;
    atomic_store_explicit(&rb->head, next_head, memory_order_release);
    return 0;
}

bool ring_buf_is_empty(const ring_buf_t *rb) {
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    return head == tail;
}

bool ring_buf_is_full(const ring_buf_t *rb) {
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    return ((tail + 1) % rb->capacity) == head;
}

uint32_t ring_buf_count(const ring_buf_t *rb) {
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    if (tail >= head) return tail - head;
    return rb->capacity - head + tail;
}

uint32_t ring_buf_capacity(const ring_buf_t *rb) {
    /* capacity is internal slots; usable slots = capacity - 1 (one slot reserved as sentinel) */
    return rb->capacity - 1;
}
