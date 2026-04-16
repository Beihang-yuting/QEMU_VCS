#include "ring_buffer.h"
#include <string.h>

/* Layout of the shared-memory buffer:
 *   [ring_buf_hdr_t header][element_0][element_1]...[element_{capacity-1}]
 *
 * ring_buf_init()   — creator: writes header, zeroes head/tail
 * ring_buf_attach() — opener:  reads header, does NOT reset head/tail
 */

static uint32_t _capacity(uint32_t buf_size, uint32_t element_size) {
    if (buf_size <= sizeof(ring_buf_hdr_t)) return 0;
    return (buf_size - sizeof(ring_buf_hdr_t)) / element_size;
}

int ring_buf_init(ring_buf_t *rb, void *buf, uint32_t buf_size, uint32_t element_size) {
    if (!rb || !buf || element_size == 0) return -1;
    uint32_t cap = _capacity(buf_size, element_size);
    if (cap < 2) return -1;

    ring_buf_hdr_t *hdr = (ring_buf_hdr_t *)buf;
    hdr->capacity     = cap;
    hdr->element_size = element_size;
    atomic_store(&hdr->head, 0);
    atomic_store(&hdr->tail, 0);

    rb->hdr  = hdr;
    rb->data = (uint8_t *)buf + sizeof(ring_buf_hdr_t);
    return 0;
}

int ring_buf_attach(ring_buf_t *rb, void *buf, uint32_t buf_size, uint32_t element_size) {
    if (!rb || !buf || element_size == 0) return -1;
    uint32_t cap = _capacity(buf_size, element_size);
    if (cap < 2) return -1;

    ring_buf_hdr_t *hdr = (ring_buf_hdr_t *)buf;
    /* Validate that the creator wrote the same parameters. */
    if (hdr->capacity != cap || hdr->element_size != element_size) return -1;

    rb->hdr  = hdr;
    rb->data = (uint8_t *)buf + sizeof(ring_buf_hdr_t);
    return 0;
}

int ring_buf_enqueue(ring_buf_t *rb, const void *element) {
    ring_buf_hdr_t *hdr = rb->hdr;
    uint32_t tail      = atomic_load_explicit(&hdr->tail, memory_order_relaxed);
    uint32_t next_tail = (tail + 1) % hdr->capacity;
    uint32_t head      = atomic_load_explicit(&hdr->head, memory_order_acquire);
    if (next_tail == head) return -1;  /* full */
    memcpy(rb->data + tail * hdr->element_size, element, hdr->element_size);
    atomic_store_explicit(&hdr->tail, next_tail, memory_order_release);
    return 0;
}

int ring_buf_dequeue(ring_buf_t *rb, void *element) {
    ring_buf_hdr_t *hdr = rb->hdr;
    uint32_t head = atomic_load_explicit(&hdr->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&hdr->tail, memory_order_acquire);
    if (head == tail) return -1;  /* empty */
    memcpy(element, rb->data + head * hdr->element_size, hdr->element_size);
    uint32_t next_head = (head + 1) % hdr->capacity;
    atomic_store_explicit(&hdr->head, next_head, memory_order_release);
    return 0;
}

bool ring_buf_is_empty(const ring_buf_t *rb) {
    uint32_t head = atomic_load_explicit(&rb->hdr->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&rb->hdr->tail, memory_order_acquire);
    return head == tail;
}

bool ring_buf_is_full(const ring_buf_t *rb) {
    uint32_t tail = atomic_load_explicit(&rb->hdr->tail, memory_order_acquire);
    uint32_t head = atomic_load_explicit(&rb->hdr->head, memory_order_acquire);
    return ((tail + 1) % rb->hdr->capacity) == head;
}

uint32_t ring_buf_count(const ring_buf_t *rb) {
    uint32_t head = atomic_load_explicit(&rb->hdr->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&rb->hdr->tail, memory_order_acquire);
    if (tail >= head) return tail - head;
    return rb->hdr->capacity - head + tail;
}

uint32_t ring_buf_capacity(const ring_buf_t *rb) {
    /* capacity is internal slots; usable slots = capacity - 1 (one slot reserved as sentinel) */
    return rb->hdr->capacity - 1;
}
