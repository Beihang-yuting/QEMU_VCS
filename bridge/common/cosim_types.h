#ifndef COSIM_TYPES_H
#define COSIM_TYPES_H

#include <stdint.h>
#include "compat_atomic.h"

#define COSIM_SHM_MAGIC       0xDEADBEEF
#define COSIM_PROTOCOL_VER    1
#define COSIM_TLP_DATA_SIZE   64
#define COSIM_IRQ_SLOTS       8

typedef enum {
    TLP_MWR    = 0,
    TLP_MRD    = 1,
    TLP_CFGWR  = 2,
    TLP_CFGRD  = 3,
    TLP_CPL    = 4,
} tlp_type_t;

typedef enum {
    COSIM_MODE_FAST    = 0,
    COSIM_MODE_PRECISE = 1,
} cosim_mode_t;

typedef enum {
    SYNC_MSG_TLP_READY    = 0,
    SYNC_MSG_CPL_READY    = 1,
    SYNC_MSG_MODE_SWITCH  = 2,
    SYNC_MSG_SHUTDOWN     = 3,
    /* P2 新增 */
    SYNC_MSG_DMA_REQ      = 4,
    SYNC_MSG_DMA_CPL      = 5,
    SYNC_MSG_MSI          = 6,
    SYNC_MSG_CLOCK_STEP   = 7,
    SYNC_MSG_CLOCK_ACK    = 8,
} sync_msg_type_t;

typedef struct {
    sync_msg_type_t type;
    uint32_t        payload;
} sync_msg_t;

typedef struct {
    uint8_t   type;
    uint8_t   tag;
    uint16_t  len;
    uint32_t  _pad0;
    uint64_t  addr;
    uint8_t   data[COSIM_TLP_DATA_SIZE];
    uint64_t  dma_offset;
    uint64_t  timestamp;
} __attribute__((packed)) tlp_entry_t;

_Static_assert(sizeof(tlp_entry_t) == 96, "tlp_entry_t must be 96 bytes");

typedef struct {
    uint8_t   type;
    uint8_t   tag;
    uint8_t   status;
    uint8_t   _pad0;
    uint32_t  len;
    uint8_t   data[COSIM_TLP_DATA_SIZE];
    uint64_t  timestamp;
} __attribute__((packed)) cpl_entry_t;

_Static_assert(sizeof(cpl_entry_t) == 80, "cpl_entry_t must be 80 bytes");

/* ========== DMA 请求（VCS 发起，QEMU 处理） ========== */
typedef enum {
    DMA_DIR_READ  = 0,
    DMA_DIR_WRITE = 1,
} dma_direction_t;

typedef struct {
    uint32_t tag;
    uint32_t direction;
    uint64_t host_addr;
    uint32_t len;
    uint32_t dma_offset;
    uint64_t timestamp;
} __attribute__((packed)) dma_req_t;

_Static_assert(sizeof(dma_req_t) == 32, "dma_req_t must be 32 bytes");

typedef struct {
    uint32_t tag;
    uint32_t status;
    uint64_t timestamp;
} __attribute__((packed)) dma_cpl_t;

_Static_assert(sizeof(dma_cpl_t) == 16, "dma_cpl_t must be 16 bytes");

/* ========== MSI 事件 ========== */
typedef struct {
    uint32_t vector;
    uint32_t _pad0;
    uint64_t timestamp;
} __attribute__((packed)) msi_event_t;

_Static_assert(sizeof(msi_event_t) == 16, "msi_event_t must be 16 bytes");

/* ========== 时钟同步（精确模式） ========== */
typedef struct {
    uint64_t cycles;
    uint64_t sim_time_ns;
} __attribute__((packed)) clock_sync_t;

_Static_assert(sizeof(clock_sync_t) == 16, "clock_sync_t must be 16 bytes");

#endif /* COSIM_TYPES_H */
