/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __DPU_COSIM_TABLE_BATCH_CORE_H
#define __DPU_COSIM_TABLE_BATCH_CORE_H

#ifdef __KERNEL__
#include <linux/types.h>
typedef u32 dpu_table_batch_u32;
typedef u64 dpu_table_batch_u64;
#define DPU_TABLE_BATCH_SIZE_MAX ((size_t)-1)
#define DPU_TABLE_BATCH_U64_MAX U64_MAX
#else
#include <stdint.h>
#include <stddef.h>
typedef uint32_t dpu_table_batch_u32;
typedef uint64_t dpu_table_batch_u64;
#define DPU_TABLE_BATCH_SIZE_MAX ((size_t)-1)
#define DPU_TABLE_BATCH_U64_MAX UINT64_MAX
#endif

enum dpu_table_batch_core_result {
	DPU_TABLE_BATCH_CORE_FRONTDOOR = 0,
	DPU_TABLE_BATCH_CORE_SUCCESS = 1,
	DPU_TABLE_BATCH_CORE_ERROR = 2,
};

enum dpu_table_batch_core_order {
	DPU_TABLE_BATCH_CORE_LOW_TO_HIGH = 0,
	DPU_TABLE_BATCH_CORE_HIGH_TO_LOW = 1,
};

struct dpu_table_batch_progress {
	dpu_table_batch_u32 committed_entries;
	dpu_table_batch_u32 failed_index;
	dpu_table_batch_u64 failed_offset;
	int original_result;
	int final_result;
};

typedef int (*dpu_table_batch_submit_once_fn)(
	void *context, dpu_table_batch_u64 offset, const void *data,
	dpu_table_batch_u32 payload_bytes, int order);

static inline int dpu_table_batch_core(
	void *context, dpu_table_batch_u64 first_offset, const void *entries,
	dpu_table_batch_u32 entry_bytes, dpu_table_batch_u32 stride_bytes,
	dpu_table_batch_u32 entry_count, int order,
	dpu_table_batch_u32 max_payload_bytes,
	dpu_table_batch_submit_once_fn submit_once,
	struct dpu_table_batch_progress *progress)
{
	const unsigned char *entry_data = entries;
	dpu_table_batch_u64 total_bytes;
	dpu_table_batch_u64 last_delta;
	dpu_table_batch_u64 last_byte_delta;
	dpu_table_batch_u32 entries_per_request;
	dpu_table_batch_u32 submitted = 0;

	if (progress) {
		progress->committed_entries = 0;
		progress->failed_index = 0;
		progress->failed_offset = first_offset;
		progress->original_result = DPU_TABLE_BATCH_CORE_FRONTDOOR;
		progress->final_result = DPU_TABLE_BATCH_CORE_FRONTDOOR;
	}

	if (!context || !entry_data || !entry_bytes || !entry_count ||
	    !max_payload_bytes || !submit_once || stride_bytes < entry_bytes ||
	    entry_bytes > max_payload_bytes ||
	    (order != DPU_TABLE_BATCH_CORE_LOW_TO_HIGH &&
	     order != DPU_TABLE_BATCH_CORE_HIGH_TO_LOW))
		return DPU_TABLE_BATCH_CORE_FRONTDOOR;

	total_bytes = (dpu_table_batch_u64)entry_bytes * entry_count;
	if (entry_count != 0 && total_bytes / entry_count != entry_bytes)
		return DPU_TABLE_BATCH_CORE_FRONTDOOR;
	if (total_bytes > DPU_TABLE_BATCH_SIZE_MAX)
		return DPU_TABLE_BATCH_CORE_FRONTDOOR;

	last_delta = (dpu_table_batch_u64)(entry_count - 1) * stride_bytes;
	if (entry_count > 1 && last_delta / (entry_count - 1) != stride_bytes)
		return DPU_TABLE_BATCH_CORE_FRONTDOOR;
	if (last_delta > DPU_TABLE_BATCH_U64_MAX - (entry_bytes - 1))
		return DPU_TABLE_BATCH_CORE_FRONTDOOR;
	last_byte_delta = last_delta + entry_bytes - 1;
	if (first_offset > DPU_TABLE_BATCH_U64_MAX - last_byte_delta)
		return DPU_TABLE_BATCH_CORE_FRONTDOOR;

	entries_per_request = max_payload_bytes / entry_bytes;
	while (submitted < entry_count) {
		dpu_table_batch_u32 remaining = entry_count - submitted;
		dpu_table_batch_u32 request_entries =
			remaining < entries_per_request ?
			remaining : entries_per_request;
		dpu_table_batch_u32 payload_bytes = request_entries * entry_bytes;
		dpu_table_batch_u64 offset = first_offset +
			(dpu_table_batch_u64)submitted * stride_bytes;
		int result = submit_once(
			context, offset,
			entry_data + (size_t)submitted * entry_bytes,
			payload_bytes, order);

		if (progress) {
			progress->failed_index = submitted;
			progress->failed_offset = offset;
			progress->original_result = result;
			progress->final_result = result;
		}

		if (result == DPU_TABLE_BATCH_CORE_SUCCESS) {
			submitted += request_entries;
			if (progress)
				progress->committed_entries = submitted;
			continue;
		}
		if (result == DPU_TABLE_BATCH_CORE_FRONTDOOR && submitted != 0) {
			if (progress)
				progress->final_result = DPU_TABLE_BATCH_CORE_ERROR;
			return DPU_TABLE_BATCH_CORE_ERROR;
		}
		return result;
	}
	if (progress) {
		progress->failed_index = entry_count;
		progress->failed_offset = 0;
		progress->original_result = DPU_TABLE_BATCH_CORE_SUCCESS;
		progress->final_result = DPU_TABLE_BATCH_CORE_SUCCESS;
	}
	return DPU_TABLE_BATCH_CORE_SUCCESS;
}

#endif /* __DPU_COSIM_TABLE_BATCH_CORE_H */
