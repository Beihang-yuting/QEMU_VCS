#include "table_ctrl_core.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__,         \
                    #condition);                                               \
            abort();                                                           \
        }                                                                      \
    } while (0)

enum {
    TEST_SLOT_BYTES = 512,
    TEST_PAYLOAD_BYTES = 48,
    TEST_TIMEOUT_MS = 50,
};

static const uint64_t test_slot_address = UINT64_C(0x100000);

typedef struct {
    uint8_t memory[TEST_SLOT_BYTES];
    cosim_table_ctrl_core_t *core;
    cosim_table_route_entry_t route;
    cosim_table_status_t rpc_status;
    cosim_table_completion_t rpc_completion;
    int active;
    int active_calls;
    int deactivate_after_first_check;
    int route_present;
    int dma_reads;
    int dma_writes;
    int result_written;
    int acquire_count;
    uint32_t state_after_acquire;
    int release_count;
    int release_after_result;
    int complete_count;
    int reenter;
    int read_called;
    int write_called;
    uint8_t expected_operation;
    uint64_t expected_offset;
    cosim_table_status_t reenter_status;
    cosim_table_write_begin_t observed_request;
    cosim_table_read_dword_t observed_read;
    uint8_t observed_payload[TEST_PAYLOAD_BYTES];
    char events[32];
    size_t event_count;
} fake_context_t;

static void record_event(fake_context_t *fake, char event)
{
    CHECK(fake->event_count + 1 < sizeof(fake->events));
    fake->events[fake->event_count++] = event;
    fake->events[fake->event_count] = '\0';
}

static cosim_table_slot_hdr_t *fake_header(fake_context_t *fake)
{
    return (cosim_table_slot_hdr_t *)fake->memory;
}

static ssize_t fake_dma_read(void *opaque, uint64_t address, void *buffer,
                             size_t bytes)
{
    fake_context_t *fake = opaque;
    uint64_t displacement;

    fake->dma_reads++;
    if (address < test_slot_address)
        return -1;
    displacement = address - test_slot_address;
    if (displacement > sizeof(fake->memory) ||
        bytes > sizeof(fake->memory) - (size_t)displacement)
        return -1;
    if (displacement == 0 && bytes == sizeof(cosim_u32))
        record_event(fake, 'S');
    if (displacement == 0 && bytes == sizeof(cosim_table_slot_hdr_t))
        record_event(fake, 'H');
    if (fake->reenter && displacement == 0 &&
        bytes == sizeof(cosim_table_slot_hdr_t)) {
        fake->reenter = 0;
        fake->reenter_status = cosim_table_ctrl_process_slot(
            fake->core, test_slot_address, TEST_SLOT_BYTES, TEST_TIMEOUT_MS);
    }
    memcpy(buffer, fake->memory + displacement, bytes);
    return (ssize_t)bytes;
}

static ssize_t fake_dma_write(void *opaque, uint64_t address,
                              const void *buffer, size_t bytes)
{
    fake_context_t *fake = opaque;
    uint64_t displacement;

    fake->dma_writes++;
    if (address < test_slot_address)
        return -1;
    displacement = address - test_slot_address;
    if (displacement > sizeof(fake->memory) ||
        bytes > sizeof(fake->memory) - (size_t)displacement)
        return -1;

    if (displacement == offsetof(cosim_table_slot_hdr_t, result_status)) {
        CHECK(bytes == sizeof(cosim_u32) * 5u);
        record_event(fake, 'R');
        fake->result_written = 1;
    }
    if (displacement == offsetof(cosim_table_slot_hdr_t, state) &&
        bytes == sizeof(cosim_u32)) {
        uint32_t state =
            cosim_table_le32_to_cpu(*(const cosim_u32 *)buffer);

        if (state == COSIM_TABLE_SLOT_BUSY) {
            record_event(fake, 'B');
        } else if (state == COSIM_TABLE_SLOT_COMPLETE) {
            CHECK(fake->result_written);
            CHECK(fake->release_after_result);
            record_event(fake, 'C');
            fake->complete_count++;
        }
    }
    memcpy(fake->memory + displacement, buffer, bytes);
    return (ssize_t)bytes;
}

static void fake_acquire(void *opaque)
{
    fake_context_t *fake = opaque;

    fake->acquire_count++;
    record_event(fake, 'A');
    if (fake->state_after_acquire != 0) {
        fake_header(fake)->state =
            cosim_table_cpu_to_le32(fake->state_after_acquire);
    }
}

static void fake_release(void *opaque)
{
    fake_context_t *fake = opaque;

    fake->release_count++;
    record_event(fake, 'L');
    if (fake->result_written)
        fake->release_after_result = 1;
}

static int fake_target_active(void *opaque,
                              const cosim_table_target_t *target)
{
    fake_context_t *fake = opaque;

    CHECK(cosim_table_le16_to_cpu(target->rc_id) == 1);
    CHECK(cosim_table_le16_to_cpu(target->device_instance) == 2);
    fake->active_calls++;
    if (fake->deactivate_after_first_check && fake->active_calls == 1) {
        fake->active = 0;
        return 1;
    }
    return fake->active;
}

static const cosim_table_route_entry_t *fake_match(
    void *opaque, const cosim_table_target_t *target, uint64_t offset,
    uint8_t operation)
{
    fake_context_t *fake = opaque;

    CHECK(target->target_type == COSIM_TABLE_TARGET_PF);
    CHECK(target->pf_index == 0);
    CHECK(target->bar_index == 0);
    CHECK(offset == fake->expected_offset);
    CHECK(operation == fake->expected_operation);
    return fake->route_present ? &fake->route : NULL;
}

static cosim_table_status_t fake_write(
    void *opaque, const cosim_table_write_begin_t *request,
    const uint8_t *payload, cosim_table_completion_t *completion,
    int timeout_ms)
{
    fake_context_t *fake = opaque;

    CHECK(timeout_ms == TEST_TIMEOUT_MS);
    fake->write_called++;
    fake->observed_request = *request;
    memcpy(fake->observed_payload, payload, sizeof(fake->observed_payload));
    *completion = fake->rpc_completion;
    return fake->rpc_status;
}

static cosim_table_status_t fake_read_dword(
    void *opaque, const cosim_table_read_dword_t *request,
    cosim_table_completion_t *completion, int timeout_ms)
{
    fake_context_t *fake = opaque;

    CHECK(timeout_ms == TEST_TIMEOUT_MS);
    fake->read_called++;
    fake->observed_read = *request;
    *completion = fake->rpc_completion;
    return fake->rpc_status;
}

static void setup(fake_context_t *fake, cosim_table_ctrl_core_t *core)
{
    cosim_table_ctrl_ops_t ops;
    cosim_table_slot_hdr_t *header;
    size_t i;

    memset(fake, 0, sizeof(*fake));
    memset(core, 0, sizeof(*core));
    fake->core = core;
    fake->active = 1;
    fake->route_present = 1;
    fake->expected_operation = COSIM_TABLE_OP_WRITE;
    fake->expected_offset = UINT64_C(0x120);
    fake->rpc_status = COSIM_TABLE_ST_SUCCESS;
    fake->rpc_completion.status = COSIM_TABLE_ST_SUCCESS;
    fake->rpc_completion.failed_index = UINT32_MAX;
    fake->rpc_completion.committed_count = 3;

    fake->route.route_id = cosim_table_cpu_to_le32(7);
    fake->route.target.rc_id = cosim_table_cpu_to_le16(1);
    fake->route.target.device_instance = cosim_table_cpu_to_le16(2);
    fake->route.target.target_type = COSIM_TABLE_TARGET_PF;
    fake->route.target.pf_index = 0;
    fake->route.target.bar_index = 0;
    fake->route.operation_mask = cosim_table_cpu_to_le32(COSIM_TABLE_OP_WRITE);
    fake->route.start_offset = cosim_table_cpu_to_le64(UINT64_C(0x100));
    fake->route.end_offset = cosim_table_cpu_to_le64(UINT64_C(0x200));
    fake->route.entry_bytes = cosim_table_cpu_to_le32(16);
    fake->route.stride_bytes = cosim_table_cpu_to_le32(16);
    fake->route.index_base = cosim_table_cpu_to_le32(10);

    header = fake_header(fake);
    header->state = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_READY);
    header->header_version =
        cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_HEADER_VERSION);
    header->transaction_id =
        cosim_table_cpu_to_le64(UINT64_C(0x1122334455667788));
    cosim_table_target_set_identity(&header->target, 1, 2, 3, 0x18, 9);
    header->target.target_type = COSIM_TABLE_TARGET_PF;
    header->target.pf_index = 0;
    header->target.bar_index = 0;
    header->bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x120));
    header->payload_bytes = cosim_table_cpu_to_le32(TEST_PAYLOAD_BYTES);
    header->payload_offset =
        cosim_table_cpu_to_le32(sizeof(cosim_table_slot_hdr_t));
    header->result_status = cosim_table_cpu_to_le32(UINT32_MAX);
    header->result_failed_index = cosim_table_cpu_to_le32(UINT32_MAX);
    for (i = 0; i < TEST_PAYLOAD_BYTES; i++)
        fake->memory[sizeof(*header) + i] = (uint8_t)(i * 7u + 3u);

    memset(&ops, 0, sizeof(ops));
    ops.dma_read = fake_dma_read;
    ops.dma_write = fake_dma_write;
    ops.acquire_barrier = fake_acquire;
    ops.release_barrier = fake_release;
    ops.target_active = fake_target_active;
    ops.match = fake_match;
    ops.write = fake_write;
    ops.read_dword = fake_read_dword;
    CHECK(cosim_table_ctrl_core_init(core, &ops, fake,
                                     TEST_PAYLOAD_BYTES) == 0);
    cosim_table_ctrl_core_set_ready(core, 1);
}

static void check_completion(fake_context_t *fake,
                             cosim_table_status_t expected_status,
                             uint32_t expected_failed,
                             uint32_t expected_committed)
{
    const cosim_table_slot_hdr_t *header = fake_header(fake);

    CHECK(cosim_table_le32_to_cpu(header->state) ==
          COSIM_TABLE_SLOT_COMPLETE);
    CHECK(cosim_table_le32_to_cpu(header->result_status) == expected_status);
    CHECK(cosim_table_le32_to_cpu(header->result_failed_index) ==
          expected_failed);
    CHECK(cosim_table_le32_to_cpu(header->result_committed_count) ==
          expected_committed);
    CHECK(fake->result_written == 1);
    CHECK(fake->complete_count == 1);
}

static void test_not_ready_claims_and_completes_slot(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    cosim_table_ctrl_core_set_ready(&core, 0);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_NOT_READY);
    CHECK(fake.dma_reads == 2);
    CHECK(strcmp(fake.events, "SAHBRLC") == 0);
    check_completion(&fake, COSIM_TABLE_ST_NOT_READY, UINT32_MAX, 0);
}

static void test_malformed_reserved_bytes_complete_protocol(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake_header(&fake)->reserved[17] = 1;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    check_completion(&fake, COSIM_TABLE_ST_PROTOCOL, UINT32_MAX, 0);
}

static void test_payload_bounds_complete_protocol(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake_header(&fake)->payload_offset = cosim_table_cpu_to_le32(500);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    check_completion(&fake, COSIM_TABLE_ST_PROTOCOL, UINT32_MAX, 0);
}

static void test_slot_address_size_overflow_and_owner_states(void)
{
    const uint32_t owner_states[] = {
        COSIM_TABLE_SLOT_FREE,
        COSIM_TABLE_SLOT_BUSY,
        COSIM_TABLE_SLOT_COMPLETE,
    };
    const cosim_table_status_t owner_statuses[] = {
        COSIM_TABLE_ST_PROTOCOL,
        COSIM_TABLE_ST_SLOT_BUSY,
        COSIM_TABLE_ST_PROTOCOL,
    };
    fake_context_t fake;
    cosim_table_ctrl_core_t core;
    size_t i;

    setup(&fake, &core);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address + 1,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    CHECK(fake.dma_reads == 0 && fake.complete_count == 0);

    setup(&fake, &core);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        sizeof(cosim_table_slot_hdr_t) - 1,
                                        TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    CHECK(fake.dma_reads == 0 && fake.complete_count == 0);

    setup(&fake, &core);
    CHECK(cosim_table_ctrl_process_slot(&core, UINT64_MAX - 7,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    CHECK(fake.dma_reads == 0 && fake.complete_count == 0);

    for (i = 0; i < sizeof(owner_states) / sizeof(owner_states[0]); i++) {
        setup(&fake, &core);
        fake_header(&fake)->state = cosim_table_cpu_to_le32(owner_states[i]);
        CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                            TEST_SLOT_BYTES,
                                            TEST_TIMEOUT_MS) ==
              owner_statuses[i]);
        CHECK(fake.complete_count == 0);
        CHECK(strcmp(fake.events, "S") == 0);
        CHECK(fake.acquire_count == 0);
    }
}

static void test_invalid_offset_index_count_and_payload_combinations(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.expected_offset = UINT64_C(0x121);
    fake_header(&fake)->bar_offset = cosim_table_cpu_to_le64(fake.expected_offset);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_UNSUPPORTED);
    check_completion(&fake, COSIM_TABLE_ST_UNSUPPORTED, UINT32_MAX, 0);

    setup(&fake, &core);
    fake_header(&fake)->payload_bytes = cosim_table_cpu_to_le32(47);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_UNSUPPORTED);
    check_completion(&fake, COSIM_TABLE_ST_UNSUPPORTED, UINT32_MAX, 0);

    setup(&fake, &core);
    fake.expected_offset = UINT64_C(0x110);
    fake_header(&fake)->bar_offset = cosim_table_cpu_to_le64(fake.expected_offset);
    fake_header(&fake)->payload_bytes = cosim_table_cpu_to_le32(16);
    fake.route.index_base = cosim_table_cpu_to_le32(UINT32_MAX);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_UNSUPPORTED);
    check_completion(&fake, COSIM_TABLE_ST_UNSUPPORTED, UINT32_MAX, 0);

    setup(&fake, &core);
    fake.expected_offset = UINT64_C(0x1f0);
    fake_header(&fake)->bar_offset = cosim_table_cpu_to_le64(fake.expected_offset);
    fake_header(&fake)->payload_bytes = cosim_table_cpu_to_le32(32);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_UNSUPPORTED);
    check_completion(&fake, COSIM_TABLE_ST_UNSUPPORTED, UINT32_MAX, 0);

    setup(&fake, &core);
    fake.expected_offset = UINT64_MAX - 100;
    fake_header(&fake)->bar_offset = cosim_table_cpu_to_le64(fake.expected_offset);
    fake_header(&fake)->payload_bytes = cosim_table_cpu_to_le32(2);
    fake.route.start_offset = cosim_table_cpu_to_le64(fake.expected_offset);
    fake.route.end_offset = cosim_table_cpu_to_le64(UINT64_MAX);
    fake.route.entry_bytes = cosim_table_cpu_to_le32(1);
    fake.route.stride_bytes = cosim_table_cpu_to_le32(UINT32_MAX);
    fake.route.index_base = 0;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_UNSUPPORTED);
    check_completion(&fake, COSIM_TABLE_ST_UNSUPPORTED, UINT32_MAX, 0);

    setup(&fake, &core);
    fake_header(&fake)->payload_offset =
        cosim_table_cpu_to_le32(sizeof(cosim_table_slot_hdr_t) + 1);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    check_completion(&fake, COSIM_TABLE_ST_PROTOCOL, UINT32_MAX, 0);
}

static void test_local_slot_contention_is_safe(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.reenter = 1;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(fake.reenter_status == COSIM_TABLE_ST_SLOT_BUSY);
    check_completion(&fake, COSIM_TABLE_ST_SUCCESS, UINT32_MAX, 3);
}

static void test_header_snapshot_rechecks_ready_state(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.state_after_acquire = COSIM_TABLE_SLOT_BUSY;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_SLOT_BUSY);
    CHECK(strcmp(fake.events, "SAH") == 0);
    CHECK(fake.dma_writes == 0);
    CHECK(fake.write_called == 0);
    CHECK(fake.complete_count == 0);
}

static void test_no_route_completes_without_rpc(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.route_present = 0;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_NO_ROUTE);
    check_completion(&fake, COSIM_TABLE_ST_NO_ROUTE, UINT32_MAX, 0);
}

static void test_three_entry_success_uses_route_geometry(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;
    size_t i;

    setup(&fake, &core);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_SUCCESS);
    check_completion(&fake, COSIM_TABLE_ST_SUCCESS, UINT32_MAX, 3);
    CHECK(strcmp(fake.events, "SAHBRLC") == 0);
    CHECK(cosim_table_le32_to_cpu(fake.observed_request.route_id) == 7);
    CHECK(cosim_table_le32_to_cpu(fake.observed_request.entry_index) == 12);
    CHECK(cosim_table_le32_to_cpu(fake.observed_request.payload_bytes) ==
          TEST_PAYLOAD_BYTES);
    CHECK(cosim_table_le64_to_cpu(fake.observed_request.bar_offset) ==
          UINT64_C(0x120));
    for (i = 0; i < TEST_PAYLOAD_BYTES; i++)
        CHECK(fake.observed_payload[i] == (uint8_t)(i * 7u + 3u));
}

static void test_partial_exec_error_is_not_replayable(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.rpc_status = COSIM_TABLE_ST_EXEC_ERROR;
    fake.rpc_completion.status = COSIM_TABLE_ST_EXEC_ERROR;
    fake.rpc_completion.failed_index = 13;
    fake.rpc_completion.committed_count = 1;
    fake.rpc_completion.handler_error = 77;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_EXEC_ERROR);
    check_completion(&fake, COSIM_TABLE_ST_EXEC_ERROR, 13, 1);
    CHECK(cosim_table_le32_to_cpu(
              fake_header(&fake)->result_handler_error) == 77);
    CHECK(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_EXEC_ERROR));
}

static void test_timeout_and_protocol_complete_without_replay(void)
{
    const cosim_table_status_t statuses[] = {
        COSIM_TABLE_ST_TIMEOUT,
        COSIM_TABLE_ST_PROTOCOL,
    };
    size_t i;

    for (i = 0; i < sizeof(statuses) / sizeof(statuses[0]); i++) {
        fake_context_t fake;
        cosim_table_ctrl_core_t core;

        setup(&fake, &core);
        fake.rpc_status = statuses[i];
        fake.rpc_completion.status = statuses[i];
        fake.rpc_completion.failed_index = UINT32_MAX;
        fake.rpc_completion.committed_count = 0;
        CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                            TEST_SLOT_BYTES,
                                            TEST_TIMEOUT_MS) == statuses[i]);
        check_completion(&fake, statuses[i], UINT32_MAX, 0);
        CHECK(!cosim_table_status_may_frontdoor(statuses[i]));
    }
}

static void test_remote_slot_busy_is_hard_protocol_error(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.rpc_status = COSIM_TABLE_ST_SLOT_BUSY;
    fake.rpc_completion.status = COSIM_TABLE_ST_SLOT_BUSY;
    fake.rpc_completion.failed_index = UINT32_MAX;
    fake.rpc_completion.committed_count = 0;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    check_completion(&fake, COSIM_TABLE_ST_PROTOCOL, UINT32_MAX, 0);
    CHECK(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_PROTOCOL));
}

static void test_malformed_success_completion_is_protocol(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.rpc_completion.committed_count = 2;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    check_completion(&fake, COSIM_TABLE_ST_PROTOCOL, UINT32_MAX, 0);
}

static void test_read_slot_returns_one_dword(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.expected_operation = COSIM_TABLE_OP_READ_DWORD;
    fake.route.operation_mask = cosim_table_cpu_to_le32(
        COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD);
    fake_header(&fake)->payload_bytes = 0;
    fake.rpc_completion.committed_count = 0;
    fake.rpc_completion.returned_dword = UINT32_C(0x44332211);
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_SUCCESS);
    check_completion(&fake, COSIM_TABLE_ST_SUCCESS, UINT32_MAX, 0);
    CHECK(fake.read_called == 1);
    CHECK(cosim_table_le32_to_cpu(fake.observed_read.route_id) == 7);
    CHECK(cosim_table_le64_to_cpu(fake.observed_read.bar_offset) ==
          UINT64_C(0x120));
    CHECK(cosim_table_le32_to_cpu(fake_header(&fake)->result_dword) ==
          UINT32_C(0x44332211));
}

static void test_generation_change_after_payload_read_returns_target_gone(void)
{
    fake_context_t fake;
    cosim_table_ctrl_core_t core;

    setup(&fake, &core);
    fake.deactivate_after_first_check = 1;
    CHECK(cosim_table_ctrl_process_slot(&core, test_slot_address,
                                        TEST_SLOT_BYTES, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_TARGET_GONE);
    check_completion(&fake, COSIM_TABLE_ST_TARGET_GONE, UINT32_MAX, 0);
    CHECK(fake.active_calls == 2);
    CHECK(fake.write_called == 0);
    CHECK(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_TARGET_GONE));
}

static void test_only_proven_no_commit_statuses_allow_replay(void)
{
    int status;

    for (status = COSIM_TABLE_ST_SUCCESS;
         status <= COSIM_TABLE_ST_PROTOCOL; status++) {
        int expected = status == COSIM_TABLE_ST_NOT_READY ||
                       status == COSIM_TABLE_ST_NO_ROUTE ||
                       status == COSIM_TABLE_ST_UNSUPPORTED ||
                       status == COSIM_TABLE_ST_SLOT_BUSY;
        CHECK(!!cosim_table_status_may_frontdoor(
                  (cosim_table_status_t)status) == expected);
    }
}

static void test_logical_bar_read_decode_and_extract(void)
{
    const uint64_t sizes[6] = { UINT64_C(0x1000), 0, UINT64_C(0x2000),
                                0, UINT64_C(0x3000), 0 };
    cosim_table_target_t target;
    uint64_t aligned;
    uint64_t aperture;
    uint8_t byte_offset;
    uint8_t pci_region;

    CHECK(cosim_table_map_logical_bar(sizes, 0, &pci_region, &aperture) == 0);
    CHECK(pci_region == 0 && aperture == UINT64_C(0x1000));
    CHECK(cosim_table_map_logical_bar(sizes, 1, &pci_region, &aperture) == 0);
    CHECK(pci_region == 2 && aperture == UINT64_C(0x2000));
    CHECK(cosim_table_map_logical_bar(sizes, 2, &pci_region, &aperture) != 0);

    memset(&target, 0xa5, sizeof(target));
    CHECK(cosim_table_decode_read(sizes, 4, 9, 0, 2, 0,
                                  UINT64_C(0x103), 1, &target, &aligned,
                                  &byte_offset));
    CHECK(cosim_table_le16_to_cpu(target.rc_id) == 4);
    CHECK(cosim_table_le16_to_cpu(target.device_instance) == 9);
    CHECK(target.target_type == COSIM_TABLE_TARGET_PF);
    CHECK(target.pf_index == 0 && target.bar_index == 1);
    CHECK(aligned == UINT64_C(0x100) && byte_offset == 3);
    CHECK(cosim_table_extract_read(UINT32_C(0x44332211), 0, 4) ==
          UINT64_C(0x44332211));
    CHECK(cosim_table_extract_read(UINT32_C(0x44332211), 1, 2) == 0x3322);
    CHECK(cosim_table_extract_read(UINT32_C(0x44332211), 3, 1) == 0x44);

    CHECK(!cosim_table_decode_read(sizes, 4, 9, 1, 2, 0, 0, 4,
                                   &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(sizes, 4, 9, 0, 2, 1, 0, 4,
                                   &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(sizes, 4, 9, 0, 2, 0, 3, 2,
                                   &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(sizes, 4, 9, 0, 2, 0, 0, 8,
                                   &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(sizes, 4, 9, 0, 2, 0,
                                   UINT64_C(0x1fff), 2, &target, &aligned,
                                   &byte_offset));
}

int main(void)
{
    test_not_ready_claims_and_completes_slot();
    test_malformed_reserved_bytes_complete_protocol();
    test_payload_bounds_complete_protocol();
    test_slot_address_size_overflow_and_owner_states();
    test_invalid_offset_index_count_and_payload_combinations();
    test_local_slot_contention_is_safe();
    test_header_snapshot_rechecks_ready_state();
    test_no_route_completes_without_rpc();
    test_three_entry_success_uses_route_geometry();
    test_partial_exec_error_is_not_replayable();
    test_timeout_and_protocol_complete_without_replay();
    test_remote_slot_busy_is_hard_protocol_error();
    test_malformed_success_completion_is_protocol();
    test_read_slot_returns_one_dword();
    test_generation_change_after_payload_read_returns_target_gone();
    test_only_proven_no_commit_statuses_allow_replay();
    test_logical_bar_read_decode_and_extract();
    puts("table controller core tests: PASS");
    return 0;
}
