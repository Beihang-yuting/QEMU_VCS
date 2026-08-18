#define _POSIX_C_SOURCE 200809L
#include "table_client.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TABLE_CLIENT_MAX_ROUTES 65536u

struct cosim_table_client {
    cosim_table_transport_t *transport;
    uint16_t rc_id;
    pthread_mutex_t request_lock;
    cosim_table_route_map_t routes;
    uint64_t next_transaction_id;
    int terminal;
    atomic_int routes_installed;
};

typedef struct {
    struct timespec expires;
    int infinite;
} table_deadline_t;

static int deadline_init(table_deadline_t *deadline, int timeout_ms)
{
    int64_t nanoseconds;

    if (timeout_ms < 0) {
        deadline->infinite = 1;
        memset(&deadline->expires, 0, sizeof(deadline->expires));
        return 0;
    }
    deadline->infinite = 0;
    if (clock_gettime(CLOCK_MONOTONIC, &deadline->expires) != 0)
        return -1;
    nanoseconds = (int64_t)deadline->expires.tv_nsec +
                  (int64_t)(timeout_ms % 1000) * INT64_C(1000000);
    deadline->expires.tv_sec += timeout_ms / 1000 +
        (time_t)(nanoseconds / INT64_C(1000000000));
    deadline->expires.tv_nsec =
        (long)(nanoseconds % INT64_C(1000000000));
    return 0;
}

static int deadline_remaining_ms(const table_deadline_t *deadline)
{
    struct timespec now;
    int64_t seconds;
    int64_t nanoseconds;
    int64_t milliseconds;

    if (deadline->infinite)
        return -1;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0;
    seconds = (int64_t)deadline->expires.tv_sec - (int64_t)now.tv_sec;
    nanoseconds = (int64_t)deadline->expires.tv_nsec - (int64_t)now.tv_nsec;
    if (nanoseconds < 0) {
        seconds--;
        nanoseconds += INT64_C(1000000000);
    }
    if (seconds < 0)
        return 0;
    milliseconds = seconds * INT64_C(1000) +
        (nanoseconds + INT64_C(999999)) / INT64_C(1000000);
    if (milliseconds > INT_MAX)
        return INT_MAX;
    return (int)milliseconds;
}

/* Returns 0 with the lock held, 1 on deadline expiration, or -1 on error. */
static int lock_before_deadline(cosim_table_client_t *client,
                                const table_deadline_t *deadline)
{
    const struct timespec pause = { 0, 1000000L };

    if (deadline->infinite)
        return pthread_mutex_lock(&client->request_lock) == 0 ? 0 : -1;
    for (;;) {
        int result = pthread_mutex_trylock(&client->request_lock);

        if (result == 0)
            return 0;
        if (result != EBUSY)
            return -1;
        result = deadline_remaining_ms(deadline);
        if (result == 0)
            return 1;
        if (result < 0)
            return -1;
        while (nanosleep(&pause, NULL) != 0) {
            if (errno != EINTR)
                return -1;
        }
    }
}

static cosim_table_frame_hdr_t make_frame(uint16_t type,
                                           uint32_t header_bytes,
                                           uint32_t payload_bytes,
                                           uint64_t transaction_id)
{
    cosim_table_frame_hdr_t frame;

    memset(&frame, 0, sizeof(frame));
    frame.magic = cosim_table_cpu_to_le32(COSIM_TABLE_MAGIC);
    frame.version = cosim_table_cpu_to_le16(COSIM_TABLE_PROTOCOL_VERSION);
    frame.type = cosim_table_cpu_to_le16(type);
    frame.header_bytes = cosim_table_cpu_to_le32(header_bytes);
    frame.payload_bytes = cosim_table_cpu_to_le32(payload_bytes);
    frame.transaction_id = cosim_table_cpu_to_le64(transaction_id);
    return frame;
}

static uint64_t next_transaction(cosim_table_client_t *client)
{
    uint64_t transaction_id = client->next_transaction_id++;

    if (transaction_id == 0) {
        transaction_id = client->next_transaction_id++;
    }
    return transaction_id;
}

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

static int recv_expected(cosim_table_client_t *client,
                         cosim_table_frame_hdr_t *frame,
                         uint16_t expected_type, uint64_t transaction_id,
                         void *header, size_t header_bytes, int timeout_ms)
{
    int result = cosim_table_recv(client->transport, frame, header,
                                  header_bytes, NULL, 0, timeout_ms);

    if (result != 0)
        return result;
    if (cosim_table_le16_to_cpu(frame->type) != expected_type ||
        cosim_table_le64_to_cpu(frame->transaction_id) != transaction_id)
        return -1;
    return 0;
}

static int route_entry_valid(const cosim_table_client_t *client,
                             const cosim_table_route_entry_t *route)
{
    uint32_t operation_mask =
        cosim_table_le32_to_cpu(route->operation_mask);
    uint64_t start = cosim_table_le64_to_cpu(route->start_offset);
    uint64_t end = cosim_table_le64_to_cpu(route->end_offset);
    uint32_t entry_bytes = cosim_table_le32_to_cpu(route->entry_bytes);
    uint32_t stride_bytes = cosim_table_le32_to_cpu(route->stride_bytes);
    uint32_t index_base = cosim_table_le32_to_cpu(route->index_base);
    uint64_t span;
    uint64_t slots;
    uint64_t last_offset;
    uint64_t last_start;
    uint64_t last_index;
    const void *handler_end;

    if (cosim_table_le16_to_cpu(route->target.rc_id) != client->rc_id ||
        route->target.target_type != COSIM_TABLE_TARGET_PF ||
        route->target.pf_index != 0 || route->target.vf_index != 0 ||
        route->target.bar_index > 1 ||
        cosim_table_le16_to_cpu(route->target.pci_domain) != 0 ||
        cosim_table_le16_to_cpu(route->target.target_bdf) != 0 ||
        cosim_table_le32_to_cpu(route->target.generation) != 0 ||
        !bytes_are_zero(route->target.reserved0,
                        sizeof(route->target.reserved0)) ||
        route->target.reserved1 != 0 || route->reserved != 0 ||
        operation_mask == 0 ||
        (operation_mask & ~(COSIM_TABLE_OP_WRITE |
                            COSIM_TABLE_OP_READ_DWORD)) != 0 ||
        (operation_mask & COSIM_TABLE_OP_WRITE) == 0 ||
        start >= end || entry_bytes == 0 || stride_bytes < entry_bytes ||
        end - start < entry_bytes)
        return 0;

    handler_end = memchr(route->handler_name, '\0',
                         sizeof(route->handler_name));
    if (route->handler_name[0] == '\0' || handler_end == NULL)
        return 0;
    span = end - start;
    slots = UINT64_C(1) + (span - entry_bytes) / stride_bytes;
    if (slots == 0 || slots - 1 > UINT32_MAX - (uint64_t)index_base)
        return 0;
    if (slots - 1 > (UINT64_MAX - start) / stride_bytes)
        return 0;
    last_offset = (slots - 1) * stride_bytes;
    last_start = start + last_offset;
    if (last_start > end - entry_bytes)
        return 0;
    last_index = (uint64_t)index_base + slots - 1;
    return last_index <= UINT32_MAX;
}

static uint64_t route_hash(const cosim_table_route_entry_t *entries,
                           size_t count)
{
    const uint8_t *bytes = (const uint8_t *)entries;
    size_t total = count * sizeof(*entries);
    size_t i;
    uint64_t hash = UINT64_C(14695981039346656037);

    for (i = 0; i < total; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static int route_logical_index(const cosim_table_route_entry_t *route,
                               uint64_t bar_offset, uint32_t *index)
{
    uint64_t start = cosim_table_le64_to_cpu(route->start_offset);
    uint32_t stride = cosim_table_le32_to_cpu(route->stride_bytes);
    uint32_t index_base = cosim_table_le32_to_cpu(route->index_base);
    uint64_t logical;

    if (stride == 0 || bar_offset < start)
        return -1;
    logical = (bar_offset - start) / stride;
    if (logical > UINT32_MAX - (uint64_t)index_base)
        return -1;
    *index = index_base + (uint32_t)logical;
    return 0;
}

static int compare_u64(uint64_t left, uint64_t right)
{
    return left < right ? -1 : left > right ? 1 : 0;
}

static int compare_route_ids(const void *left_pointer,
                             const void *right_pointer)
{
    const cosim_table_route_entry_t *left = left_pointer;
    const cosim_table_route_entry_t *right = right_pointer;

    return compare_u64(cosim_table_le32_to_cpu(left->route_id),
                       cosim_table_le32_to_cpu(right->route_id));
}

static int compare_route_owners(const void *left_pointer,
                                const void *right_pointer)
{
    const cosim_table_route_entry_t *left = left_pointer;
    const cosim_table_route_entry_t *right = right_pointer;
    int result;

    result = compare_u64(cosim_table_le16_to_cpu(left->target.rc_id),
                         cosim_table_le16_to_cpu(right->target.rc_id));
    if (result == 0)
        result = compare_u64(
            cosim_table_le16_to_cpu(left->target.device_instance),
            cosim_table_le16_to_cpu(right->target.device_instance));
    if (result == 0)
        result = compare_u64(left->target.target_type,
                             right->target.target_type);
    if (result == 0)
        result = compare_u64(left->target.pf_index,
                             right->target.pf_index);
    if (result == 0)
        result = compare_u64(left->target.vf_index,
                             right->target.vf_index);
    if (result == 0)
        result = compare_u64(left->target.bar_index,
                             right->target.bar_index);
    if (result == 0)
        result = compare_u64(cosim_table_le64_to_cpu(left->start_offset),
                             cosim_table_le64_to_cpu(right->start_offset));
    return result;
}

static int same_route_owner(const cosim_table_route_entry_t *left,
                            const cosim_table_route_entry_t *right)
{
    return cosim_table_le16_to_cpu(left->target.rc_id) ==
               cosim_table_le16_to_cpu(right->target.rc_id) &&
           cosim_table_le16_to_cpu(left->target.device_instance) ==
               cosim_table_le16_to_cpu(right->target.device_instance) &&
           left->target.target_type == right->target.target_type &&
           left->target.pf_index == right->target.pf_index &&
           left->target.vf_index == right->target.vf_index &&
           left->target.bar_index == right->target.bar_index;
}

static int route_ids_duplicate(const cosim_table_route_entry_t *left,
                               const cosim_table_route_entry_t *right)
{
    return cosim_table_le32_to_cpu(left->route_id) ==
           cosim_table_le32_to_cpu(right->route_id);
}

static int ordered_routes_overlap(const cosim_table_route_entry_t *previous,
                                  const cosim_table_route_entry_t *current,
                                  uint64_t maximum_end)
{
    uint64_t current_start =
        cosim_table_le64_to_cpu(current->start_offset);

    return same_route_owner(previous, current) &&
           current_start < maximum_end;
}

static int validate_route_map(const cosim_table_client_t *client,
                              const cosim_table_route_entry_t *entries,
                              size_t count)
{
    cosim_table_route_entry_t *ordered;
    uint64_t maximum_end;
    size_t i;

    for (i = 0; i < count; i++) {
        if (!route_entry_valid(client, &entries[i]))
            return -1;
    }
    if (count < 2)
        return 0;
    if (count > SIZE_MAX / sizeof(*ordered))
        return -1;
    ordered = malloc(count * sizeof(*ordered));
    if (ordered == NULL)
        return -1;
    memcpy(ordered, entries, count * sizeof(*ordered));

    qsort(ordered, count, sizeof(*ordered), compare_route_ids);
    for (i = 1; i < count; i++) {
        if (route_ids_duplicate(&ordered[i - 1], &ordered[i]))
            goto invalid;
    }

    qsort(ordered, count, sizeof(*ordered), compare_route_owners);
    maximum_end = cosim_table_le64_to_cpu(ordered[0].end_offset);
    for (i = 1; i < count; i++) {
        if (!same_route_owner(&ordered[i - 1], &ordered[i])) {
            maximum_end = cosim_table_le64_to_cpu(ordered[i].end_offset);
            continue;
        }
        if (ordered_routes_overlap(&ordered[i - 1], &ordered[i],
                                   maximum_end))
            goto invalid;
        if (maximum_end < cosim_table_le64_to_cpu(ordered[i].end_offset))
            maximum_end = cosim_table_le64_to_cpu(ordered[i].end_offset);
    }
    free(ordered);
    return 0;

invalid:
    free(ordered);
    return -1;
}

cosim_table_client_t *cosim_table_client_create(
    cosim_table_transport_t *transport, uint16_t rc_id)
{
    cosim_table_client_t *client;

    if (transport == NULL)
        return NULL;
    client = calloc(1, sizeof(*client));
    if (client == NULL)
        return NULL;
    client->transport = transport;
    client->rc_id = rc_id;
    client->routes = (cosim_table_route_map_t)COSIM_TABLE_ROUTE_MAP_INIT;
    client->next_transaction_id = 1;
    atomic_init(&client->routes_installed, 0);
    if (pthread_mutex_init(&client->request_lock, NULL) != 0) {
        free(client);
        return NULL;
    }
    return client;
}

int cosim_table_client_wait_routes(cosim_table_client_t *client,
                                   int timeout_ms)
{
    cosim_table_route_begin_t begin;
    cosim_table_route_end_t end;
    cosim_table_frame_hdr_t frame;
    cosim_table_route_entry_t *entries = NULL;
    uint64_t transaction_id;
    uint32_t generation;
    uint32_t count;
    uint32_t i;
    table_deadline_t deadline;
    int result = -1;
    int remaining;
    int receive_result;

    if (client == NULL || deadline_init(&deadline, timeout_ms) != 0)
        return -1;
    remaining = lock_before_deadline(client, &deadline);
    if (remaining != 0)
        return remaining == 1 ? 1 : -1;
    memset(&begin, 0, sizeof(begin));
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0)
        goto timed_out;
    receive_result = cosim_table_recv(client->transport, &frame, &begin,
                                      sizeof(begin), NULL, 0, remaining);
    if (receive_result == 1)
        goto timed_out;
    if (receive_result != 0 ||
        cosim_table_le16_to_cpu(frame.type) != COSIM_TABLE_MSG_ROUTE_BEGIN)
        goto done;
    transaction_id = cosim_table_le64_to_cpu(frame.transaction_id);
    generation = cosim_table_le32_to_cpu(begin.generation);
    count = cosim_table_le32_to_cpu(begin.entry_count);
    if (transaction_id == 0 || generation == 0 || count == 0 ||
        count > TABLE_CLIENT_MAX_ROUTES)
        goto done;
    entries = calloc(count, sizeof(*entries));
    if (entries == NULL)
        goto done;
    for (i = 0; i < count; i++) {
        remaining = deadline_remaining_ms(&deadline);
        if (remaining == 0)
            goto timed_out;
        receive_result = recv_expected(
            client, &frame, COSIM_TABLE_MSG_ROUTE_ENTRY, transaction_id,
            &entries[i], sizeof(entries[i]), remaining);
        if (receive_result == 1)
            goto timed_out;
        if (receive_result != 0)
            goto done;
    }
    memset(&end, 0, sizeof(end));
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0)
        goto timed_out;
    receive_result = recv_expected(client, &frame, COSIM_TABLE_MSG_ROUTE_END,
                                   transaction_id, &end, sizeof(end),
                                   remaining);
    if (receive_result == 1)
        goto timed_out;
    if (receive_result != 0 ||
        cosim_table_le32_to_cpu(end.generation) != generation ||
        end.reserved != 0 || validate_route_map(client, entries, count) != 0 ||
        atomic_load_explicit(&client->routes_installed,
                             memory_order_acquire))
        goto done;

    client->routes.entries = entries;
    client->routes.count = count;
    client->routes.generation_hash = route_hash(entries, count);
    atomic_store_explicit(&client->routes_installed, 1,
                          memory_order_release);
    entries = NULL;
    result = 0;
    goto done;

timed_out:
    result = 1;

done:
    free(entries);
    (void)pthread_mutex_unlock(&client->request_lock);
    return result;
}

const cosim_table_route_entry_t *cosim_table_client_match(
    cosim_table_client_t *client, const cosim_table_target_t *target,
    uint64_t offset, uint8_t operation)
{
    if (client == NULL ||
        !atomic_load_explicit(&client->routes_installed,
                              memory_order_acquire))
        return NULL;
    return cosim_table_route_match(&client->routes, target, offset, operation);
}

static void completion_reset(cosim_table_completion_t *completion,
                             cosim_table_status_t status)
{
    memset(completion, 0, sizeof(*completion));
    completion->status = status;
    completion->failed_index = UINT32_MAX;
}

static void client_mark_terminal(cosim_table_client_t *client)
{
    if (!client->terminal) {
        client->terminal = 1;
        cosim_table_transport_interrupt(client->transport);
    }
}

static cosim_table_status_t client_send(
    cosim_table_client_t *client, const cosim_table_frame_hdr_t *frame,
    const void *header, const void *payload, int timeout_ms)
{
    int send_errno;

    if (cosim_table_send(client->transport, frame, header, payload,
                         timeout_ms) == 0)
        return COSIM_TABLE_ST_SUCCESS;
    send_errno = errno;
    client_mark_terminal(client);
    return send_errno == ETIMEDOUT ? COSIM_TABLE_ST_TIMEOUT
                                   : COSIM_TABLE_ST_TARGET_GONE;
}

static cosim_table_status_t receive_completion(
    cosim_table_client_t *client, uint64_t transaction_id,
    cosim_table_completion_t *completion, uint32_t first_index,
    uint32_t entry_count, int is_read, int timeout_ms,
    int *transport_timed_out)
{
    cosim_table_completion_t wire;
    cosim_table_frame_hdr_t frame;
    cosim_table_status_t status;
    uint32_t failed_index;
    uint32_t committed_count;
    uint32_t handler_error;
    uint32_t returned_dword;
    int receive_result;

    *transport_timed_out = 0;
    memset(&wire, 0, sizeof(wire));
    receive_result = cosim_table_recv(client->transport, &frame, &wire,
                                      sizeof(wire), NULL, 0, timeout_ms);
    if (receive_result == 1) {
        *transport_timed_out = 1;
        completion_reset(completion, COSIM_TABLE_ST_TIMEOUT);
        return COSIM_TABLE_ST_TIMEOUT;
    }
    if (receive_result != 0) {
        completion_reset(completion, COSIM_TABLE_ST_PROTOCOL);
        return COSIM_TABLE_ST_PROTOCOL;
    }
    if (cosim_table_le16_to_cpu(frame.type) != COSIM_TABLE_MSG_COMPLETION ||
        cosim_table_le64_to_cpu(frame.transaction_id) != transaction_id ||
        !bytes_are_zero(wire.reserved, sizeof(wire.reserved))) {
        completion_reset(completion, COSIM_TABLE_ST_PROTOCOL);
        return COSIM_TABLE_ST_PROTOCOL;
    }

    status = (cosim_table_status_t)cosim_table_le32_to_cpu(wire.status);
    failed_index = cosim_table_le32_to_cpu(wire.failed_index);
    committed_count = cosim_table_le32_to_cpu(wire.committed_count);
    handler_error = cosim_table_le32_to_cpu(wire.handler_error);
    returned_dword = cosim_table_le32_to_cpu(wire.returned_dword);
    if (status < COSIM_TABLE_ST_SUCCESS || status > COSIM_TABLE_ST_PROTOCOL ||
        status == COSIM_TABLE_ST_SLOT_BUSY)
        goto protocol;
    if (status == COSIM_TABLE_ST_SUCCESS) {
        if ((!is_read && (committed_count != entry_count ||
                          failed_index != UINT32_MAX || handler_error != 0 ||
                          returned_dword != 0)) ||
            (is_read && (committed_count != 0 ||
                         failed_index != UINT32_MAX || handler_error != 0)))
            goto protocol;
    } else if (status == COSIM_TABLE_ST_EXEC_ERROR) {
        if (is_read) {
            if (committed_count != 0 || failed_index != first_index ||
                returned_dword != 0)
                goto protocol;
        } else if (entry_count == 0 || committed_count >= entry_count ||
                   failed_index != first_index + committed_count ||
                   returned_dword != 0) {
            goto protocol;
        }
    } else if (committed_count != 0 || returned_dword != 0) {
        goto protocol;
    }

    completion->status = status;
    completion->failed_index = failed_index;
    completion->committed_count = committed_count;
    completion->handler_error = handler_error;
    completion->returned_dword = returned_dword;
    memset(completion->reserved, 0, sizeof(completion->reserved));
    return status;

protocol:
    completion_reset(completion, COSIM_TABLE_ST_PROTOCOL);
    return COSIM_TABLE_ST_PROTOCOL;
}

cosim_table_status_t cosim_table_client_write(
    cosim_table_client_t *client, const cosim_table_write_begin_t *request,
    const uint8_t *payload, cosim_table_completion_t *completion,
    int timeout_ms)
{
    const cosim_table_route_entry_t *route;
    cosim_table_write_begin_t outbound;
    cosim_table_write_data_t data_header;
    cosim_table_write_end_t end;
    cosim_table_frame_hdr_t frame;
    uint64_t first_index;
    uint64_t transaction_id;
    uint64_t offset;
    uint32_t payload_bytes;
    uint32_t entry_count;
    size_t sent = 0;
    cosim_table_status_t status = COSIM_TABLE_ST_PROTOCOL;
    table_deadline_t deadline;
    int completion_timed_out;
    int in_flight = 0;
    int remaining;

    if (client == NULL || request == NULL || payload == NULL ||
        completion == NULL || deadline_init(&deadline, timeout_ms) != 0)
        return COSIM_TABLE_ST_PROTOCOL;
    completion_reset(completion, COSIM_TABLE_ST_PROTOCOL);
    remaining = lock_before_deadline(client, &deadline);
    if (remaining == 1) {
        completion_reset(completion, COSIM_TABLE_ST_TIMEOUT);
        return COSIM_TABLE_ST_TIMEOUT;
    }
    if (remaining != 0)
        return COSIM_TABLE_ST_PROTOCOL;
    if (client->terminal) {
        status = COSIM_TABLE_ST_TARGET_GONE;
        completion_reset(completion, status);
        goto done;
    }
    if (!atomic_load_explicit(&client->routes_installed,
                              memory_order_acquire)) {
        status = COSIM_TABLE_ST_NOT_READY;
        completion_reset(completion, status);
        goto done;
    }
    offset = cosim_table_le64_to_cpu(request->bar_offset);
    payload_bytes = cosim_table_le32_to_cpu(request->payload_bytes);
    route = cosim_table_route_match(&client->routes, &request->target, offset,
                                    COSIM_TABLE_OP_WRITE);
    if (route == NULL) {
        status = COSIM_TABLE_ST_NO_ROUTE;
        completion_reset(completion, status);
        goto done;
    }
    if (payload_bytes == 0 ||
        cosim_table_route_slice(route, offset, payload_bytes, &first_index,
                                &entry_count) != 0 ||
        first_index > UINT32_MAX) {
        status = COSIM_TABLE_ST_UNSUPPORTED;
        completion_reset(completion, status);
        goto done;
    }

    outbound = *request;
    outbound.route_id = route->route_id;
    outbound.entry_index = cosim_table_cpu_to_le32((uint32_t)first_index);
    transaction_id = next_transaction(client);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(outbound), 0,
                       transaction_id);
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0)
        goto timed_out;
    status = client_send(client, &frame, &outbound, NULL, remaining);
    if (status != COSIM_TABLE_ST_SUCCESS) {
        completion_reset(completion, status);
        goto done;
    }
    in_flight = 1;
    while (sent < payload_bytes) {
        size_t chunk = payload_bytes - sent;

        if (chunk > COSIM_TABLE_FRAME_DATA_BYTES)
            chunk = COSIM_TABLE_FRAME_DATA_BYTES;
        memset(&data_header, 0, sizeof(data_header));
        data_header.data_offset = cosim_table_cpu_to_le64(sent);
        data_header.data_bytes = cosim_table_cpu_to_le32((uint32_t)chunk);
        frame = make_frame(COSIM_TABLE_MSG_WRITE_DATA, sizeof(data_header),
                           (uint32_t)chunk, transaction_id);
        remaining = deadline_remaining_ms(&deadline);
        if (remaining == 0)
            goto timed_out;
        status = client_send(client, &frame, &data_header, payload + sent,
                             remaining);
        if (status != COSIM_TABLE_ST_SUCCESS) {
            completion_reset(completion, status);
            goto done;
        }
        sent += chunk;
    }
    memset(&end, 0, sizeof(end));
    end.payload_bytes = cosim_table_cpu_to_le32(payload_bytes);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_END, sizeof(end), 0,
                       transaction_id);
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0)
        goto timed_out;
    status = client_send(client, &frame, &end, NULL, remaining);
    if (status != COSIM_TABLE_ST_SUCCESS) {
        completion_reset(completion, status);
        goto done;
    }
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0)
        goto timed_out;
    status = receive_completion(client, transaction_id, completion,
                                (uint32_t)first_index, entry_count, 0,
                                remaining, &completion_timed_out);
    if (completion_timed_out)
        client_mark_terminal(client);
    goto done;

timed_out:
    status = COSIM_TABLE_ST_TIMEOUT;
    completion_reset(completion, status);
    if (in_flight)
        client_mark_terminal(client);
done:
    (void)pthread_mutex_unlock(&client->request_lock);
    return status;
}

cosim_table_status_t cosim_table_client_read_dword(
    cosim_table_client_t *client, const cosim_table_read_dword_t *request,
    cosim_table_completion_t *completion, int timeout_ms)
{
    const cosim_table_route_entry_t *route;
    cosim_table_read_dword_t outbound;
    cosim_table_frame_hdr_t frame;
    uint64_t offset;
    uint64_t transaction_id;
    uint32_t read_index;
    cosim_table_status_t status = COSIM_TABLE_ST_PROTOCOL;
    table_deadline_t deadline;
    int completion_timed_out;
    int remaining;

    if (client == NULL || request == NULL || completion == NULL ||
        deadline_init(&deadline, timeout_ms) != 0)
        return COSIM_TABLE_ST_PROTOCOL;
    completion_reset(completion, COSIM_TABLE_ST_PROTOCOL);
    remaining = lock_before_deadline(client, &deadline);
    if (remaining == 1) {
        completion_reset(completion, COSIM_TABLE_ST_TIMEOUT);
        return COSIM_TABLE_ST_TIMEOUT;
    }
    if (remaining != 0)
        return COSIM_TABLE_ST_PROTOCOL;
    if (client->terminal) {
        status = COSIM_TABLE_ST_TARGET_GONE;
        completion_reset(completion, status);
        goto done;
    }
    if (!atomic_load_explicit(&client->routes_installed,
                              memory_order_acquire)) {
        status = COSIM_TABLE_ST_NOT_READY;
        completion_reset(completion, status);
        goto done;
    }
    offset = cosim_table_le64_to_cpu(request->bar_offset);
    route = cosim_table_route_match(&client->routes, &request->target, offset,
                                    COSIM_TABLE_OP_READ_DWORD);
    if (route == NULL) {
        status = cosim_table_route_match(&client->routes, &request->target,
                                         offset, COSIM_TABLE_OP_WRITE) != NULL
                     ? COSIM_TABLE_ST_UNSUPPORTED
                     : COSIM_TABLE_ST_NO_ROUTE;
        completion_reset(completion, status);
        goto done;
    }
    outbound = *request;
    outbound.route_id = route->route_id;
    outbound.reserved = 0;
    if (route_logical_index(route, offset, &read_index) != 0) {
        status = COSIM_TABLE_ST_PROTOCOL;
        completion_reset(completion, status);
        goto done;
    }
    transaction_id = next_transaction(client);
    frame = make_frame(COSIM_TABLE_MSG_READ_DWORD, sizeof(outbound), 0,
                       transaction_id);
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0) {
        status = COSIM_TABLE_ST_TIMEOUT;
        completion_reset(completion, status);
        goto done;
    }
    status = client_send(client, &frame, &outbound, NULL, remaining);
    if (status != COSIM_TABLE_ST_SUCCESS) {
        completion_reset(completion, status);
        goto done;
    }
    remaining = deadline_remaining_ms(&deadline);
    if (remaining == 0) {
        status = COSIM_TABLE_ST_TIMEOUT;
        completion_reset(completion, status);
        client_mark_terminal(client);
        goto done;
    }
    status = receive_completion(client, transaction_id, completion,
                                read_index, 0, 1, remaining,
                                &completion_timed_out);
    if (completion_timed_out)
        client_mark_terminal(client);

done:
    (void)pthread_mutex_unlock(&client->request_lock);
    return status;
}

void cosim_table_client_destroy(cosim_table_client_t *client)
{
    if (client == NULL)
        return;
    cosim_table_route_free(&client->routes);
    (void)pthread_mutex_destroy(&client->request_lock);
    free(client);
}
