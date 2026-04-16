#include "eth_shm.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define ETH_SHM_SIZE (sizeof(eth_shm_ctrl_t) + 2 * sizeof(eth_frame_ring_t))

int eth_shm_open(eth_shm_t *shm, const char *name, int create)
{
    memset(shm, 0, sizeof(*shm));
    shm->fd = -1;
    snprintf(shm->name, sizeof(shm->name), "%s", name);

    int flags = create ? (O_CREAT | O_RDWR | O_EXCL) : O_RDWR;
    int fd = shm_open(name, flags, 0600);
    if (fd < 0) {
        /* If create==1 and object already exists, reuse it. */
        if (create) {
            fd = shm_open(name, O_CREAT | O_RDWR, 0600);
            if (fd < 0) {
                perror("shm_open");
                return -1;
            }
        } else {
            return -1;
        }
    }

    if (create && ftruncate(fd, ETH_SHM_SIZE) < 0) {
        perror("ftruncate");
        close(fd);
        shm_unlink(name);
        return -1;
    }

    void *base = mmap(NULL, ETH_SHM_SIZE, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }

    shm->fd = fd;
    shm->base = base;
    shm->size = ETH_SHM_SIZE;
    shm->ctrl = (eth_shm_ctrl_t *)base;
    shm->a_to_b = (eth_frame_ring_t *)((uint8_t *)base + sizeof(eth_shm_ctrl_t));
    shm->b_to_a = (eth_frame_ring_t *)((uint8_t *)base + sizeof(eth_shm_ctrl_t)
                                         + sizeof(eth_frame_ring_t));

    if (create) {
        memset(base, 0, ETH_SHM_SIZE);
        shm->ctrl->magic = ETH_SHM_MAGIC;
        shm->ctrl->version = ETH_SHM_VERSION;
        shm->ctrl->link_up = 1;
        shm->a_to_b->depth = ETH_FRAME_RING_DEPTH;
        shm->b_to_a->depth = ETH_FRAME_RING_DEPTH;
    } else {
        if (shm->ctrl->magic != ETH_SHM_MAGIC ||
            shm->ctrl->version != ETH_SHM_VERSION) {
            fprintf(stderr, "eth_shm_open: magic/version mismatch\n");
            eth_shm_close(shm);
            return -1;
        }
    }
    return 0;
}

void eth_shm_close(eth_shm_t *shm)
{
    if (!shm) return;
    if (shm->base && shm->base != MAP_FAILED) {
        munmap(shm->base, shm->size);
    }
    if (shm->fd >= 0) {
        close(shm->fd);
    }
    shm->base = NULL;
    shm->fd = -1;
}

void eth_shm_unlink(const char *name)
{
    shm_unlink(name);
}

void eth_shm_mark_ready(eth_shm_t *shm, eth_role_t role)
{
    if (!shm || !shm->ctrl) return;
    atomic_store(&shm->ctrl->ready_flag[role], 1);
}

int eth_shm_peer_ready(const eth_shm_t *shm, eth_role_t self_role)
{
    if (!shm || !shm->ctrl) return 0;
    eth_role_t peer = (self_role == ETH_ROLE_A) ? ETH_ROLE_B : ETH_ROLE_A;
    return atomic_load(&shm->ctrl->ready_flag[peer]) != 0;
}

int eth_shm_enqueue(eth_frame_ring_t *ring, const eth_frame_t *f)
{
    uint32_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    uint32_t next = (head + 1) % ring->depth;
    if (next == tail) {
        return -1;  /* full */
    }
    ring->slots[head] = *f;
    atomic_store_explicit(&ring->head, next, memory_order_release);
    return 0;
}

int eth_shm_dequeue(eth_frame_ring_t *ring, eth_frame_t *out)
{
    uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (tail == head) {
        return -1;  /* empty */
    }
    *out = ring->slots[tail];
    atomic_store_explicit(&ring->tail, (tail + 1) % ring->depth,
                          memory_order_release);
    return 0;
}

eth_frame_ring_t *eth_shm_tx_ring(eth_shm_t *shm, eth_role_t role)
{
    return (role == ETH_ROLE_A) ? shm->a_to_b : shm->b_to_a;
}

eth_frame_ring_t *eth_shm_rx_ring(eth_shm_t *shm, eth_role_t role)
{
    return (role == ETH_ROLE_A) ? shm->b_to_a : shm->a_to_b;
}

void eth_shm_advance_time(eth_shm_t *shm, eth_role_t role, uint64_t ns)
{
    if (!shm || !shm->ctrl) return;
    atomic_store(&shm->ctrl->node_time_ns[role], ns);
}

uint64_t eth_shm_peer_time(const eth_shm_t *shm, eth_role_t self_role)
{
    if (!shm || !shm->ctrl) return 0;
    eth_role_t peer = (self_role == ETH_ROLE_A) ? ETH_ROLE_B : ETH_ROLE_A;
    return atomic_load(&shm->ctrl->node_time_ns[peer]);
}
