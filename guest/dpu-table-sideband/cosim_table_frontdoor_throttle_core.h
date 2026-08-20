/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __DPU_COSIM_TABLE_FRONTDOOR_THROTTLE_CORE_H
#define __DPU_COSIM_TABLE_FRONTDOOR_THROTTLE_CORE_H

#ifdef __KERNEL__
#include <linux/types.h>
typedef u32 dpu_table_frontdoor_u32;
typedef u64 dpu_table_frontdoor_u64;
#else
#include <stdint.h>
typedef uint32_t dpu_table_frontdoor_u32;
typedef uint64_t dpu_table_frontdoor_u64;
#endif

static inline int dpu_table_frontdoor_should_flush(
		dpu_table_frontdoor_u64 sequence,
		dpu_table_frontdoor_u32 interval)
{
	return interval != 0 && sequence != 0 && sequence % interval == 0;
}

#endif
