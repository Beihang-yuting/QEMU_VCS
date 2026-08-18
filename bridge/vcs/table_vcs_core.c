#define _POSIX_C_SOURCE 200809L

#include "table_vcs_core.h"

#include "cosim_table_route.h"
#include "cosim_table_transport.h"

#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef COSIM_MAX_RCS
#define COSIM_MAX_RCS 4
#endif

typedef struct {
    char name[COSIM_TABLE_HANDLER_NAME_BYTES];
    int supports_read;
} table_vcs_handler_t;

typedef struct {
    int kind;
    const cosim_table_route_entry_t *route;
    cosim_table_target_t target;
    uint64_t transaction_id;
    uint64_t first_index;
    uint64_t bar_offset;
    uint32_t route_id;
    uint32_t entry_count;
    uint32_t entry_bytes;
    uint32_t payload_bytes;
    uint32_t byte_offset;
    uint32_t flags;
    uint8_t *payload;
} table_vcs_request_t;

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t idle;
    cosim_table_route_map_t routes;
    cosim_table_route_entry_t *published_routes;
    size_t published_count;
    table_vcs_handler_t *handlers;
    size_t handler_count;
    size_t handler_capacity;
    cosim_table_transport_t *transport;
    table_vcs_request_t request;
    pthread_t worker;
    pthread_cond_t request_changed;
    int io_timeout_ms;
    unsigned int active_io;
    int loaded;
    int initialized;
    int activated;
    int activating;
    int completing;
    int outstanding;
    int delivered;
    int worker_started;
    int stop_requested;
    int interrupted;
    int terminal;
    int cleaning;
} table_vcs_state_t;

static table_vcs_state_t table_states[COSIM_MAX_RCS];

static pthread_once_t table_states_once = PTHREAD_ONCE_INIT;

static void *table_vcs_worker_main(void *opaque);

/* Unit tests may interpose this weak symbol to stop at concurrency points. */
extern void table_vcs_test_hook(int rc, int event) __attribute__((weak));
extern void *table_vcs_test_alloc(size_t bytes) __attribute__((weak));

enum {
    TABLE_VCS_TEST_HOOK_ACTIVATION_CLAIMED = 1,
    TABLE_VCS_TEST_HOOK_ACTIVATION_END_SENT = 2,
    TABLE_VCS_TEST_HOOK_CLEANUP_CLAIMED = 3,
    TABLE_VCS_TEST_HOOK_WRITE_WAITING_DATA = 4,
    TABLE_VCS_TEST_HOOK_REQUEST_RECEIVED = 5,
};

static void run_test_hook(int rc, int event)
{
    if (table_vcs_test_hook != NULL)
        table_vcs_test_hook(rc, event);
}

static void *allocate_payload(size_t bytes)
{
    return table_vcs_test_alloc != NULL
        ? table_vcs_test_alloc(bytes) : malloc(bytes);
}

static void *allocate_route_subset(size_t count)
{
    if (!cosim_table_route_count_supported((uint64_t)count) ||
        count > SIZE_MAX / sizeof(cosim_table_route_entry_t))
        return NULL;
    return allocate_payload(count * sizeof(cosim_table_route_entry_t));
}

#ifdef TABLE_VCS_TESTING
void *table_vcs_test_allocate_route_subset(size_t count)
{
    return allocate_route_subset(count);
}
#endif

static void initialize_states(void)
{
    int rc;

    for (rc = 0; rc < COSIM_MAX_RCS; rc++) {
        (void)pthread_mutex_init(&table_states[rc].lock, NULL);
        (void)pthread_cond_init(&table_states[rc].idle, NULL);
        (void)pthread_cond_init(&table_states[rc].request_changed, NULL);
        table_states[rc].routes =
            (cosim_table_route_map_t)COSIM_TABLE_ROUTE_MAP_INIT;
    }
}

static table_vcs_state_t *get_state(int rc)
{
    if (rc < 0 || rc >= COSIM_MAX_RCS)
        return NULL;
    (void)pthread_once(&table_states_once, initialize_states);
    return &table_states[rc];
}

static int bytes_are_zero(const void *data, size_t bytes)
{
    const uint8_t *cursor = data;
    size_t i;

    for (i = 0; i < bytes; i++) {
        if (cursor[i] != 0)
            return 0;
    }
    return 1;
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

static uint64_t route_hash(const cosim_table_route_entry_t *routes,
                           size_t count)
{
    const uint8_t *bytes = (const uint8_t *)routes;
    size_t total = count * sizeof(*routes);
    uint64_t hash = UINT64_C(14695981039346656037);
    size_t i;

    for (i = 0; i < total; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint32_t route_generation(uint64_t hash)
{
    uint32_t generation = (uint32_t)hash ^ (uint32_t)(hash >> 32);

    return generation != 0 ? generation : 1;
}

static const table_vcs_handler_t *find_handler(
    const table_vcs_state_t *state, const cosim_u8 *name)
{
    size_t i;

    for (i = 0; i < state->handler_count; i++) {
        if (strcmp(state->handlers[i].name, (const char *)name) == 0)
            return &state->handlers[i];
    }
    return NULL;
}

static const cosim_table_route_entry_t *find_route(
    const table_vcs_state_t *state, uint32_t route_id)
{
    size_t i;

    for (i = 0; i < state->published_count; i++) {
        if (cosim_table_le32_to_cpu(state->published_routes[i].route_id) ==
            route_id)
            return &state->published_routes[i];
    }
    return NULL;
}

static int target_matches_route(const cosim_table_target_t *target,
                                const cosim_table_route_entry_t *route,
                                int rc)
{
    return cosim_table_le16_to_cpu(target->rc_id) == rc &&
           cosim_table_le16_to_cpu(target->device_instance) ==
               cosim_table_le16_to_cpu(route->target.device_instance) &&
           target->target_type == route->target.target_type &&
           target->pf_index == route->target.pf_index &&
           target->vf_index == route->target.vf_index &&
           target->bar_index == route->target.bar_index &&
           cosim_table_le32_to_cpu(target->generation) != 0 &&
           bytes_are_zero(target->reserved0, sizeof(target->reserved0)) &&
           target->reserved1 == 0;
}

static int preflight_routes(table_vcs_state_t *state, int rc,
                            cosim_table_route_entry_t **subset_out,
                            size_t *count_out)
{
    cosim_table_route_entry_t *subset;
    size_t count = 0;
    size_t i;

    for (i = 0; i < state->routes.count; i++) {
        if (cosim_table_le16_to_cpu(state->routes.entries[i].target.rc_id) ==
            rc)
            count++;
    }
    subset = allocate_route_subset(count);
    if (subset == NULL)
        return -1;

    count = 0;
    for (i = 0; i < state->routes.count; i++) {
        const cosim_table_route_entry_t *route = &state->routes.entries[i];
        const table_vcs_handler_t *handler;
        uint32_t operations;

        if (cosim_table_le16_to_cpu(route->target.rc_id) != rc)
            continue;
        handler = find_handler(state, route->handler_name);
        operations = cosim_table_le32_to_cpu(route->operation_mask);
        if (handler == NULL ||
            ((operations & COSIM_TABLE_OP_READ_DWORD) != 0 &&
             !handler->supports_read)) {
            free(subset);
            return -1;
        }
        subset[count++] = *route;
    }
    *subset_out = subset;
    *count_out = count;
    return 0;
}

static void end_io_locked(table_vcs_state_t *state)
{
    if (state->active_io > 0)
        state->active_io--;
    (void)pthread_cond_broadcast(&state->idle);
}

int table_vcs_load_routes_rc(int rc, const char *absolute_path)
{
    table_vcs_state_t *state = get_state(rc);
    cosim_table_route_map_t loaded = COSIM_TABLE_ROUTE_MAP_INIT;
    char error[256];
    int result;

    if (state == NULL || absolute_path == NULL || absolute_path[0] != '/')
        return -1;
    if (cosim_table_route_load(absolute_path, &loaded, error,
                               sizeof(error)) != 0)
        return -1;

    (void)pthread_mutex_lock(&state->lock);
    if (state->loaded || state->initialized || state->activated ||
        state->activating ||
        state->cleaning) {
        result = -1;
    } else {
        state->routes = loaded;
        state->loaded = 1;
        loaded = (cosim_table_route_map_t)COSIM_TABLE_ROUTE_MAP_INIT;
        result = 0;
    }
    (void)pthread_mutex_unlock(&state->lock);
    cosim_table_route_free(&loaded);
    return result;
}

int table_vcs_register_handler_rc(int rc, const char *name,
                                  int supports_read)
{
    table_vcs_state_t *state = get_state(rc);
    table_vcs_handler_t *grown;
    size_t name_bytes;
    size_t capacity;
    size_t i;
    int result = -1;

    if (state == NULL || name == NULL ||
        (supports_read != 0 && supports_read != 1))
        return -1;
    name_bytes = strlen(name);
    if (name_bytes == 0 || name_bytes >= COSIM_TABLE_HANDLER_NAME_BYTES)
        return -1;

    (void)pthread_mutex_lock(&state->lock);
    if (!state->loaded || state->initialized || state->activated ||
        state->activating ||
        state->cleaning)
        goto done;
    for (i = 0; i < state->handler_count; i++) {
        if (strcmp(state->handlers[i].name, name) == 0)
            goto done;
    }
    if (state->handler_count == state->handler_capacity) {
        capacity = state->handler_capacity == 0
            ? 8 : state->handler_capacity * 2;
        if (capacity < state->handler_capacity ||
            capacity > SIZE_MAX / sizeof(*grown))
            goto done;
        grown = realloc(state->handlers, capacity * sizeof(*grown));
        if (grown == NULL)
            goto done;
        state->handlers = grown;
        state->handler_capacity = capacity;
    }
    memset(&state->handlers[state->handler_count], 0,
           sizeof(state->handlers[state->handler_count]));
    memcpy(state->handlers[state->handler_count].name, name, name_bytes + 1);
    state->handlers[state->handler_count].supports_read = supports_read;
    state->handler_count++;
    result = 0;

done:
    (void)pthread_mutex_unlock(&state->lock);
    return result;
}

int table_vcs_init_rc(int rc, const char *remote_host,
                      int table_port_base, int instance_id,
                      int connect_timeout_ms)
{
    table_vcs_state_t *state = get_state(rc);
    cosim_table_transport_cfg_t cfg;
    cosim_table_transport_t *transport;
    uint64_t port;

    if (state == NULL || remote_host == NULL || remote_host[0] == '\0' ||
        table_port_base <= 0 || instance_id < 0 || connect_timeout_ms <= 0)
        return -1;
    port = (uint64_t)(unsigned int)table_port_base +
           (uint64_t)(unsigned int)instance_id;
    if (port > UINT16_MAX)
        return -1;

    (void)pthread_mutex_lock(&state->lock);
    if (!state->loaded || state->initialized || state->activated ||
        state->activating ||
        state->cleaning) {
        (void)pthread_mutex_unlock(&state->lock);
        return -1;
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.remote_host = remote_host;
    cfg.table_port_base = (uint32_t)table_port_base;
    cfg.instance_id = (uint32_t)instance_id;
    cfg.rc_id = (uint16_t)rc;
    cfg.is_server = 0;
    cfg.connect_timeout_ms = connect_timeout_ms;
    transport = cosim_table_transport_create(&cfg);
    if (transport == NULL) {
        (void)pthread_mutex_unlock(&state->lock);
        return -1;
    }
    state->transport = transport;
    state->io_timeout_ms = connect_timeout_ms;
    state->initialized = 1;
    (void)pthread_mutex_unlock(&state->lock);
    return 0;
}

int table_vcs_activate_routes_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    cosim_table_route_entry_t *subset = NULL;
    size_t count = 0;
    cosim_table_route_begin_t begin;
    cosim_table_route_end_t end;
    cosim_table_frame_hdr_t frame;
    cosim_table_transport_t *transport;
    uint64_t hash;
    uint64_t transaction_id;
    uint32_t generation;
    int timeout_ms;
    size_t i;
    int result = -1;

    if (state == NULL)
        return -1;
    (void)pthread_mutex_lock(&state->lock);
    if (!state->initialized || state->activated || state->activating ||
        state->terminal ||
        state->cleaning || preflight_routes(state, rc, &subset, &count) != 0) {
        (void)pthread_mutex_unlock(&state->lock);
        return -1;
    }
    hash = route_hash(subset, count);
    transaction_id = hash != 0 ? hash : 1;
    generation = route_generation(hash);
    transport = state->transport;
    timeout_ms = state->io_timeout_ms;
    state->activating = 1;
    state->active_io++;
    (void)pthread_mutex_unlock(&state->lock);

    run_test_hook(rc, TABLE_VCS_TEST_HOOK_ACTIVATION_CLAIMED);

    memset(&begin, 0, sizeof(begin));
    begin.generation = cosim_table_cpu_to_le32(generation);
    begin.entry_count = cosim_table_cpu_to_le32((uint32_t)count);
    frame = make_frame(COSIM_TABLE_MSG_ROUTE_BEGIN, sizeof(begin), 0,
                       transaction_id);
    if (cosim_table_send(transport, &frame, &begin, NULL, timeout_ms) != 0)
        goto done;
    for (i = 0; i < count; i++) {
        frame = make_frame(COSIM_TABLE_MSG_ROUTE_ENTRY, sizeof(subset[i]), 0,
                           transaction_id);
        if (cosim_table_send(transport, &frame, &subset[i], NULL,
                             timeout_ms) != 0)
            goto done;
    }
    memset(&end, 0, sizeof(end));
    end.generation = cosim_table_cpu_to_le32(generation);
    frame = make_frame(COSIM_TABLE_MSG_ROUTE_END, sizeof(end), 0,
                       transaction_id);
    if (cosim_table_send(transport, &frame, &end, NULL, timeout_ms) != 0)
        goto done;
    run_test_hook(rc, TABLE_VCS_TEST_HOOK_ACTIVATION_END_SENT);
    result = 0;

done:
    (void)pthread_mutex_lock(&state->lock);
    if (result == 0) {
        if (!state->cleaning && !state->terminal && !state->interrupted) {
            state->published_routes = subset;
            state->published_count = count;
            state->activated = 1;
            state->stop_requested = 0;
            state->delivered = 0;
            if (pthread_create(&state->worker, NULL, table_vcs_worker_main,
                               state) == 0) {
                state->worker_started = 1;
                subset = NULL;
            } else {
                state->published_routes = NULL;
                state->published_count = 0;
                state->activated = 0;
                state->stop_requested = 1;
                result = -1;
            }
        } else {
            result = -1;
        }
    }
    if (result != 0)
        state->terminal = 1;
    state->activating = 0;
    end_io_locked(state);
    (void)pthread_mutex_unlock(&state->lock);
    free(subset);
    return result;
}

typedef union {
    cosim_table_route_entry_t route;
    cosim_table_write_begin_t write_begin;
    cosim_table_write_data_t write_data;
    cosim_table_write_end_t write_end;
    cosim_table_read_dword_t read;
    cosim_table_completion_t completion;
} table_vcs_header_t;

static int receive_frame(cosim_table_transport_t *transport,
                         cosim_table_frame_hdr_t *frame,
                         table_vcs_header_t *header, uint8_t *payload)
{
    memset(header, 0, sizeof(*header));
    return cosim_table_recv(transport, frame, header, sizeof(*header),
                            payload, COSIM_TABLE_FRAME_DATA_BYTES, -1);
}

static int prepare_common_request(table_vcs_state_t *state, int rc,
                                  uint32_t route_id,
                                  const cosim_table_target_t *target,
                                  uint64_t bar_offset, uint8_t operation,
                                  table_vcs_request_t *request)
{
    cosim_table_route_map_t map;
    const cosim_table_route_entry_t *route;

    route = find_route(state, route_id);
    if (route == NULL || !target_matches_route(target, route, rc))
        return -1;
    map.entries = state->published_routes;
    map.count = state->published_count;
    map.generation_hash = 0;
    if (cosim_table_route_match(&map, target, bar_offset, operation) != route)
        return -1;
    request->route = route;
    request->target = *target;
    request->route_id = route_id;
    request->bar_offset = bar_offset;
    request->entry_bytes = cosim_table_le32_to_cpu(route->entry_bytes);
    return 0;
}

static int prepare_write(table_vcs_state_t *state, int rc,
                         const cosim_table_frame_hdr_t *first_frame,
                         const cosim_table_write_begin_t *begin,
                         table_vcs_request_t *request)
{
    const uint64_t transaction_id =
        cosim_table_le64_to_cpu(first_frame->transaction_id);
    uint64_t first_index;
    uint32_t entry_count;
    uint32_t payload_bytes = cosim_table_le32_to_cpu(begin->payload_bytes);

    request->kind = TABLE_VCS_REQUEST_WRITE;
    request->transaction_id = transaction_id;
    request->flags = cosim_table_le32_to_cpu(begin->flags);
    if (prepare_common_request(
            state, rc, cosim_table_le32_to_cpu(begin->route_id),
            &begin->target, cosim_table_le64_to_cpu(begin->bar_offset),
            COSIM_TABLE_OP_WRITE, request) != 0 ||
        !cosim_table_write_bytes_supported(payload_bytes) ||
        cosim_table_route_slice(request->route, request->bar_offset,
                                payload_bytes, &first_index,
                                &entry_count) != 0 ||
        first_index != cosim_table_le32_to_cpu(begin->entry_index))
        return -1;

    request->first_index = first_index;
    request->entry_count = entry_count;
    request->payload_bytes = payload_bytes;
    request->payload = allocate_payload(payload_bytes);
    if (request->payload == NULL)
        return -1;

    return 0;
}

/* Worker-only blocking assembly.  interrupt() is the only asynchronous exit
 * while a complete frame or later write fragment is pending. */
static int advance_write(cosim_table_transport_t *transport,
                         table_vcs_request_t *request,
                         uint64_t *received)
{
    const uint64_t transaction_id = request->transaction_id;

    for (;;) {
        cosim_table_frame_hdr_t frame;
        table_vcs_header_t header;
        uint8_t fragment[COSIM_TABLE_FRAME_DATA_BYTES];
        uint32_t frame_bytes;
        uint32_t data_bytes;
        int receive_result;

        receive_result = receive_frame(transport, &frame, &header, fragment);
        if (receive_result != 0 ||
            cosim_table_le64_to_cpu(frame.transaction_id) != transaction_id)
            return -1;

        if (*received == request->payload_bytes) {
            if (cosim_table_le16_to_cpu(frame.type) !=
                    COSIM_TABLE_MSG_WRITE_END ||
                cosim_table_le32_to_cpu(header.write_end.payload_bytes) !=
                    request->payload_bytes ||
                header.write_end.reserved != 0)
                return -1;
            return 1;
        }

        if (cosim_table_le16_to_cpu(frame.type) !=
            COSIM_TABLE_MSG_WRITE_DATA)
            return -1;
        frame_bytes = cosim_table_le32_to_cpu(frame.payload_bytes);
        data_bytes = cosim_table_le32_to_cpu(header.write_data.data_bytes);
        if (header.write_data.reserved != 0 || frame_bytes == 0 ||
            data_bytes != frame_bytes ||
            cosim_table_le64_to_cpu(header.write_data.data_offset) !=
                *received ||
            *received > request->payload_bytes ||
            frame_bytes > request->payload_bytes - *received)
            return -1;
        memcpy(request->payload + (size_t)*received, fragment, frame_bytes);
        *received += frame_bytes;
    }
}

static int assemble_read(table_vcs_state_t *state, int rc,
                         const cosim_table_frame_hdr_t *frame,
                         const cosim_table_read_dword_t *read,
                         table_vcs_request_t *request)
{
    uint64_t start;
    uint64_t displacement;
    uint64_t logical_index;
    uint32_t stride;
    uint32_t index_base;

    if (read->reserved != 0)
        return -1;
    request->kind = TABLE_VCS_REQUEST_READ_DWORD;
    request->transaction_id =
        cosim_table_le64_to_cpu(frame->transaction_id);
    if (prepare_common_request(
            state, rc, cosim_table_le32_to_cpu(read->route_id),
            &read->target, cosim_table_le64_to_cpu(read->bar_offset),
            COSIM_TABLE_OP_READ_DWORD, request) != 0)
        return -1;
    start = cosim_table_le64_to_cpu(request->route->start_offset);
    stride = cosim_table_le32_to_cpu(request->route->stride_bytes);
    index_base = cosim_table_le32_to_cpu(request->route->index_base);
    displacement = request->bar_offset - start;
    logical_index = displacement / stride;
    if (logical_index > UINT32_MAX - (uint64_t)index_base)
        return -1;
    request->first_index = (uint64_t)index_base + logical_index;
    request->entry_count = 1;
    request->byte_offset = (uint32_t)(displacement % stride);
    return 0;
}

static void discard_request(table_vcs_request_t *request)
{
    free(request->payload);
    memset(request, 0, sizeof(*request));
}

static void worker_mark_terminal(table_vcs_state_t *state)
{
    cosim_table_transport_t *transport;

    (void)pthread_mutex_lock(&state->lock);
    state->terminal = 1;
    state->stop_requested = 1;
    transport = state->transport;
    (void)pthread_cond_broadcast(&state->request_changed);
    (void)pthread_mutex_unlock(&state->lock);
    cosim_table_transport_interrupt(transport);
}

static void *table_vcs_worker_main(void *opaque)
{
    table_vcs_state_t *state = opaque;
    const int rc = (int)(state - table_states);
    cosim_table_transport_t *transport;

    for (;;) {
        cosim_table_frame_hdr_t frame;
        table_vcs_header_t header;
        table_vcs_request_t request;
        uint8_t payload[COSIM_TABLE_FRAME_DATA_BYTES];
        uint64_t received = 0;
        uint16_t kind;

        memset(&request, 0, sizeof(request));
        (void)pthread_mutex_lock(&state->lock);
        if (state->stop_requested || state->cleaning || state->terminal) {
            (void)pthread_mutex_unlock(&state->lock);
            break;
        }
        transport = state->transport;
        (void)pthread_mutex_unlock(&state->lock);

        if (receive_frame(transport, &frame, &header, payload) != 0)
            goto receive_failed;
        run_test_hook(rc, TABLE_VCS_TEST_HOOK_REQUEST_RECEIVED);
        kind = cosim_table_le16_to_cpu(frame.type);
        if (kind == COSIM_TABLE_MSG_WRITE_BEGIN) {
            if (prepare_write(state, rc, &frame, &header.write_begin,
                              &request) != 0)
                goto protocol_failed;
            run_test_hook(rc, TABLE_VCS_TEST_HOOK_WRITE_WAITING_DATA);
            if (advance_write(transport, &request, &received) != 1)
                goto protocol_failed;
        } else if (kind == COSIM_TABLE_MSG_READ_DWORD) {
            if (assemble_read(state, rc, &frame, &header.read, &request) != 0)
                goto protocol_failed;
        } else {
            goto protocol_failed;
        }

        (void)pthread_mutex_lock(&state->lock);
        if (state->stop_requested || state->cleaning || state->terminal) {
            (void)pthread_mutex_unlock(&state->lock);
            discard_request(&request);
            break;
        }
        if (state->outstanding) {
            (void)pthread_mutex_unlock(&state->lock);
            goto protocol_failed;
        }
        state->request = request;
        memset(&request, 0, sizeof(request));
        state->outstanding = 1;
        state->delivered = 0;
        (void)pthread_cond_broadcast(&state->request_changed);
        while (state->outstanding && !state->stop_requested &&
               !state->cleaning && !state->terminal)
            (void)pthread_cond_wait(&state->request_changed, &state->lock);
        if (state->stop_requested || state->cleaning || state->terminal) {
            (void)pthread_mutex_unlock(&state->lock);
            break;
        }
        (void)pthread_mutex_unlock(&state->lock);
        continue;

protocol_failed:
        discard_request(&request);
        worker_mark_terminal(state);
        break;

receive_failed:
        discard_request(&request);
        (void)pthread_mutex_lock(&state->lock);
        if (!state->stop_requested && !state->cleaning)
            state->terminal = 1;
        state->stop_requested = 1;
        (void)pthread_cond_broadcast(&state->request_changed);
        (void)pthread_mutex_unlock(&state->lock);
        break;
    }
    return NULL;
}

int table_vcs_poll_request_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    int result;

    if (state == NULL)
        return -1;
    (void)pthread_mutex_lock(&state->lock);
    if (!state->activated || state->cleaning || state->terminal ||
        state->stop_requested) {
        result = -1;
    } else if (!state->outstanding) {
        result = 0;
    } else if (state->delivered || state->completing) {
        result = -1;
    } else {
        state->delivered = 1;
        result = 1;
    }
    (void)pthread_mutex_unlock(&state->lock);
    return result;
}

static int completion_valid(const table_vcs_request_t *request, int status,
                            uint64_t failed_index, uint32_t committed,
                            int handler_error, uint32_t read_data)
{
    int is_read = request->kind == TABLE_VCS_REQUEST_READ_DWORD;

    if (status < COSIM_TABLE_ST_SUCCESS || status > COSIM_TABLE_ST_PROTOCOL ||
        status == COSIM_TABLE_ST_SLOT_BUSY || failed_index > UINT32_MAX)
        return 0;
    if (status == COSIM_TABLE_ST_SUCCESS) {
        if (handler_error != 0 || failed_index != UINT32_MAX)
            return 0;
        return is_read ? committed == 0
                       : committed == request->entry_count && read_data == 0;
    }
    if (status == COSIM_TABLE_ST_EXEC_ERROR) {
        if (is_read)
            return committed == 0 && failed_index == request->first_index &&
                   read_data == 0;
        return request->entry_count != 0 &&
               committed < request->entry_count &&
               failed_index == request->first_index + committed &&
               read_data == 0;
    }
    return committed == 0 && read_data == 0;
}

int table_vcs_complete_rc(int rc, int status,
                          unsigned long long failed_index,
                          unsigned int committed, int handler_error,
                          unsigned int read_data)
{
    table_vcs_state_t *state = get_state(rc);
    cosim_table_completion_t completion;
    cosim_table_frame_hdr_t frame;
    cosim_table_transport_t *transport;
    uint64_t transaction_id;
    int timeout_ms;
    int result;

    if (state == NULL)
        return -1;
    (void)pthread_mutex_lock(&state->lock);
    if (!state->outstanding || !state->delivered || state->completing ||
        state->cleaning || state->terminal ||
        !completion_valid(&state->request, status, failed_index, committed,
                          handler_error, read_data)) {
        (void)pthread_mutex_unlock(&state->lock);
        return -1;
    }
    transaction_id = state->request.transaction_id;
    transport = state->transport;
    timeout_ms = state->io_timeout_ms;
    state->completing = 1;
    state->active_io++;
    (void)pthread_mutex_unlock(&state->lock);

    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32((uint32_t)status);
    completion.failed_index =
        cosim_table_cpu_to_le32((uint32_t)failed_index);
    completion.committed_count = cosim_table_cpu_to_le32(committed);
    completion.handler_error =
        cosim_table_cpu_to_le32((uint32_t)handler_error);
    completion.returned_dword = cosim_table_cpu_to_le32(read_data);
    frame = make_frame(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0,
                       transaction_id);
    result = cosim_table_send(transport, &frame, &completion, NULL,
                              timeout_ms);

    (void)pthread_mutex_lock(&state->lock);
    if (result != 0) {
        state->terminal = 1;
        state->stop_requested = 1;
    }
    discard_request(&state->request);
    state->outstanding = 0;
    state->delivered = 0;
    state->completing = 0;
    (void)pthread_cond_broadcast(&state->request_changed);
    end_io_locked(state);
    (void)pthread_mutex_unlock(&state->lock);
    return result == 0 ? 0 : -1;
}

static int request_available(const table_vcs_state_t *state)
{
    return state->outstanding && state->delivered && !state->completing;
}

int table_vcs_get_request_kind_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    int value;

    if (state == NULL)
        return -1;
    (void)pthread_mutex_lock(&state->lock);
    value = request_available(state) ? state->request.kind : 0;
    (void)pthread_mutex_unlock(&state->lock);
    return value;
}

const char *table_vcs_get_request_handler_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    const char *value;

    if (state == NULL)
        return NULL;
    (void)pthread_mutex_lock(&state->lock);
    value = request_available(state)
        ? (const char *)state->request.route->handler_name : NULL;
    (void)pthread_mutex_unlock(&state->lock);
    return value;
}

typedef enum {
    TARGET_FIELD_RC,
    TARGET_FIELD_DEVICE,
    TARGET_FIELD_DOMAIN,
    TARGET_FIELD_BDF,
    TARGET_FIELD_TYPE,
    TARGET_FIELD_PF,
    TARGET_FIELD_VF,
    TARGET_FIELD_BAR,
} target_field_t;

static int get_target_field(int rc, target_field_t field)
{
    table_vcs_state_t *state = get_state(rc);
    const cosim_table_target_t *target;
    int value = -1;

    if (state == NULL)
        return -1;
    (void)pthread_mutex_lock(&state->lock);
    if (!request_available(state))
        goto done;
    target = &state->request.target;
    switch (field) {
    case TARGET_FIELD_RC:
        value = cosim_table_le16_to_cpu(target->rc_id);
        break;
    case TARGET_FIELD_DEVICE:
        value = cosim_table_le16_to_cpu(target->device_instance);
        break;
    case TARGET_FIELD_DOMAIN:
        value = cosim_table_le16_to_cpu(target->pci_domain);
        break;
    case TARGET_FIELD_BDF:
        value = cosim_table_le16_to_cpu(target->target_bdf);
        break;
    case TARGET_FIELD_TYPE:
        value = target->target_type;
        break;
    case TARGET_FIELD_PF:
        value = target->pf_index;
        break;
    case TARGET_FIELD_VF:
        value = cosim_table_le16_to_cpu(target->vf_index);
        break;
    case TARGET_FIELD_BAR:
        value = target->bar_index;
        break;
    }

done:
    (void)pthread_mutex_unlock(&state->lock);
    return value;
}

int table_vcs_get_request_rc_id_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_RC);
}

int table_vcs_get_request_device_instance_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_DEVICE);
}

int table_vcs_get_request_pci_domain_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_DOMAIN);
}

int table_vcs_get_request_target_bdf_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_BDF);
}

int table_vcs_get_request_target_type_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_TYPE);
}

int table_vcs_get_request_pf_index_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_PF);
}

int table_vcs_get_request_vf_index_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_VF);
}

int table_vcs_get_request_bar_index_rc(int rc)
{
    return get_target_field(rc, TARGET_FIELD_BAR);
}

typedef enum {
    REQUEST_U32_GENERATION,
    REQUEST_U32_ROUTE_ID,
    REQUEST_U32_ENTRY_COUNT,
    REQUEST_U32_ENTRY_BYTES,
    REQUEST_U32_PAYLOAD_BYTES,
    REQUEST_U32_BYTE_OFFSET,
    REQUEST_U32_FLAGS,
} request_u32_field_t;

static unsigned int get_request_u32(int rc, request_u32_field_t field)
{
    table_vcs_state_t *state = get_state(rc);
    unsigned int value = 0;

    if (state == NULL)
        return 0;
    (void)pthread_mutex_lock(&state->lock);
    if (!request_available(state))
        goto done;
    switch (field) {
    case REQUEST_U32_GENERATION:
        value = cosim_table_le32_to_cpu(state->request.target.generation);
        break;
    case REQUEST_U32_ROUTE_ID:
        value = state->request.route_id;
        break;
    case REQUEST_U32_ENTRY_COUNT:
        value = state->request.entry_count;
        break;
    case REQUEST_U32_ENTRY_BYTES:
        value = state->request.entry_bytes;
        break;
    case REQUEST_U32_PAYLOAD_BYTES:
        value = state->request.payload_bytes;
        break;
    case REQUEST_U32_BYTE_OFFSET:
        value = state->request.byte_offset;
        break;
    case REQUEST_U32_FLAGS:
        value = state->request.flags;
        break;
    }

done:
    (void)pthread_mutex_unlock(&state->lock);
    return value;
}

unsigned int table_vcs_get_request_generation_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_GENERATION);
}

unsigned int table_vcs_get_request_route_id_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_ROUTE_ID);
}

unsigned int table_vcs_get_request_entry_count_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_ENTRY_COUNT);
}

unsigned int table_vcs_get_request_entry_bytes_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_ENTRY_BYTES);
}

unsigned int table_vcs_get_request_payload_bytes_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_PAYLOAD_BYTES);
}

unsigned int table_vcs_get_request_byte_offset_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_BYTE_OFFSET);
}

unsigned int table_vcs_get_request_flags_rc(int rc)
{
    return get_request_u32(rc, REQUEST_U32_FLAGS);
}

static unsigned long long get_request_u64(int rc, int transaction)
{
    table_vcs_state_t *state = get_state(rc);
    unsigned long long value = 0;

    if (state == NULL)
        return 0;
    (void)pthread_mutex_lock(&state->lock);
    if (request_available(state))
        value = transaction ? state->request.transaction_id
                            : state->request.first_index;
    (void)pthread_mutex_unlock(&state->lock);
    return value;
}

unsigned long long table_vcs_get_request_first_index_rc(int rc)
{
    return get_request_u64(rc, 0);
}

unsigned long long table_vcs_get_request_transaction_id_rc(int rc)
{
    return get_request_u64(rc, 1);
}

unsigned long long table_vcs_get_request_bar_offset_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    unsigned long long value = 0;

    if (state == NULL)
        return 0;
    (void)pthread_mutex_lock(&state->lock);
    if (request_available(state))
        value = state->request.bar_offset;
    (void)pthread_mutex_unlock(&state->lock);
    return value;
}

unsigned long long table_vcs_get_request_payload_u64_rc(
    int rc, unsigned int word)
{
    table_vcs_state_t *state = get_state(rc);
    uint64_t result = 0;
    uint64_t offset = (uint64_t)word * 8u;
    unsigned int byte;

    if (state == NULL)
        return 0;
    (void)pthread_mutex_lock(&state->lock);
    if (!request_available(state) || state->request.payload == NULL ||
        offset >= state->request.payload_bytes)
        goto done;
    for (byte = 0; byte < 8 && offset + byte < state->request.payload_bytes;
         byte++)
        result |= (uint64_t)state->request.payload[offset + byte] <<
                  (byte * 8);

done:
    (void)pthread_mutex_unlock(&state->lock);
    return result;
}

void table_vcs_interrupt_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    cosim_table_transport_t *transport;

    if (state == NULL)
        return;
    (void)pthread_mutex_lock(&state->lock);
    state->interrupted = 1;
    state->terminal = 1;
    state->stop_requested = 1;
    transport = state->transport;
    (void)pthread_cond_broadcast(&state->request_changed);
    (void)pthread_mutex_unlock(&state->lock);
    cosim_table_transport_interrupt(transport);
}

static void reset_state_locked(table_vcs_state_t *state)
{
    discard_request(&state->request);
    cosim_table_route_free(&state->routes);
    free(state->published_routes);
    free(state->handlers);
    state->published_routes = NULL;
    state->published_count = 0;
    state->handlers = NULL;
    state->handler_count = 0;
    state->handler_capacity = 0;
    state->transport = NULL;
    state->io_timeout_ms = 0;
    state->active_io = 0;
    state->loaded = 0;
    state->initialized = 0;
    state->activated = 0;
    state->activating = 0;
    state->completing = 0;
    state->outstanding = 0;
    state->delivered = 0;
    state->worker_started = 0;
    state->stop_requested = 0;
    state->interrupted = 0;
    state->terminal = 0;
    state->cleaning = 0;
}

void table_vcs_cleanup_rc(int rc)
{
    table_vcs_state_t *state = get_state(rc);
    cosim_table_transport_t *transport;
    pthread_t worker;
    int join_worker;

    if (state == NULL)
        return;
    (void)pthread_mutex_lock(&state->lock);
    if (state->cleaning) {
        (void)pthread_mutex_unlock(&state->lock);
        return;
    }
    if (state->worker_started &&
        pthread_equal(state->worker, pthread_self())) {
        state->interrupted = 1;
        state->terminal = 1;
        state->stop_requested = 1;
        transport = state->transport;
        (void)pthread_cond_broadcast(&state->request_changed);
        (void)pthread_mutex_unlock(&state->lock);
        cosim_table_transport_interrupt(transport);
        return;
    }
    state->cleaning = 1;
    state->interrupted = 1;
    state->terminal = 1;
    state->stop_requested = 1;
    transport = state->transport;
    worker = state->worker;
    join_worker = state->worker_started;
    run_test_hook(rc, TABLE_VCS_TEST_HOOK_CLEANUP_CLAIMED);
    (void)pthread_cond_broadcast(&state->request_changed);
    (void)pthread_mutex_unlock(&state->lock);

    cosim_table_transport_interrupt(transport);
    if (join_worker)
        (void)pthread_join(worker, NULL);

    (void)pthread_mutex_lock(&state->lock);
    while (state->active_io != 0)
        (void)pthread_cond_wait(&state->idle, &state->lock);
    discard_request(&state->request);
    cosim_table_route_free(&state->routes);
    free(state->published_routes);
    free(state->handlers);
    state->published_routes = NULL;
    state->published_count = 0;
    state->handlers = NULL;
    state->handler_count = 0;
    state->handler_capacity = 0;
    state->transport = NULL;
    (void)pthread_mutex_unlock(&state->lock);

    cosim_table_transport_close(transport);

    (void)pthread_mutex_lock(&state->lock);
    reset_state_locked(state);
    (void)pthread_mutex_unlock(&state->lock);
}
