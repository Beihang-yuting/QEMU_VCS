#ifndef COSIM_TYPES_H
#define COSIM_TYPES_H

#include <stdint.h>
#include <stdatomic.h>

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

#endif /* COSIM_TYPES_H */
