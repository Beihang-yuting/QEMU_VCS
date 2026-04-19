#ifndef ETH_SHM_H
#define ETH_SHM_H

#include "compat_atomic.h"
#include <stddef.h>
#include <stdint.h>
#include "eth_types.h"

#define ETH_SHM_MAGIC      0x45544831u   /* "ETH1" */
#define ETH_SHM_VERSION    1u

/* Packed control region lives at offset 0 of the SHM object. */
typedef struct {
    uint32_t                magic;
    uint32_t                version;
    /* Per-node ready flags: node A writes [0], node B writes [1]. */
    _Atomic uint32_t        ready_flag[2];
    /* Loose time sync: each node publishes its local sim time here. */
    _Atomic uint64_t        node_time_ns[2];
    /* Link status (not atomic, written by the controlling side). */
    uint32_t                link_up;
    uint32_t                reserved;
} eth_shm_ctrl_t;

typedef struct {
    /* One direction of the link: ring head / tail + slots. */
    _Atomic uint32_t        head;     /* producer index */
    _Atomic uint32_t        tail;     /* consumer index */
    uint32_t                depth;
    uint32_t                _pad;
    eth_frame_t             slots[ETH_FRAME_RING_DEPTH];
} eth_frame_ring_t;

typedef struct {
    eth_shm_ctrl_t *        ctrl;
    eth_frame_ring_t *      a_to_b;
    eth_frame_ring_t *      b_to_a;
    void *                  base;
    size_t                  size;
    int                     fd;       /* -1 after unmap */
    char                    name[128];
} eth_shm_t;

/* Create or attach to the shared memory backing the ETH link.
 *   create = 1: create & zero the region (intended for "first starter")
 *   create = 0: attach to existing region
 */
int   eth_shm_open(eth_shm_t *shm, const char *name, int create);
void  eth_shm_close(eth_shm_t *shm);
void  eth_shm_unlink(const char *name);

/* Signal readiness from a node's side; peer sees via peer_ready. */
void  eth_shm_mark_ready(eth_shm_t *shm, eth_role_t role);
int   eth_shm_peer_ready(const eth_shm_t *shm, eth_role_t self_role);

/* Non-blocking enqueue / dequeue. Returns 0 on success, -1 on empty/full. */
int   eth_shm_enqueue(eth_frame_ring_t *ring, const eth_frame_t *f);
int   eth_shm_dequeue(eth_frame_ring_t *ring, eth_frame_t *out);

/* Direction helpers (returns non-owning pointer into shm->a_to_b / b_to_a). */
eth_frame_ring_t *eth_shm_tx_ring(eth_shm_t *shm, eth_role_t role);
eth_frame_ring_t *eth_shm_rx_ring(eth_shm_t *shm, eth_role_t role);

/* Loose-coupling time barrier. */
void     eth_shm_advance_time(eth_shm_t *shm, eth_role_t role, uint64_t ns);
uint64_t eth_shm_peer_time(const eth_shm_t *shm, eth_role_t self_role);

#endif
