#ifndef COSIM_TABLE_TARGET_H
#define COSIM_TABLE_TARGET_H

#include <stdint.h>

#include "cosim_table_protocol.h"

typedef struct {
    uint16_t rc_id;
    uint16_t device_instance;
    uint16_t pci_domain;
    uint16_t target_bdf;
    uint32_t generation;
    uint64_t bar_sizes[6];
} cosim_table_target_snapshot_t;

int cosim_table_target_snapshot_valid(
    const cosim_table_target_snapshot_t *snapshot);
int cosim_table_target_matches(const cosim_table_target_snapshot_t *snapshot,
                               const cosim_table_target_t *target);

#endif /* COSIM_TABLE_TARGET_H */
