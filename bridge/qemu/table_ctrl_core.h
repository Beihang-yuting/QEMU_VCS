#ifndef COSIM_TABLE_CTRL_CORE_H
#define COSIM_TABLE_CTRL_CORE_H

#include "cosim_table_ctrl_uapi.h"

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    ssize_t (*dma_read)(void *opaque, uint64_t address, void *buffer,
                        size_t bytes);
    ssize_t (*dma_write)(void *opaque, uint64_t address, const void *buffer,
                         size_t bytes);
    void (*acquire_barrier)(void *opaque);
    void (*release_barrier)(void *opaque);
    int (*target_active)(void *opaque, const cosim_table_target_t *target);
    const cosim_table_route_entry_t *(*match)(
        void *opaque, const cosim_table_target_t *target, uint64_t offset,
        uint8_t operation);
    cosim_table_status_t (*write)(
        void *opaque, const cosim_table_write_begin_t *request,
        const uint8_t *payload, cosim_table_completion_t *completion,
        int timeout_ms);
    cosim_table_status_t (*read_dword)(
        void *opaque, const cosim_table_read_dword_t *request,
        cosim_table_completion_t *completion, int timeout_ms);
} cosim_table_ctrl_ops_t;

typedef struct cosim_table_ctrl_core {
    cosim_table_ctrl_ops_t ops;
    void *opaque;
    uint32_t max_payload_bytes;
    atomic_int ready;
    atomic_int processing;
} cosim_table_ctrl_core_t;

int cosim_table_ctrl_core_init(cosim_table_ctrl_core_t *core,
                               const cosim_table_ctrl_ops_t *ops,
                               void *opaque, uint32_t max_payload_bytes);
void cosim_table_ctrl_core_set_ready(cosim_table_ctrl_core_t *core, int ready);
/* Returns zero on success and -1 when logical_bar has no owner region. */
int cosim_table_map_logical_bar(const uint64_t bar_sizes[6],
                                uint8_t logical_bar, uint8_t *pci_region,
                                uint64_t *aperture_bytes);
/* Returns one for an eligible PF0 BAR0/BAR1 read, else zero. */
int cosim_table_decode_read(const uint64_t bar_sizes[6], uint16_t rc_id,
                            uint16_t device_instance, uint8_t pf_index,
                            uint8_t pci_region, int is_vf,
                            uint64_t bar_offset, unsigned size,
                            cosim_table_target_t *target,
                            uint64_t *aligned_offset, uint8_t *byte_offset);
uint64_t cosim_table_extract_read(uint32_t dword, uint8_t byte_offset,
                                  unsigned size);
cosim_table_status_t cosim_table_ctrl_process_slot(
    cosim_table_ctrl_core_t *core, uint64_t slot_dma_address,
    uint32_t slot_bytes, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* COSIM_TABLE_CTRL_CORE_H */
