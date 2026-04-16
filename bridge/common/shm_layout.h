#ifndef SHM_LAYOUT_H
#define SHM_LAYOUT_H

#include <stdint.h>
#include <stdatomic.h>
#include "cosim_types.h"
#include "ring_buffer.h"

#define COSIM_SHM_TOTAL_SIZE    (4 * 1024 * 1024)
#define COSIM_SHM_CTRL_OFFSET   0x00000000
#define COSIM_SHM_CTRL_SIZE     0x00001000
#define COSIM_SHM_REQ_OFFSET    0x00001000
#define COSIM_SHM_REQ_SIZE      0x00040000
#define COSIM_SHM_CPL_OFFSET    0x00041000
#define COSIM_SHM_CPL_SIZE      0x00040000
#define COSIM_SHM_DMA_OFFSET    0x00081000

typedef struct {
    uint32_t              magic;
    uint32_t              version;
    uint32_t              mode;
    uint32_t              _pad0;
    atomic_uint_least32_t qemu_ready;
    atomic_uint_least32_t vcs_ready;
    uint32_t              _pad1[2];
    atomic_uint_least64_t sim_time_ns;
    uint32_t              irq_status[COSIM_IRQ_SLOTS];
} cosim_ctrl_t;

typedef struct {
    void          *base;
    cosim_ctrl_t  *ctrl;
    ring_buf_t     req_ring;
    ring_buf_t     cpl_ring;
    int            fd;
} cosim_shm_t;

int cosim_shm_create(cosim_shm_t *shm, const char *name);
int cosim_shm_open(cosim_shm_t *shm, const char *name);
void cosim_shm_close(cosim_shm_t *shm);
void cosim_shm_destroy(cosim_shm_t *shm, const char *name);

#endif /* SHM_LAYOUT_H */
