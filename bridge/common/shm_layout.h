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

/* P2 新增：DMA 队列 + MSI 队列 + DMA 数据区 */
#define COSIM_SHM_DMA_REQ_OFFSET    0x00081000
#define COSIM_SHM_DMA_REQ_SIZE      0x00010000   /* 64KB */
#define COSIM_SHM_DMA_CPL_OFFSET    0x00091000
#define COSIM_SHM_DMA_CPL_SIZE      0x00010000   /* 64KB */
#define COSIM_SHM_MSI_OFFSET        0x000A1000
#define COSIM_SHM_MSI_SIZE          0x00001000   /* 4KB */
#define COSIM_SHM_DMA_BUF_OFFSET    0x000A2000

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
    /* P2 新增 */
    atomic_uint_least32_t mode_switch_pending;
    atomic_uint_least32_t target_mode;
    atomic_uint_least64_t precise_cycles_pending;
    uint32_t              _pad_tail[4];
} cosim_ctrl_t;

typedef struct {
    void          *base;
    cosim_ctrl_t  *ctrl;
    ring_buf_t     req_ring;
    ring_buf_t     cpl_ring;
    /* P2 新增 */
    ring_buf_t     dma_req_ring;
    ring_buf_t     dma_cpl_ring;
    ring_buf_t     msi_ring;
    void          *dma_buf;
    uint32_t       dma_buf_size;
    int            fd;
} cosim_shm_t;

int cosim_shm_create(cosim_shm_t *shm, const char *name);
int cosim_shm_open(cosim_shm_t *shm, const char *name);
void cosim_shm_close(cosim_shm_t *shm);
void cosim_shm_destroy(cosim_shm_t *shm, const char *name);

#endif /* SHM_LAYOUT_H */
