#include "table_target.h"

int main(void)
{
    cosim_table_target_snapshot_t snapshot = {
        .generation = 1,
        .bar_sizes = { 1 },
    };

    if (cosim_table_target_next_generation(UINT32_MAX) != 0) {
        return 1;
    }
    return cosim_table_target_snapshot_valid(&snapshot) ? 0 : 1;
}
