#ifndef COSIM_TABLE_CTRL_UAPI_H
#define COSIM_TABLE_CTRL_UAPI_H

#include "cosim_table_protocol.h"

#define COSIM_TABLE_SLOT_HEADER_VERSION 1u

enum {
    COSIM_TABLE_REG_MAGIC = 0x00,
    COSIM_TABLE_REG_VERSION = 0x04,
    COSIM_TABLE_REG_CAPS = 0x08,
    COSIM_TABLE_REG_READY = 0x0c,
    COSIM_TABLE_REG_DMA_ADDR_LO = 0x10,
    COSIM_TABLE_REG_DMA_ADDR_HI = 0x14,
    COSIM_TABLE_REG_DMA_BYTES = 0x18,
    COSIM_TABLE_REG_SLOT_COUNT = 0x1c,
    COSIM_TABLE_REG_DOORBELL = 0x20,
    COSIM_TABLE_REG_LAST_ERROR = 0x24,
    COSIM_TABLE_REG_RC_ID = 0x28,
    COSIM_TABLE_REG_DEVICE_INSTANCE = 0x2c,
    COSIM_TABLE_REG_TARGET_GENERATION = 0x30,
};

static inline void cosim_table_target_set_identity(
    cosim_table_target_t *target, cosim_u16 rc_id,
    cosim_u16 device_instance, cosim_u16 pci_domain,
    cosim_u16 target_bdf, cosim_u32 generation)
{
    target->rc_id = cosim_table_cpu_to_le16(rc_id);
    target->device_instance = cosim_table_cpu_to_le16(device_instance);
    target->pci_domain = cosim_table_cpu_to_le16(pci_domain);
    target->target_bdf = cosim_table_cpu_to_le16(target_bdf);
    target->generation = cosim_table_cpu_to_le32(generation);
}

static inline int cosim_table_target_is_pf0(cosim_u8 target_type,
                                            cosim_u16 pf_index)
{
    return target_type == COSIM_TABLE_TARGET_PF && pf_index == 0;
}

enum {
    COSIM_TABLE_SLOT_FREE,
    COSIM_TABLE_SLOT_READY,
    COSIM_TABLE_SLOT_BUSY,
    COSIM_TABLE_SLOT_COMPLETE,
};

/*
 * Guest/QEMU coherent DMA slot.  The owner writes request or completion data
 * before publishing the corresponding state with release ordering; the next
 * owner observes state with acquire ordering before consuming those fields.
 */
typedef struct __attribute__((packed, aligned(8))) {
    cosim_u32 state;
    cosim_u32 header_version;
    cosim_u64 transaction_id;
    cosim_table_target_t target;
    cosim_u64 bar_offset;
    cosim_u32 payload_bytes;
    cosim_u32 payload_offset;
    cosim_u32 result_status;
    cosim_u32 result_failed_index;
    cosim_u32 result_committed_count;
    cosim_u32 result_handler_error;
    cosim_u32 result_dword;
    cosim_u8 reserved[52];
} cosim_table_slot_hdr_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_slot_hdr_t) == 128,
                    "cosim_table_slot_hdr_t must be 128 bytes");
COSIM_STATIC_ASSERT(__alignof__(cosim_table_slot_hdr_t) == 8,
                    "cosim_table_slot_hdr_t must be 8-byte aligned");

#endif /* COSIM_TABLE_CTRL_UAPI_H */
