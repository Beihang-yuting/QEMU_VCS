#include "test_check.h"

#include "cosim_table_ctrl.h"

int main(void)
{
    CHECK(dpu_table_policy(COSIM_TABLE_ST_SUCCESS) == DPU_TABLE_SUCCESS);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_NOT_READY) ==
           DPU_TABLE_FRONTDOOR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_NO_ROUTE) == DPU_TABLE_FRONTDOOR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_UNSUPPORTED) ==
           DPU_TABLE_FRONTDOOR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_SLOT_BUSY) ==
           DPU_TABLE_FRONTDOOR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_EXEC_ERROR) == DPU_TABLE_ERROR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_TIMEOUT) == DPU_TABLE_ERROR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_TARGET_GONE) == DPU_TABLE_ERROR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_UNKNOWN) == DPU_TABLE_ERROR);
    CHECK(dpu_table_policy(COSIM_TABLE_ST_PROTOCOL) == DPU_TABLE_ERROR);
    return 0;
}
