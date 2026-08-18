#include "table_ctrl_core.h"

#include "cosim_table_route.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int bytes_are_zero(const void *data, size_t bytes)
{
    const unsigned char *cursor = data;
    size_t i;

    for (i = 0; i < bytes; i++) {
        if (cursor[i] != 0)
            return 0;
    }
    return 1;
}

int cosim_table_ctrl_core_init(cosim_table_ctrl_core_t *core,
                               const cosim_table_ctrl_ops_t *ops,
                               void *opaque, uint32_t max_payload_bytes)
{
    if (core == NULL || ops == NULL || max_payload_bytes == 0 ||
        ops->dma_read == NULL || ops->dma_write == NULL ||
        ops->release_barrier == NULL || ops->target_active == NULL ||
        ops->match == NULL || ops->write == NULL ||
        ops->read_dword == NULL)
        return -1;
    memset(core, 0, sizeof(*core));
    core->ops = *ops;
    core->opaque = opaque;
    core->max_payload_bytes = max_payload_bytes;
    atomic_init(&core->ready, 0);
    atomic_init(&core->processing, 0);
    return 0;
}

void cosim_table_ctrl_core_set_ready(cosim_table_ctrl_core_t *core, int ready)
{
    if (core != NULL)
        atomic_store_explicit(&core->ready, ready != 0,
                              memory_order_release);
}

int cosim_table_map_logical_bar(const uint64_t bar_sizes[6],
                                uint8_t logical_bar, uint8_t *pci_region,
                                uint64_t *aperture_bytes)
{
    unsigned int physical;
    uint8_t logical = 0;

    if (bar_sizes == NULL || pci_region == NULL || aperture_bytes == NULL)
        return -1;
    for (physical = 0; physical < 6; physical++) {
        if (bar_sizes[physical] == 0)
            continue;
        if (logical == logical_bar) {
            *pci_region = (uint8_t)physical;
            *aperture_bytes = bar_sizes[physical];
            return 0;
        }
        logical++;
    }
    return -1;
}

int cosim_table_decode_read(const uint64_t bar_sizes[6], uint16_t rc_id,
                            uint16_t device_instance, uint8_t pf_index,
                            uint8_t pci_region, int is_vf,
                            uint64_t bar_offset, unsigned size,
                            cosim_table_target_t *target,
                            uint64_t *aligned_offset, uint8_t *byte_offset)
{
    unsigned int physical;
    uint8_t logical = 0;
    uint64_t aperture;
    uint8_t within_dword;

    if (bar_sizes == NULL || target == NULL || aligned_offset == NULL ||
        byte_offset == NULL || pf_index != 0 || is_vf || pci_region >= 6 ||
        bar_sizes[pci_region] == 0 ||
        (size != 1 && size != 2 && size != 4))
        return 0;
    for (physical = 0; physical < pci_region; physical++) {
        if (bar_sizes[physical] != 0)
            logical++;
    }
    if (logical > 1)
        return 0;
    aperture = bar_sizes[pci_region];
    within_dword = (uint8_t)(bar_offset & UINT64_C(3));
    if (within_dword + size > 4 || bar_offset >= aperture ||
        size > aperture - bar_offset)
        return 0;

    memset(target, 0, sizeof(*target));
    cosim_table_target_set_identity(target, rc_id, device_instance, 0, 0, 0);
    target->target_type = COSIM_TABLE_TARGET_PF;
    target->pf_index = 0;
    target->vf_index = 0;
    target->bar_index = logical;
    *aligned_offset = bar_offset & ~UINT64_C(3);
    *byte_offset = within_dword;
    return 1;
}

uint64_t cosim_table_extract_read(uint32_t dword, uint8_t byte_offset,
                                  unsigned size)
{
    uint64_t mask;

    if ((size != 1 && size != 2 && size != 4) ||
        byte_offset > 3 || byte_offset + size > 4)
        return 0;
    mask = size == 4 ? UINT64_C(0xffffffff)
                     : (UINT64_C(1) << (size * 8u)) - 1u;
    return ((uint64_t)dword >> (byte_offset * 8u)) & mask;
}

static cosim_table_status_t publish_completion(
    cosim_table_ctrl_core_t *core, uint64_t slot_dma_address,
    cosim_table_status_t status, const cosim_table_completion_t *completion)
{
    cosim_u32 result[5];
    cosim_u32 state;

    result[0] = cosim_table_cpu_to_le32(status);
    result[1] = cosim_table_cpu_to_le32(completion->failed_index);
    result[2] = cosim_table_cpu_to_le32(completion->committed_count);
    result[3] = cosim_table_cpu_to_le32(completion->handler_error);
    result[4] = cosim_table_cpu_to_le32(completion->returned_dword);
    if (core->ops.dma_write(
            core->opaque,
            slot_dma_address +
                offsetof(cosim_table_slot_hdr_t, result_status),
            result, sizeof(result)) != (ssize_t)sizeof(result))
        return COSIM_TABLE_ST_UNKNOWN;
    core->ops.release_barrier(core->opaque);
    state = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_COMPLETE);
    if (core->ops.dma_write(core->opaque, slot_dma_address, &state,
                            sizeof(state)) != (ssize_t)sizeof(state))
        return COSIM_TABLE_ST_UNKNOWN;
    return status;
}

static cosim_table_status_t complete_simple(cosim_table_ctrl_core_t *core,
                                             uint64_t slot_dma_address,
                                             cosim_table_status_t status)
{
    cosim_table_completion_t completion;

    memset(&completion, 0, sizeof(completion));
    completion.status = status;
    completion.failed_index = UINT32_MAX;
    return publish_completion(core, slot_dma_address, status, &completion);
}

static int route_logical_index(const cosim_table_route_entry_t *route,
                               uint64_t bar_offset, uint64_t *index)
{
    uint64_t start;
    uint64_t logical;
    uint32_t stride;
    uint32_t index_base;

    if (route == NULL || index == NULL)
        return -1;
    start = cosim_table_le64_to_cpu(route->start_offset);
    stride = cosim_table_le32_to_cpu(route->stride_bytes);
    index_base = cosim_table_le32_to_cpu(route->index_base);
    if (stride == 0 || bar_offset < start)
        return -1;
    logical = (bar_offset - start) / stride;
    if (logical > UINT32_MAX - index_base)
        return -1;
    *index = index_base + logical;
    return 0;
}

static int completion_semantics_valid(
    cosim_table_status_t status, const cosim_table_completion_t *completion,
    int is_write, uint64_t first_index, uint32_t entry_count)
{
    uint64_t expected_failed;

    if (status == COSIM_TABLE_ST_SUCCESS) {
        return completion->failed_index == UINT32_MAX &&
               completion->handler_error == 0 &&
               completion->committed_count == (is_write ? entry_count : 0) &&
               (!is_write || completion->returned_dword == 0);
    }
    if (status == COSIM_TABLE_ST_EXEC_ERROR) {
        if (!is_write)
            return completion->committed_count == 0 &&
                   completion->failed_index == first_index &&
                   completion->returned_dword == 0;
        if (completion->committed_count >= entry_count ||
            first_index > UINT32_MAX - completion->committed_count ||
            completion->returned_dword != 0)
            return 0;
        expected_failed = first_index + completion->committed_count;
        return completion->failed_index == expected_failed;
    }
    return completion->committed_count == 0 &&
           completion->returned_dword == 0;
}

static int header_valid(const cosim_table_slot_hdr_t *header,
                        uint64_t slot_dma_address, uint32_t slot_bytes,
                        uint32_t max_payload_bytes)
{
    uint32_t payload_offset =
        cosim_table_le32_to_cpu(header->payload_offset);
    uint32_t payload_bytes =
        cosim_table_le32_to_cpu(header->payload_bytes);

    if (cosim_table_le32_to_cpu(header->header_version) !=
            COSIM_TABLE_SLOT_HEADER_VERSION ||
        cosim_table_le64_to_cpu(header->transaction_id) == 0 ||
        header->target.target_type != COSIM_TABLE_TARGET_PF ||
        header->target.pf_index != 0 || header->target.vf_index != 0 ||
        header->target.bar_index > 1 ||
        !bytes_are_zero(header->target.reserved0,
                        sizeof(header->target.reserved0)) ||
        header->target.reserved1 != 0 ||
        !bytes_are_zero(header->reserved, sizeof(header->reserved)) ||
        payload_bytes > max_payload_bytes ||
        payload_offset < sizeof(*header) || (payload_offset & 7u) != 0 ||
        payload_offset > slot_bytes ||
        payload_bytes > slot_bytes - payload_offset ||
        slot_dma_address > UINT64_MAX - payload_offset ||
        slot_dma_address + payload_offset > UINT64_MAX - payload_bytes)
        return 0;
    return 1;
}

cosim_table_status_t cosim_table_ctrl_process_slot(
    cosim_table_ctrl_core_t *core, uint64_t slot_dma_address,
    uint32_t slot_bytes, int timeout_ms)
{
    cosim_table_slot_hdr_t header;
    const cosim_table_route_entry_t *route;
    cosim_table_completion_t completion;
    cosim_table_status_t status;
    cosim_u32 busy;
    uint8_t *payload = NULL;
    uint64_t first_index;
    uint64_t payload_address;
    uint64_t bar_offset;
    uint32_t payload_bytes;
    uint32_t entry_count;

    if (core == NULL)
        return COSIM_TABLE_ST_UNKNOWN;
    if (atomic_exchange_explicit(&core->processing, 1,
                                 memory_order_acquire) != 0)
        return COSIM_TABLE_ST_SLOT_BUSY;

    status = COSIM_TABLE_ST_PROTOCOL;
    if ((slot_dma_address & UINT64_C(7)) != 0 ||
        slot_bytes < sizeof(header) ||
        slot_dma_address > UINT64_MAX - slot_bytes)
        goto done;
    if (core->ops.dma_read(core->opaque, slot_dma_address, &header,
                           sizeof(header)) != (ssize_t)sizeof(header)) {
        status = COSIM_TABLE_ST_UNKNOWN;
        goto done;
    }
    if (cosim_table_le32_to_cpu(header.state) == COSIM_TABLE_SLOT_BUSY) {
        status = COSIM_TABLE_ST_SLOT_BUSY;
        goto done;
    }
    if (cosim_table_le32_to_cpu(header.state) != COSIM_TABLE_SLOT_READY)
        goto done;

    core->ops.release_barrier(core->opaque);
    busy = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_BUSY);
    if (core->ops.dma_write(core->opaque, slot_dma_address, &busy,
                            sizeof(busy)) != (ssize_t)sizeof(busy)) {
        status = COSIM_TABLE_ST_UNKNOWN;
        goto done;
    }
    if (!atomic_load_explicit(&core->ready, memory_order_acquire)) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_NOT_READY);
        goto done;
    }
    if (!header_valid(&header, slot_dma_address, slot_bytes,
                      core->max_payload_bytes)) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_PROTOCOL);
        goto done;
    }
    if (!core->ops.target_active(core->opaque, &header.target)) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_TARGET_GONE);
        goto done;
    }

    bar_offset = cosim_table_le64_to_cpu(header.bar_offset);
    payload_bytes = cosim_table_le32_to_cpu(header.payload_bytes);
    if (payload_bytes == 0) {
        cosim_table_read_dword_t request;

        route = core->ops.match(core->opaque, &header.target, bar_offset,
                                COSIM_TABLE_OP_READ_DWORD);
        if (route == NULL) {
            status = complete_simple(core, slot_dma_address,
                                     COSIM_TABLE_ST_NO_ROUTE);
            goto done;
        }
        if (route_logical_index(route, bar_offset, &first_index) != 0 ||
            first_index > UINT32_MAX) {
            status = complete_simple(core, slot_dma_address,
                                     COSIM_TABLE_ST_PROTOCOL);
            goto done;
        }
        entry_count = 0;
        memset(&request, 0, sizeof(request));
        request.target = header.target;
        request.bar_offset = header.bar_offset;
        request.route_id = route->route_id;
        memset(&completion, 0, sizeof(completion));
        completion.failed_index = UINT32_MAX;
        status = core->ops.read_dword(core->opaque, &request, &completion,
                                      timeout_ms);
        goto validate_completion;
    }

    route = core->ops.match(core->opaque, &header.target, bar_offset,
                            COSIM_TABLE_OP_WRITE);
    if (route == NULL) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_NO_ROUTE);
        goto done;
    }
    if (cosim_table_route_slice(route, bar_offset, payload_bytes,
                                &first_index, &entry_count) != 0 ||
        first_index > UINT32_MAX) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_UNSUPPORTED);
        goto done;
    }
    payload = malloc(payload_bytes);
    if (payload == NULL) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_UNKNOWN);
        goto done;
    }
    payload_address = slot_dma_address +
                      cosim_table_le32_to_cpu(header.payload_offset);
    if (core->ops.dma_read(core->opaque, payload_address, payload,
                           payload_bytes) != (ssize_t)payload_bytes) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_UNKNOWN);
        goto done;
    }
    if (!core->ops.target_active(core->opaque, &header.target)) {
        status = complete_simple(core, slot_dma_address,
                                 COSIM_TABLE_ST_TARGET_GONE);
        goto done;
    }

    {
        cosim_table_write_begin_t request;

        memset(&request, 0, sizeof(request));
        request.target = header.target;
        request.route_id = route->route_id;
        request.entry_index = cosim_table_cpu_to_le32((uint32_t)first_index);
        request.bar_offset = header.bar_offset;
        request.payload_bytes = header.payload_bytes;
        memset(&completion, 0, sizeof(completion));
        completion.failed_index = UINT32_MAX;
        status = core->ops.write(core->opaque, &request, payload, &completion,
                                 timeout_ms);
    }

validate_completion:
    if (status < COSIM_TABLE_ST_SUCCESS || status > COSIM_TABLE_ST_PROTOCOL ||
        status == COSIM_TABLE_ST_SLOT_BUSY ||
        completion.status != (cosim_u32)status ||
        !completion_semantics_valid(status, &completion, payload_bytes != 0,
                                    first_index, entry_count)) {
        memset(&completion, 0, sizeof(completion));
        completion.failed_index = UINT32_MAX;
        status = COSIM_TABLE_ST_PROTOCOL;
    }
    completion.status = status;
    status = publish_completion(core, slot_dma_address, status, &completion);

done:
    free(payload);
    atomic_store_explicit(&core->processing, 0, memory_order_release);
    return status;
}
