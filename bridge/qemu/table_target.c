#include "table_target.h"

#include "table_ctrl_core.h"

#include <stddef.h>

enum {
    COSIM_TABLE_PHYSICAL_BARS = 6,
};

uint32_t cosim_table_target_next_generation(uint32_t generation)
{
    /* Generation zero is the invalid sentinel.  Saturate at UINT32_MAX so
     * exhaustion fails closed instead of reusing an old identity (ABA). */
    return generation == UINT32_MAX ? 0 : generation + 1;
}

int cosim_table_target_snapshot_valid(
    const cosim_table_target_snapshot_t *snapshot)
{
    size_t physical;

    if (snapshot == NULL || snapshot->generation == 0) {
        return 0;
    }
    for (physical = 0; physical < COSIM_TABLE_PHYSICAL_BARS; ++physical) {
        if (snapshot->bar_sizes[physical] != 0) {
            return 1;
        }
    }
    return 0;
}

int cosim_table_target_matches(const cosim_table_target_snapshot_t *snapshot,
                               const cosim_table_target_t *target)
{
    uint64_t aperture_bytes;
    uint8_t physical_bar;

    if (!cosim_table_target_snapshot_valid(snapshot) || target == NULL ||
        target->target_type != COSIM_TABLE_TARGET_PF ||
        target->pf_index != 0 || cosim_table_le16_to_cpu(target->vf_index) != 0 ||
        cosim_table_le16_to_cpu(target->rc_id) != snapshot->rc_id ||
        cosim_table_le16_to_cpu(target->device_instance) !=
            snapshot->device_instance ||
        cosim_table_le16_to_cpu(target->pci_domain) != snapshot->pci_domain ||
        cosim_table_le16_to_cpu(target->target_bdf) != snapshot->target_bdf ||
        cosim_table_le32_to_cpu(target->generation) != snapshot->generation) {
        return 0;
    }
    return cosim_table_map_logical_bar(snapshot->bar_sizes, target->bar_index,
                                       &physical_bar, &aperture_bytes) == 0;
}
