#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "cosim_table_batch_core.h"

#define MAX_CALLS 32

struct call_record {
    uint64_t offset;
    const unsigned char *data;
    uint32_t payload_bytes;
    int order;
};

struct fixture {
    struct call_record calls[MAX_CALLS];
    int results[MAX_CALLS];
    unsigned int call_count;
    unsigned int result_count;
};

static int submit_once(void *opaque, dpu_table_batch_u64 offset,
                       const void *data,
                       dpu_table_batch_u32 payload_bytes, int order)
{
    struct fixture *fixture = opaque;
    unsigned int call = fixture->call_count++;

    assert(call < MAX_CALLS);
    fixture->calls[call].offset = offset;
    fixture->calls[call].data = data;
    fixture->calls[call].payload_bytes = payload_bytes;
    fixture->calls[call].order = order;
    return call < fixture->result_count ? fixture->results[call] :
           DPU_TABLE_BATCH_CORE_SUCCESS;
}

static void fill_payload(unsigned char *payload, size_t bytes)
{
    size_t index;

    for (index = 0; index < bytes; ++index)
        payload[index] = (unsigned char)(index * 17u + 3u);
}

static void expect_chunks(uint32_t entry_bytes, uint32_t stride_bytes,
                          uint32_t entry_count, uint32_t slot_bytes,
                          int order)
{
    unsigned char payload[4096];
    struct fixture fixture = {0};
    uint32_t entries_per_call = slot_bytes / entry_bytes;
    uint32_t submitted = 0;
    unsigned int call;

    assert((uint64_t)entry_bytes * entry_count <= sizeof(payload));
    fill_payload(payload, (size_t)entry_bytes * entry_count);
    assert(dpu_table_batch_core(&fixture, 0x1000, payload, entry_bytes,
                                stride_bytes, entry_count, order, slot_bytes,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_SUCCESS);
    assert(fixture.call_count ==
           (entry_count + entries_per_call - 1) / entries_per_call);

    for (call = 0; call < fixture.call_count; ++call) {
        uint32_t remaining = entry_count - submitted;
        uint32_t entries = remaining < entries_per_call ?
                           remaining : entries_per_call;
        uint32_t bytes = entries * entry_bytes;

        assert(fixture.calls[call].offset ==
               0x1000 + (uint64_t)submitted * stride_bytes);
        assert(fixture.calls[call].data == payload +
               (size_t)submitted * entry_bytes);
        assert(fixture.calls[call].payload_bytes == bytes);
        assert(fixture.calls[call].payload_bytes % entry_bytes == 0);
        assert(fixture.calls[call].order == order);
        assert(memcmp(fixture.calls[call].data,
                      payload + (size_t)submitted * entry_bytes,
                      bytes) == 0);
        submitted += entries;
    }
    assert(submitted == entry_count);
}

static void test_entry_aligned_chunking(void)
{
    expect_chunks(16, 32, 11, 47, DPU_TABLE_BATCH_CORE_LOW_TO_HIGH);
    expect_chunks(32, 64, 7, 100, DPU_TABLE_BATCH_CORE_HIGH_TO_LOW);
    expect_chunks(128, 256, 9, 300, DPU_TABLE_BATCH_CORE_HIGH_TO_LOW);
}

static void test_payload_larger_than_slot_uses_multiple_requests(void)
{
    unsigned char payload[128 * 17];
    struct fixture fixture = {0};
    unsigned int call;

    fill_payload(payload, sizeof(payload));
    assert(dpu_table_batch_core(
               &fixture, 0x8000, payload, 128, 192, 17,
               DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 512, submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_SUCCESS);
    assert(fixture.call_count == 5);
    for (call = 0; call < 4; ++call)
        assert(fixture.calls[call].payload_bytes == 512);
    assert(fixture.calls[4].payload_bytes == 128);
    assert(fixture.calls[4].offset == 0x8000 + 16u * 192u);
    assert(fixture.calls[4].data == payload + 16u * 128u);
}

static void test_errors_stop_without_later_requests(void)
{
    unsigned char payload[16 * 10] = {0};
    struct fixture fixture = {0};

    fixture.results[0] = DPU_TABLE_BATCH_CORE_SUCCESS;
    fixture.results[1] = DPU_TABLE_BATCH_CORE_ERROR;
    fixture.result_count = 2;
    assert(dpu_table_batch_core(
               &fixture, 0, payload, 16, 32, 10,
               DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 32, submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_ERROR);
    assert(fixture.call_count == 2);

    memset(&fixture, 0, sizeof(fixture));
    fixture.results[0] = DPU_TABLE_BATCH_CORE_SUCCESS;
    fixture.results[1] = DPU_TABLE_BATCH_CORE_FRONTDOOR;
    fixture.result_count = 2;
    assert(dpu_table_batch_core(
               &fixture, 0, payload, 16, 32, 10,
               DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 32, submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_ERROR);
    assert(fixture.call_count == 2);

    memset(&fixture, 0, sizeof(fixture));
    fixture.results[0] = DPU_TABLE_BATCH_CORE_FRONTDOOR;
    fixture.result_count = 1;
    assert(dpu_table_batch_core(
               &fixture, 0, payload, 16, 32, 10,
               DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 32, submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(fixture.call_count == 1);
}

static void test_hard_and_partial_frontdoor_errors_report_progress(void)
{
    unsigned char payload[16 * 10] = {0};
    struct fixture fixture = {0};
    struct dpu_table_batch_progress progress;

    fixture.results[0] = DPU_TABLE_BATCH_CORE_SUCCESS;
    fixture.results[1] = DPU_TABLE_BATCH_CORE_ERROR;
    fixture.result_count = 2;
    assert(dpu_table_batch_core(
               &fixture, 0x1000, payload, 16, 32, 10,
               DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 32, submit_once,
               &progress) == DPU_TABLE_BATCH_CORE_ERROR);
    assert(progress.committed_entries == 2);
    assert(progress.failed_index == 2);
    assert(progress.failed_offset == 0x1040);
    assert(progress.original_result == DPU_TABLE_BATCH_CORE_ERROR);
    assert(progress.final_result == DPU_TABLE_BATCH_CORE_ERROR);

    memset(&fixture, 0, sizeof(fixture));
    fixture.results[0] = DPU_TABLE_BATCH_CORE_SUCCESS;
    fixture.results[1] = DPU_TABLE_BATCH_CORE_FRONTDOOR;
    fixture.result_count = 2;
    assert(dpu_table_batch_core(
               &fixture, 0x2000, payload, 16, 32, 10,
               DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 32, submit_once,
               &progress) == DPU_TABLE_BATCH_CORE_ERROR);
    assert(progress.committed_entries == 2);
    assert(progress.failed_index == 2);
    assert(progress.failed_offset == 0x2040);
    assert(progress.original_result == DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(progress.final_result == DPU_TABLE_BATCH_CORE_ERROR);
}

static void test_invalid_and_overflow_inputs_do_not_submit(void)
{
    unsigned char payload[256] = {0};
    struct fixture fixture = {0};

    assert(dpu_table_batch_core(&fixture, 0, payload, 64, 64, 1,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 63,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(dpu_table_batch_core(&fixture, UINT64_MAX - 15, payload,
                                16, 32, 2,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 64,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(dpu_table_batch_core(&fixture, UINT64_MAX - 15, payload,
                                16, 32, 1,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 64,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_SUCCESS);
    assert(fixture.call_count == 1);
    memset(&fixture, 0, sizeof(fixture));
    assert(dpu_table_batch_core(&fixture, UINT64_MAX - 14, payload,
                                16, 32, 1,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 64,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(dpu_table_batch_core(&fixture, UINT64_MAX, payload, UINT32_MAX,
                                UINT32_MAX, UINT32_MAX,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, UINT32_MAX,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(dpu_table_batch_core(&fixture, 0, payload, 16, 15, 1,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 64,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(dpu_table_batch_core(&fixture, 0, payload, 16, 16, 0,
                                DPU_TABLE_BATCH_CORE_LOW_TO_HIGH, 64,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(dpu_table_batch_core(&fixture, 0, payload, 16, 16, 1, 7, 64,
                                submit_once, NULL) ==
           DPU_TABLE_BATCH_CORE_FRONTDOOR);
    assert(fixture.call_count == 0);
}

int main(void)
{
    test_entry_aligned_chunking();
    test_payload_larger_than_slot_uses_multiple_requests();
    test_errors_stop_without_later_requests();
    test_hard_and_partial_frontdoor_errors_report_progress();
    test_invalid_and_overflow_inputs_do_not_submit();
    return 0;
}
