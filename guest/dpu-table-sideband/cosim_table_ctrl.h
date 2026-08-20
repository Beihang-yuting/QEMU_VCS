/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __DPU_COSIM_TABLE_CTRL_H
#define __DPU_COSIM_TABLE_CTRL_H

#include "cosim_table_protocol.h"

enum dpu_table_submit_result {
	DPU_TABLE_FRONTDOOR = 0,
	DPU_TABLE_SUCCESS = 1,
	DPU_TABLE_ERROR = 2,
};

enum dpu_table_write_order {
	DPU_TABLE_LOW_TO_HIGH = 0,
	DPU_TABLE_HIGH_TO_LOW = 1,
};

static inline enum dpu_table_submit_result
dpu_table_policy(cosim_table_status_t status)
{
	if (status == COSIM_TABLE_ST_SUCCESS)
		return DPU_TABLE_SUCCESS;
	if (cosim_table_status_may_frontdoor(status))
		return DPU_TABLE_FRONTDOOR;
	return DPU_TABLE_ERROR;
}

#ifdef __KERNEL__
#include <linux/types.h>

struct dpu_hw;

enum dpu_table_submit_result dpu_table_submit(
	struct dpu_hw *hw, unsigned int logical_bar, u64 offset,
	const void *data, u32 bytes, enum dpu_table_write_order order);
enum dpu_table_submit_result dpu_table_submit_batch(
	struct dpu_hw *hw, unsigned int logical_bar, u64 first_offset,
	const void *entries, u32 entry_bytes, u32 stride_bytes,
	u32 entry_count, enum dpu_table_write_order order);

u32 dpu_table_frontdoor_flush_interval_get(void);
bool dpu_table_backdoor_enabled(void);
int dpu_table_ctrl_register(void);
void dpu_table_ctrl_unregister(void);
#endif

#endif /* __DPU_COSIM_TABLE_CTRL_H */
