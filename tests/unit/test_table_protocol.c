#include "cosim_table_ctrl_uapi.h"
#include <assert.h>

int main(void)
{
    assert(COSIM_TABLE_PROTOCOL_VERSION == 1);
    assert(COSIM_TABLE_ST_NO_ROUTE == 2);
    assert(COSIM_TABLE_ST_PROTOCOL == 9);
    assert(sizeof(cosim_table_frame_hdr_t) == 24);
    assert(sizeof(cosim_table_target_t) == 24);
    assert(sizeof(cosim_table_route_entry_t) == 128);
    assert(sizeof(cosim_table_completion_t) == 32);
    assert(COSIM_TABLE_REG_DOORBELL == 0x20);
    assert(COSIM_TABLE_REG_TARGET_GENERATION == 0x30);
    assert(sizeof(cosim_table_slot_hdr_t) == 128);
    assert(cosim_table_status_may_frontdoor(COSIM_TABLE_ST_NO_ROUTE));
    assert(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_TIMEOUT));
    return 0;
}
