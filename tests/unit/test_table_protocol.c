#include "cosim_table_ctrl_uapi.h"
#include "test_check.h"

int main(void)
{
    CHECK(COSIM_TABLE_PROTOCOL_VERSION == 1);
    CHECK(COSIM_TABLE_ST_NO_ROUTE == 2);
    CHECK(COSIM_TABLE_ST_PROTOCOL == 9);
    CHECK(sizeof(cosim_table_frame_hdr_t) == 24);
    CHECK(sizeof(cosim_table_target_t) == 24);
    CHECK(sizeof(cosim_table_route_entry_t) == 128);
    CHECK(sizeof(cosim_table_completion_t) == 32);
    CHECK(COSIM_TABLE_REG_DOORBELL == 0x20);
    CHECK(COSIM_TABLE_REG_TARGET_GENERATION == 0x30);
    CHECK(sizeof(cosim_table_slot_hdr_t) == 128);
    CHECK(cosim_table_status_may_frontdoor(COSIM_TABLE_ST_NO_ROUTE));
    CHECK(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_TIMEOUT));
    return 0;
}
