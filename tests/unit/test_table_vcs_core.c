#define _POSIX_C_SOURCE 200809L

#include "cosim_table_ctrl_uapi.h"
#include "cosim_table_route.h"
#include "cosim_table_transport.h"
#include "table_vcs_core.h"

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__,       \
                    #condition);                                               \
            abort();                                                           \
        }                                                                      \
    } while (0)

enum {
    TEST_TIMEOUT_MS = 3000,
    TEST_ENTRY_BYTES = 128,
    TEST_PAYLOAD_BYTES = 256,
};

typedef enum {
    PEER_HAPPY,
    PEER_NO_ROUTE_FRAMES,
    PEER_BAD_FRAGMENT_SEQUENCE,
    PEER_BAD_TRANSACTION,
    PEER_BAD_TYPE,
    PEER_BAD_LENGTH,
    PEER_BAD_ROUTE_ID,
    PEER_BAD_TARGET_RC,
    PEER_WAIT_FOR_CLEANUP,
    PEER_ROUTES_ONLY,
    PEER_IDLE_THEN_CLOSE,
    PEER_DELAYED_WRITE,
    PEER_ROUTES_ACCEPT_CLOSE,
} peer_kind_t;

enum {
    TABLE_VCS_TEST_HOOK_ACTIVATION_CLAIMED = 1,
    TABLE_VCS_TEST_HOOK_ACTIVATION_END_SENT = 2,
    TABLE_VCS_TEST_HOOK_CLEANUP_CLAIMED = 3,
    TABLE_VCS_TEST_HOOK_WRITE_WAITING_DATA = 4,
};

typedef struct {
    cosim_table_transport_t *transport;
    peer_kind_t kind;
    int rc;
    uint8_t seed;
    uint32_t published_generation;
    uint32_t request_payload_bytes;
} peer_context_t;

typedef struct {
    int rc;
    int result;
} poll_context_t;

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    int enabled;
    int rc;
    int block_event;
    int released;
    unsigned int count[5];
} hook_control_t;

typedef struct {
    int rc;
    int result;
} activate_context_t;

typedef struct {
    pthread_mutex_t lock;
    int enabled;
    int fail;
    unsigned int calls;
    size_t last_bytes;
} allocation_control_t;

typedef struct {
    int rc;
} cleanup_context_t;

static hook_control_t hook_control = {
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_COND_INITIALIZER,
    0,
    0,
    0,
    0,
    { 0, 0, 0, 0, 0 },
};

static allocation_control_t allocation_control = {
    PTHREAD_MUTEX_INITIALIZER,
    0,
    0,
    0,
    0,
};

static struct timespec realtime_after_ms(long milliseconds);

static struct {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    int waiting;
    int released;
} delayed_peer_control = {
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_COND_INITIALIZER,
    0,
    0,
};

static void delayed_peer_reset(void)
{
    CHECK(pthread_mutex_lock(&delayed_peer_control.lock) == 0);
    delayed_peer_control.waiting = 0;
    delayed_peer_control.released = 0;
    CHECK(pthread_mutex_unlock(&delayed_peer_control.lock) == 0);
}

static void delayed_peer_wait_until_paused(void)
{
    struct timespec deadline = realtime_after_ms(TEST_TIMEOUT_MS);

    CHECK(pthread_mutex_lock(&delayed_peer_control.lock) == 0);
    while (!delayed_peer_control.waiting)
        CHECK(pthread_cond_timedwait(&delayed_peer_control.condition,
                                     &delayed_peer_control.lock,
                                     &deadline) == 0);
    CHECK(pthread_mutex_unlock(&delayed_peer_control.lock) == 0);
}

static void delayed_peer_release(void)
{
    CHECK(pthread_mutex_lock(&delayed_peer_control.lock) == 0);
    delayed_peer_control.released = 1;
    CHECK(pthread_cond_broadcast(&delayed_peer_control.condition) == 0);
    CHECK(pthread_mutex_unlock(&delayed_peer_control.lock) == 0);
}

void *table_vcs_test_alloc(size_t bytes)
{
    int fail;

    CHECK(pthread_mutex_lock(&allocation_control.lock) == 0);
    if (allocation_control.enabled) {
        allocation_control.calls++;
        allocation_control.last_bytes = bytes;
    }
    fail = allocation_control.enabled && allocation_control.fail;
    CHECK(pthread_mutex_unlock(&allocation_control.lock) == 0);
    return fail ? NULL : malloc(bytes);
}

static void allocation_enable(int fail)
{
    CHECK(pthread_mutex_lock(&allocation_control.lock) == 0);
    allocation_control.enabled = 1;
    allocation_control.fail = fail;
    allocation_control.calls = 0;
    allocation_control.last_bytes = 0;
    CHECK(pthread_mutex_unlock(&allocation_control.lock) == 0);
}

static void allocation_check(unsigned int calls, size_t last_bytes)
{
    CHECK(pthread_mutex_lock(&allocation_control.lock) == 0);
    CHECK(allocation_control.calls == calls);
    CHECK(allocation_control.last_bytes == last_bytes);
    CHECK(pthread_mutex_unlock(&allocation_control.lock) == 0);
}

static void allocation_disable(void)
{
    CHECK(pthread_mutex_lock(&allocation_control.lock) == 0);
    allocation_control.enabled = 0;
    allocation_control.fail = 0;
    CHECK(pthread_mutex_unlock(&allocation_control.lock) == 0);
}

static struct timespec realtime_after_ms(long milliseconds)
{
    struct timespec deadline;

    CHECK(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += milliseconds / 1000;
    deadline.tv_nsec += (milliseconds % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

/* Strong test definition resolves the production core's optional weak hook. */
void table_vcs_test_hook(int rc, int event)
{
    CHECK(pthread_mutex_lock(&hook_control.lock) == 0);
    if (hook_control.enabled && hook_control.rc == rc && event > 0 &&
        (size_t)event < sizeof(hook_control.count) /
                            sizeof(hook_control.count[0])) {
        hook_control.count[event]++;
        CHECK(pthread_cond_broadcast(&hook_control.condition) == 0);
        while (hook_control.enabled && event == hook_control.block_event &&
               hook_control.count[event] == 1 && !hook_control.released)
            CHECK(pthread_cond_wait(&hook_control.condition,
                                    &hook_control.lock) == 0);
    }
    CHECK(pthread_mutex_unlock(&hook_control.lock) == 0);
}

static void hook_enable(int rc, int block_event)
{
    CHECK(pthread_mutex_lock(&hook_control.lock) == 0);
    memset(hook_control.count, 0, sizeof(hook_control.count));
    hook_control.enabled = 1;
    hook_control.rc = rc;
    hook_control.block_event = block_event;
    hook_control.released = 0;
    CHECK(pthread_mutex_unlock(&hook_control.lock) == 0);
}

static void hook_wait(int event)
{
    struct timespec deadline = realtime_after_ms(TEST_TIMEOUT_MS);

    CHECK(pthread_mutex_lock(&hook_control.lock) == 0);
    while (hook_control.count[event] == 0)
        CHECK(pthread_cond_timedwait(&hook_control.condition,
                                     &hook_control.lock, &deadline) == 0);
    CHECK(pthread_mutex_unlock(&hook_control.lock) == 0);
}

static void hook_release(void)
{
    CHECK(pthread_mutex_lock(&hook_control.lock) == 0);
    hook_control.released = 1;
    CHECK(pthread_cond_broadcast(&hook_control.condition) == 0);
    CHECK(pthread_mutex_unlock(&hook_control.lock) == 0);
}

static void hook_disable(void)
{
    CHECK(pthread_mutex_lock(&hook_control.lock) == 0);
    hook_control.enabled = 0;
    hook_control.released = 1;
    CHECK(pthread_cond_broadcast(&hook_control.condition) == 0);
    CHECK(pthread_mutex_unlock(&hook_control.lock) == 0);
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

static void check_frame(const cosim_table_frame_hdr_t *frame,
                        uint16_t type, uint64_t transaction_id)
{
    CHECK(cosim_table_le16_to_cpu(frame->type) == type);
    CHECK(cosim_table_le64_to_cpu(frame->transaction_id) == transaction_id);
}

static uint16_t reserve_available_port(void)
{
    struct sockaddr_in address;
    socklen_t address_bytes = sizeof(address);
    int fd;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(fd >= 0);
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(0);
    CHECK(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    CHECK(getsockname(fd, (struct sockaddr *)&address, &address_bytes) == 0);
    CHECK(close(fd) == 0);
    CHECK(ntohs(address.sin_port) > 3);
    return ntohs(address.sin_port);
}

static cosim_table_transport_t *create_server(uint16_t port, int instance_id,
                                               int rc)
{
    cosim_table_transport_cfg_t cfg;

    memset(&cfg, 0, sizeof(cfg));
    cfg.listen_addr = "127.0.0.1";
    cfg.table_port_base = (uint32_t)port - (uint32_t)instance_id;
    cfg.instance_id = (uint32_t)instance_id;
    cfg.rc_id = (uint16_t)rc;
    cfg.is_server = 1;
    cfg.connect_timeout_ms = TEST_TIMEOUT_MS;
    return cosim_table_transport_create(&cfg);
}

static void append_fixture(FILE *output, int rc)
{
    FILE *input = fopen(TABLE_ROUTE_FIXTURE, "r");
    char line[512];

    CHECK(input != NULL);
    while (fgets(line, sizeof(line), input) != NULL) {
        if (strcmp(line, "rc=0\n") == 0)
            CHECK(fprintf(output, "rc=%d\n", rc) > 0);
        else
            CHECK(fputs(line, output) >= 0);
    }
    CHECK(!ferror(input));
    CHECK(fclose(input) == 0);
}

static void make_shared_route_file(char path[64])
{
    int fd;
    FILE *output;

    memcpy(path, "/tmp/table_vcs_routes_XXXXXX",
           sizeof("/tmp/table_vcs_routes_XXXXXX"));
    fd = mkstemp(path);
    CHECK(fd >= 0);
    output = fdopen(fd, "w");
    CHECK(output != NULL);
    append_fixture(output, 0);
    CHECK(fputc('\n', output) != EOF);
    append_fixture(output, 1);
    CHECK(fclose(output) == 0);
}

static void make_partial_route_file(char path[64])
{
    int fd;
    FILE *output;

    memcpy(path, "/tmp/table_vcs_partial_XXXXXX",
           sizeof("/tmp/table_vcs_partial_XXXXXX"));
    fd = mkstemp(path);
    CHECK(fd >= 0);
    output = fdopen(fd, "w");
    CHECK(output != NULL);
    CHECK(fprintf(output,
                  "[route.partial]\n"
                  "rc=0\n"
                  "device=0\n"
                  "target=pf0\n"
                  "bar=0\n"
                  "start=0x8000\n"
                  "end=0x8014\n"
                  "entry_bytes=10\n"
                  "stride_bytes=10\n"
                  "index_base=7\n"
                  "handler=partial\n") > 0);
    CHECK(fclose(output) == 0);
}

static void make_write_limit_route_file(char path[64])
{
    int fd;
    FILE *output;

    memcpy(path, "/tmp/table_vcs_limit_XXXXXX",
           sizeof("/tmp/table_vcs_limit_XXXXXX"));
    fd = mkstemp(path);
    CHECK(fd >= 0);
    output = fdopen(fd, "w");
    CHECK(output != NULL);
    CHECK(fprintf(output,
                  "[route.limit]\n"
                  "rc=0\n"
                  "device=0\n"
                  "target=pf0\n"
                  "bar=0\n"
                  "start=0\n"
                  "end=0x4000001\n"
                  "entry_bytes=1\n"
                  "stride_bytes=1\n"
                  "index_base=0\n"
                  "handler=limit\n") > 0);
    CHECK(fclose(output) == 0);
}

static uint8_t payload_byte(uint8_t seed, size_t offset)
{
    return (uint8_t)(seed + (uint8_t)(offset * 37u));
}

static uint64_t payload_word(uint8_t seed, size_t word)
{
    uint64_t result = 0;
    size_t byte;

    for (byte = 0; byte < 8; byte++)
        result |= (uint64_t)payload_byte(seed, word * 8 + byte) << (byte * 8);
    return result;
}

static uint32_t expected_route_id(int rc, unsigned int local_route)
{
    return (uint32_t)rc * 3u + local_route;
}

static uint32_t expected_generation(const cosim_table_route_entry_t *routes,
                                    size_t count)
{
    const uint8_t *bytes = (const uint8_t *)routes;
    size_t total = count * sizeof(*routes);
    uint64_t hash = UINT64_C(14695981039346656037);
    uint32_t generation;
    size_t i;

    for (i = 0; i < total; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    generation = (uint32_t)hash ^ (uint32_t)(hash >> 32);
    return generation != 0 ? generation : 1;
}

static void receive_route_generation(peer_context_t *peer)
{
    cosim_table_frame_hdr_t frame;
    cosim_table_route_begin_t begin;
    cosim_table_route_entry_t routes[3];
    cosim_table_route_end_t end;
    uint64_t transaction_id;
    unsigned int i;

    memset(&begin, 0, sizeof(begin));
    CHECK(cosim_table_recv(peer->transport, &frame, &begin, sizeof(begin),
                           NULL, 0, TEST_TIMEOUT_MS) == 0);
    CHECK(cosim_table_le16_to_cpu(frame.type) == COSIM_TABLE_MSG_ROUTE_BEGIN);
    transaction_id = cosim_table_le64_to_cpu(frame.transaction_id);
    CHECK(transaction_id != 0);
    peer->published_generation = cosim_table_le32_to_cpu(begin.generation);
    CHECK(peer->published_generation != 0);
    CHECK(cosim_table_le32_to_cpu(begin.entry_count) == 3);

    for (i = 0; i < 3; i++) {
        memset(&routes[i], 0, sizeof(routes[i]));
        CHECK(cosim_table_recv(peer->transport, &frame, &routes[i],
                               sizeof(routes[i]), NULL, 0,
                               TEST_TIMEOUT_MS) == 0);
        check_frame(&frame, COSIM_TABLE_MSG_ROUTE_ENTRY, transaction_id);
        CHECK(cosim_table_le32_to_cpu(routes[i].route_id) ==
              expected_route_id(peer->rc, i));
        CHECK(cosim_table_le16_to_cpu(routes[i].target.rc_id) == peer->rc);
        CHECK(cosim_table_le16_to_cpu(routes[i].target.pci_domain) == 0);
        CHECK(cosim_table_le16_to_cpu(routes[i].target.target_bdf) == 0);
        CHECK(cosim_table_le32_to_cpu(routes[i].target.generation) == 0);
        CHECK(routes[i].handler_name[0] != '\0');
    }
    CHECK(peer->published_generation == expected_generation(routes, 3));

    memset(&end, 0, sizeof(end));
    CHECK(cosim_table_recv(peer->transport, &frame, &end, sizeof(end),
                           NULL, 0, TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_ROUTE_END, transaction_id);
    CHECK(cosim_table_le32_to_cpu(end.generation) ==
          peer->published_generation);
}

static cosim_table_write_begin_t make_write_begin(const peer_context_t *peer)
{
    cosim_table_write_begin_t begin;

    memset(&begin, 0, sizeof(begin));
    cosim_table_target_set_identity(
        &begin.target, (uint16_t)peer->rc, 0, (uint16_t)(2 + peer->rc),
        (uint16_t)(0x18 + peer->rc), (uint32_t)(0x100 + peer->rc));
    begin.target.target_type = COSIM_TABLE_TARGET_PF;
    begin.target.pf_index = 0;
    begin.target.vf_index = 0;
    begin.target.bar_index = 1;
    begin.route_id = cosim_table_cpu_to_le32(expected_route_id(peer->rc, 2));
    begin.entry_index = cosim_table_cpu_to_le32(33);
    begin.bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x6080));
    begin.payload_bytes = cosim_table_cpu_to_le32(TEST_PAYLOAD_BYTES);
    begin.flags = cosim_table_cpu_to_le32(UINT32_C(0x5a00) +
                                          (uint32_t)peer->rc);
    return begin;
}

static void send_fragment(cosim_table_transport_t *transport,
                          uint64_t transaction_id, uint64_t offset,
                          uint32_t header_bytes, uint32_t actual_bytes,
                          uint8_t seed)
{
    cosim_table_write_data_t data;
    cosim_table_frame_hdr_t frame;
    uint8_t payload[TEST_PAYLOAD_BYTES];
    size_t i;

    CHECK(actual_bytes <= sizeof(payload));
    memset(&data, 0, sizeof(data));
    data.data_offset = cosim_table_cpu_to_le64(offset);
    data.data_bytes = cosim_table_cpu_to_le32(header_bytes);
    for (i = 0; i < actual_bytes; i++)
        payload[i] = payload_byte(seed, (size_t)offset + i);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_DATA, sizeof(data), actual_bytes,
                       transaction_id);
    CHECK(cosim_table_send(transport, &frame, &data, payload,
                           TEST_TIMEOUT_MS) == 0);
}

static void receive_write_completion(peer_context_t *peer,
                                     uint64_t transaction_id)
{
    cosim_table_completion_t completion;
    cosim_table_frame_hdr_t frame;

    memset(&completion, 0, sizeof(completion));
    CHECK(cosim_table_recv(peer->transport, &frame, &completion,
                           sizeof(completion), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_COMPLETION, transaction_id);
    CHECK(cosim_table_le32_to_cpu(completion.status) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(cosim_table_le32_to_cpu(completion.failed_index) == UINT32_MAX);
    CHECK(cosim_table_le32_to_cpu(completion.committed_count) == 2);
    CHECK(cosim_table_le32_to_cpu(completion.handler_error) == 0);
    CHECK(cosim_table_le32_to_cpu(completion.returned_dword) == 0);
}

static void send_read_request(peer_context_t *peer, uint64_t transaction_id)
{
    cosim_table_read_dword_t request;
    cosim_table_frame_hdr_t frame;

    memset(&request, 0, sizeof(request));
    cosim_table_target_set_identity(
        &request.target, (uint16_t)peer->rc, 0, (uint16_t)(2 + peer->rc),
        (uint16_t)(0x18 + peer->rc), (uint32_t)(0x100 + peer->rc));
    request.target.target_type = COSIM_TABLE_TARGET_PF;
    request.target.pf_index = 0;
    request.target.bar_index = 1;
    request.bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x6084));
    request.route_id =
        cosim_table_cpu_to_le32(expected_route_id(peer->rc, 2));
    frame = make_frame(COSIM_TABLE_MSG_READ_DWORD, sizeof(request), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &request, NULL,
                           TEST_TIMEOUT_MS) == 0);
}

static void receive_read_completion(peer_context_t *peer,
                                    uint64_t transaction_id)
{
    cosim_table_completion_t completion;
    cosim_table_frame_hdr_t frame;
    uint32_t expected = UINT32_C(0x11223300) + (uint32_t)peer->rc;

    memset(&completion, 0, sizeof(completion));
    CHECK(cosim_table_recv(peer->transport, &frame, &completion,
                           sizeof(completion), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_COMPLETION, transaction_id);
    CHECK(cosim_table_le32_to_cpu(completion.status) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(cosim_table_le32_to_cpu(completion.failed_index) == UINT32_MAX);
    CHECK(cosim_table_le32_to_cpu(completion.committed_count) == 0);
    CHECK(cosim_table_le32_to_cpu(completion.returned_dword) == expected);
}

static void run_happy_peer(peer_context_t *peer)
{
    const uint64_t write_transaction = UINT64_C(0x1000) +
                                       (uint64_t)peer->rc * 16u;
    cosim_table_write_begin_t begin =
        make_write_begin(peer);
    cosim_table_write_end_t end;
    cosim_table_frame_hdr_t frame;

    frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(begin), 0,
                       write_transaction);
    CHECK(cosim_table_send(peer->transport, &frame, &begin, NULL,
                           TEST_TIMEOUT_MS) == 0);
    send_fragment(peer->transport, write_transaction, 0, 63, 63, peer->seed);
    send_fragment(peer->transport, write_transaction, 63,
                  TEST_PAYLOAD_BYTES - 63, TEST_PAYLOAD_BYTES - 63,
                  peer->seed);
    memset(&end, 0, sizeof(end));
    end.payload_bytes = cosim_table_cpu_to_le32(TEST_PAYLOAD_BYTES);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_END, sizeof(end), 0,
                       write_transaction);
    CHECK(cosim_table_send(peer->transport, &frame, &end, NULL,
                           TEST_TIMEOUT_MS) == 0);

    send_read_request(peer, write_transaction + 1);
    receive_write_completion(peer, write_transaction);
    receive_read_completion(peer, write_transaction + 1);
}

static void run_delayed_write_peer(peer_context_t *peer)
{
    const uint64_t transaction_id = UINT64_C(0xd100);
    cosim_table_write_begin_t begin = make_write_begin(peer);
    cosim_table_write_end_t end;
    cosim_table_frame_hdr_t frame;
    struct timespec deadline = realtime_after_ms(500);
    int wait_result = 0;

    frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(begin), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &begin, NULL,
                           TEST_TIMEOUT_MS) == 0);

    CHECK(pthread_mutex_lock(&delayed_peer_control.lock) == 0);
    delayed_peer_control.waiting = 1;
    CHECK(pthread_cond_broadcast(&delayed_peer_control.condition) == 0);
    while (!delayed_peer_control.released && wait_result == 0)
        wait_result = pthread_cond_timedwait(&delayed_peer_control.condition,
                                             &delayed_peer_control.lock,
                                             &deadline);
    CHECK(wait_result == 0 || wait_result == ETIMEDOUT);
    CHECK(pthread_mutex_unlock(&delayed_peer_control.lock) == 0);

    send_fragment(peer->transport, transaction_id, 0, 63, 63, peer->seed);
    send_fragment(peer->transport, transaction_id, 63,
                  TEST_PAYLOAD_BYTES - 63, TEST_PAYLOAD_BYTES - 63,
                  peer->seed);
    memset(&end, 0, sizeof(end));
    end.payload_bytes = cosim_table_cpu_to_le32(TEST_PAYLOAD_BYTES);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_END, sizeof(end), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &end, NULL,
                           TEST_TIMEOUT_MS) == 0);
    receive_write_completion(peer, transaction_id);
}

static void send_invalid_request(peer_context_t *peer)
{
    const uint64_t transaction_id = UINT64_C(0x8800) +
                                    (uint64_t)peer->kind;
    cosim_table_write_begin_t begin =
        make_write_begin(peer);
    cosim_table_write_end_t end;
    cosim_table_frame_hdr_t frame;

    if (peer->kind == PEER_BAD_ROUTE_ID)
        begin.route_id = cosim_table_cpu_to_le32(1);
    if (peer->kind == PEER_BAD_TARGET_RC)
        begin.target.rc_id = cosim_table_cpu_to_le16(1);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(begin), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &begin, NULL,
                           TEST_TIMEOUT_MS) == 0);
    if (peer->kind == PEER_BAD_ROUTE_ID ||
        peer->kind == PEER_BAD_TARGET_RC)
        return;
    if (peer->kind == PEER_BAD_FRAGMENT_SEQUENCE) {
        send_fragment(peer->transport, transaction_id, 1, 8, 8, peer->seed);
    } else if (peer->kind == PEER_BAD_TRANSACTION) {
        send_fragment(peer->transport, transaction_id + 1, 0, 8, 8,
                      peer->seed);
    } else if (peer->kind == PEER_BAD_LENGTH) {
        send_fragment(peer->transport, transaction_id, 0, 7, 8, peer->seed);
    } else {
        CHECK(peer->kind == PEER_BAD_TYPE);
        memset(&end, 0, sizeof(end));
        end.payload_bytes = cosim_table_cpu_to_le32(TEST_PAYLOAD_BYTES);
        frame = make_frame(COSIM_TABLE_MSG_WRITE_END, sizeof(end), 0,
                           transaction_id);
        CHECK(cosim_table_send(peer->transport, &frame, &end, NULL,
                               TEST_TIMEOUT_MS) == 0);
    }
}

static void *peer_main(void *opaque)
{
    peer_context_t *peer = opaque;

    if (peer->kind == PEER_NO_ROUTE_FRAMES) {
        cosim_table_frame_hdr_t frame;
        unsigned char header[sizeof(cosim_table_route_entry_t)];
        unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];

        CHECK(cosim_table_recv(peer->transport, &frame, header,
                               sizeof(header), payload, sizeof(payload),
                               200) == 1);
        return NULL;
    }

    receive_route_generation(peer);
    if (peer->kind == PEER_HAPPY) {
        run_happy_peer(peer);
    } else if (peer->kind == PEER_DELAYED_WRITE) {
        run_delayed_write_peer(peer);
    } else if (peer->kind == PEER_ROUTES_ACCEPT_CLOSE) {
        return NULL;
    } else if (peer->kind == PEER_ROUTES_ONLY) {
        cosim_table_frame_hdr_t frame;
        unsigned char header[sizeof(cosim_table_route_entry_t)];
        unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];

        CHECK(cosim_table_recv(peer->transport, &frame, header,
                               sizeof(header), payload, sizeof(payload),
                               200) == 1);
    } else if (peer->kind == PEER_IDLE_THEN_CLOSE) {
        struct timespec pause = { 0, 200 * 1000 * 1000L };

        CHECK(nanosleep(&pause, NULL) == 0);
        cosim_table_transport_interrupt(peer->transport);
    } else if (peer->kind == PEER_WAIT_FOR_CLEANUP) {
        const uint64_t transaction_id = UINT64_C(0xc100);
        cosim_table_write_begin_t begin = make_write_begin(peer);
        cosim_table_frame_hdr_t frame;
        unsigned char header[sizeof(cosim_table_route_entry_t)];
        unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];

        frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(begin), 0,
                           transaction_id);
        CHECK(cosim_table_send(peer->transport, &frame, &begin, NULL,
                               TEST_TIMEOUT_MS) == 0);
        CHECK(cosim_table_recv(peer->transport, &frame, header,
                               sizeof(header), payload, sizeof(payload),
                               -1) == -1);
    } else {
        send_invalid_request(peer);
    }
    return NULL;
}

static void *cleanup_main(void *opaque)
{
    cleanup_context_t *cleanup = opaque;

    table_vcs_cleanup_rc(cleanup->rc);
    return NULL;
}

static void *activate_main(void *opaque)
{
    activate_context_t *activate = opaque;

    activate->result = table_vcs_activate_routes_rc(activate->rc);
    return NULL;
}

static void register_handlers(int rc, int include_readable,
                              int readable_supports_read);
static int poll_until_nonidle(int rc);

static void test_concurrent_activation_publishes_once(const char *route_path)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    activate_context_t first;
    pthread_t peer_thread;
    pthread_t activate_thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_ROUTES_ONLY;
    peer.rc = 0;
    CHECK(pthread_create(&peer_thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);

    memset(&first, 0, sizeof(first));
    hook_enable(0, TABLE_VCS_TEST_HOOK_ACTIVATION_CLAIMED);
    CHECK(pthread_create(&activate_thread, NULL, activate_main, &first) == 0);
    hook_wait(TABLE_VCS_TEST_HOOK_ACTIVATION_CLAIMED);
    CHECK(table_vcs_activate_routes_rc(0) == -1);
    hook_release();
    CHECK(pthread_join(activate_thread, NULL) == 0);
    CHECK(first.result == 0);
    CHECK(pthread_join(peer_thread, NULL) == 0);
    hook_disable();
    table_vcs_cleanup_rc(0);
    cosim_table_transport_close(server);
}

static void test_preflight_uses_bounded_subset_allocator(
    const char *route_path)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    pthread_t peer_thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_NO_ROUTE_FRAMES;
    peer.rc = 0;
    CHECK(pthread_create(&peer_thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);

    allocation_enable(1);
    CHECK(table_vcs_activate_routes_rc(0) == -1);
    allocation_check(1, 3 * sizeof(cosim_table_route_entry_t));
    allocation_disable();
    CHECK(pthread_join(peer_thread, NULL) == 0);
    table_vcs_cleanup_rc(0);
    cosim_table_transport_close(server);
}

static void test_cleanup_wins_after_activation_end(const char *route_path)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    activate_context_t activate;
    cleanup_context_t cleanup;
    pthread_t peer_thread;
    pthread_t activate_thread;
    pthread_t cleanup_thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_ROUTES_ACCEPT_CLOSE;
    peer.rc = 0;
    CHECK(pthread_create(&peer_thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);

    memset(&activate, 0, sizeof(activate));
    memset(&cleanup, 0, sizeof(cleanup));
    hook_enable(0, TABLE_VCS_TEST_HOOK_ACTIVATION_END_SENT);
    CHECK(pthread_create(&activate_thread, NULL, activate_main, &activate) == 0);
    hook_wait(TABLE_VCS_TEST_HOOK_ACTIVATION_END_SENT);
    CHECK(pthread_create(&cleanup_thread, NULL, cleanup_main, &cleanup) == 0);
    hook_wait(TABLE_VCS_TEST_HOOK_CLEANUP_CLAIMED);
    hook_release();
    CHECK(pthread_join(activate_thread, NULL) == 0);
    CHECK(activate.result == -1);
    CHECK(pthread_join(cleanup_thread, NULL) == 0);
    CHECK(pthread_join(peer_thread, NULL) == 0);
    hook_disable();
    cosim_table_transport_close(server);
}

static void register_handlers(int rc, int include_readable,
                              int readable_supports_read)
{
    CHECK(table_vcs_register_handler_rc(rc, "default_write", 0) == 0);
    CHECK(table_vcs_register_handler_rc(rc, "explicit_write", 0) == 0);
    if (include_readable) {
        CHECK(table_vcs_register_handler_rc(
                  rc, "readable", readable_supports_read) == 0);
    }
}

static void check_write_request(int rc, uint8_t seed)
{
    uint64_t transaction = UINT64_C(0x1000) + (uint64_t)rc * 16u;

    CHECK(poll_until_nonidle(rc) == 1);
    CHECK(table_vcs_get_request_kind_rc(rc) == TABLE_VCS_REQUEST_WRITE);
    CHECK(strcmp(table_vcs_get_request_handler_rc(rc), "readable") == 0);
    CHECK(table_vcs_get_request_rc_id_rc(rc) == rc);
    CHECK(table_vcs_get_request_device_instance_rc(rc) == 0);
    CHECK(table_vcs_get_request_pci_domain_rc(rc) == 2 + rc);
    CHECK(table_vcs_get_request_target_bdf_rc(rc) == 0x18 + rc);
    CHECK(table_vcs_get_request_target_type_rc(rc) == COSIM_TABLE_TARGET_PF);
    CHECK(table_vcs_get_request_pf_index_rc(rc) == 0);
    CHECK(table_vcs_get_request_vf_index_rc(rc) == 0);
    CHECK(table_vcs_get_request_bar_index_rc(rc) == 1);
    CHECK(table_vcs_get_request_generation_rc(rc) == (unsigned int)(0x100 + rc));
    CHECK(table_vcs_get_request_route_id_rc(rc) == expected_route_id(rc, 2));
    CHECK(table_vcs_get_request_first_index_rc(rc) == 33);
    CHECK(table_vcs_get_request_bar_offset_rc(rc) == UINT64_C(0x6080));
    CHECK(table_vcs_get_request_entry_count_rc(rc) == 2);
    CHECK(table_vcs_get_request_entry_bytes_rc(rc) == TEST_ENTRY_BYTES);
    CHECK(table_vcs_get_request_payload_bytes_rc(rc) == TEST_PAYLOAD_BYTES);
    CHECK(table_vcs_get_request_byte_offset_rc(rc) == 0);
    CHECK(table_vcs_get_request_flags_rc(rc) ==
          (unsigned int)(0x5a00 + rc));
    CHECK(table_vcs_get_request_transaction_id_rc(rc) == transaction);
    CHECK(table_vcs_get_request_payload_u64_rc(rc, 0) ==
          payload_word(seed, 0));
    CHECK(table_vcs_get_request_payload_u64_rc(rc, 31) ==
          payload_word(seed, 31));

    CHECK(table_vcs_poll_request_rc(rc) == -1);
    CHECK(table_vcs_get_request_transaction_id_rc(rc) == transaction);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                1, 0, 0) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SLOT_BUSY, UINT32_MAX,
                                0, 0, 0) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                2, 1, 0) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                2, 0, 1) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                2, 0, 0) == 0);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                2, 0, 0) == -1);
}

static void check_read_request(int rc)
{
    uint64_t transaction = UINT64_C(0x1001) + (uint64_t)rc * 16u;
    uint32_t read_data = UINT32_C(0x11223300) + (uint32_t)rc;

    CHECK(poll_until_nonidle(rc) == 1);
    CHECK(table_vcs_get_request_kind_rc(rc) == TABLE_VCS_REQUEST_READ_DWORD);
    CHECK(strcmp(table_vcs_get_request_handler_rc(rc), "readable") == 0);
    CHECK(table_vcs_get_request_first_index_rc(rc) == 33);
    CHECK(table_vcs_get_request_bar_offset_rc(rc) == UINT64_C(0x6084));
    CHECK(table_vcs_get_request_entry_count_rc(rc) == 1);
    CHECK(table_vcs_get_request_entry_bytes_rc(rc) == TEST_ENTRY_BYTES);
    CHECK(table_vcs_get_request_payload_bytes_rc(rc) == 0);
    CHECK(table_vcs_get_request_byte_offset_rc(rc) == 4);
    CHECK(table_vcs_get_request_flags_rc(rc) == 0);
    CHECK(table_vcs_get_request_transaction_id_rc(rc) == transaction);
    CHECK(table_vcs_get_request_payload_u64_rc(rc, 0) == 0);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                1, 0, read_data) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, 33,
                                0, 0, read_data) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                0, 1, read_data) == -1);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                0, 0, read_data) == 0);
    CHECK(table_vcs_complete_rc(rc, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                0, 0, read_data) == -1);
}

static void test_per_rc_activation_reassembly_and_completion(
    const char *route_path)
{
    const uint8_t seeds[2] = { 0x13, 0x97 };
    uint16_t ports[2];
    cosim_table_transport_t *servers[2];
    peer_context_t peers[2];
    pthread_t threads[2];
    int rc;

    memset(peers, 0, sizeof(peers));
    for (rc = 0; rc < 2; rc++) {
        ports[rc] = reserve_available_port();
        servers[rc] = create_server(ports[rc], rc, rc);
        CHECK(servers[rc] != NULL);
        peers[rc].transport = servers[rc];
        peers[rc].kind = PEER_HAPPY;
        peers[rc].rc = rc;
        peers[rc].seed = seeds[rc];
        CHECK(pthread_create(&threads[rc], NULL, peer_main, &peers[rc]) == 0);

        CHECK(table_vcs_load_routes_rc(rc, route_path) == 0);
        register_handlers(rc, 1, 1);
        CHECK(table_vcs_init_rc(rc, "127.0.0.1", ports[rc] - rc, rc,
                                TEST_TIMEOUT_MS) == 0);
        CHECK(table_vcs_activate_routes_rc(rc) == 0);
    }

    check_write_request(0, seeds[0]);
    CHECK(table_vcs_get_request_kind_rc(1) == 0);
    check_write_request(1, seeds[1]);
    check_read_request(0);
    check_read_request(1);

    for (rc = 0; rc < 2; rc++) {
        CHECK(pthread_join(threads[rc], NULL) == 0);
        table_vcs_cleanup_rc(rc);
        cosim_table_transport_close(servers[rc]);
    }
}

static void run_preflight_failure(const char *route_path,
                                  int rc,
                                  int include_readable,
                                  int readable_supports_read)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, rc, rc);
    peer_context_t peer;
    pthread_t thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_NO_ROUTE_FRAMES;
    CHECK(pthread_create(&thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(rc, route_path) == 0);
    register_handlers(rc, include_readable, readable_supports_read);
    CHECK(table_vcs_init_rc(rc, "127.0.0.1", port - rc, rc,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(rc) == -1);
    CHECK(pthread_join(thread, NULL) == 0);
    table_vcs_cleanup_rc(rc);
    cosim_table_transport_close(server);
}

static void test_preflight_failure_publishes_no_route_frame(
    const char *route_path)
{
    run_preflight_failure(route_path, 0, 0, 0);
    run_preflight_failure(route_path, 0, 1, 0);
    run_preflight_failure(route_path, 2, 1, 1);
}

static void run_invalid_wire_case(const char *route_path, peer_kind_t kind)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    pthread_t thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = kind;
    peer.rc = 0;
    peer.seed = 0x41;
    CHECK(pthread_create(&thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(0) == 0);
    CHECK(poll_until_nonidle(0) == -1);
    CHECK(table_vcs_get_request_kind_rc(0) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    table_vcs_cleanup_rc(0);
    cosim_table_transport_close(server);
}

static void test_rejects_invalid_request_wire(const char *route_path)
{
    const peer_kind_t cases[] = {
        PEER_BAD_FRAGMENT_SEQUENCE,
        PEER_BAD_TRANSACTION,
        PEER_BAD_TYPE,
        PEER_BAD_LENGTH,
        PEER_BAD_ROUTE_ID,
        PEER_BAD_TARGET_RC,
    };
    size_t i;

    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run_invalid_wire_case(route_path, cases[i]);
}

static void *poll_main(void *opaque)
{
    poll_context_t *poll = opaque;

    do {
        poll->result = table_vcs_poll_request_rc(poll->rc);
    } while (poll->result == 0);
    return NULL;
}

static int poll_until_nonidle(int rc)
{
    int attempt;
    int result;

    for (attempt = 0; attempt < 400; attempt++) {
        result = table_vcs_poll_request_rc(rc);
        if (result != 0)
            return result;
    }
    return 0;
}

static void test_fragment_wait_is_bounded_and_resumable(
    const char *route_path)
{
    const uint8_t seed = 0x6d;
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    pthread_t peer_thread;

    CHECK(server != NULL);
    delayed_peer_reset();
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_DELAYED_WRITE;
    peer.rc = 0;
    peer.seed = seed;
    CHECK(pthread_create(&peer_thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(0) == 0);
    delayed_peer_wait_until_paused();
    CHECK(table_vcs_poll_request_rc(0) == 0);
    CHECK(table_vcs_poll_request_rc(0) == 0);
    CHECK(table_vcs_get_request_kind_rc(0) == TABLE_VCS_REQUEST_NONE);
    delayed_peer_release();
    CHECK(poll_until_nonidle(0) == 1);
    CHECK(table_vcs_get_request_kind_rc(0) == TABLE_VCS_REQUEST_WRITE);
    CHECK(table_vcs_get_request_payload_u64_rc(0, 0) ==
          payload_word(seed, 0));
    CHECK(table_vcs_complete_rc(0, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                2, 0, 0) == 0);
    CHECK(pthread_join(peer_thread, NULL) == 0);
    table_vcs_cleanup_rc(0);
    cosim_table_transport_close(server);
}

static void test_cleanup_interrupts_blocked_poll(const char *route_path)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    poll_context_t poll_context;
    pthread_t peer_thread;
    pthread_t poll_thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_WAIT_FOR_CLEANUP;
    peer.rc = 0;
    peer.seed = 0x52;
    CHECK(pthread_create(&peer_thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(0) == 0);

    memset(&poll_context, 0, sizeof(poll_context));
    hook_enable(0, 0);
    CHECK(pthread_create(&poll_thread, NULL, poll_main, &poll_context) == 0);
    hook_wait(TABLE_VCS_TEST_HOOK_WRITE_WAITING_DATA);
    table_vcs_cleanup_rc(0);
    CHECK(pthread_join(poll_thread, NULL) == 0);
    CHECK(poll_context.result == -1);
    CHECK(pthread_join(peer_thread, NULL) == 0);
    hook_disable();
    cosim_table_transport_close(server);
}

static void test_idle_poll_is_bounded_and_recoverable(const char *route_path)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    pthread_t peer_thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.kind = PEER_IDLE_THEN_CLOSE;
    peer.rc = 0;
    CHECK(pthread_create(&peer_thread, NULL, peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    register_handlers(0, 1, 1);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(0) == 0);
    CHECK(table_vcs_poll_request_rc(0) == 0);
    CHECK(table_vcs_get_request_kind_rc(0) == TABLE_VCS_REQUEST_NONE);
    table_vcs_interrupt_rc(0);
    table_vcs_cleanup_rc(0);
    CHECK(pthread_join(peer_thread, NULL) == 0);
    cosim_table_transport_close(server);
}

static void *partial_peer_main(void *opaque)
{
    peer_context_t *peer = opaque;
    const uint64_t transaction_id = UINT64_C(0x778899);
    cosim_table_frame_hdr_t frame;
    cosim_table_route_begin_t route_begin;
    cosim_table_route_entry_t route;
    cosim_table_route_end_t route_end;
    cosim_table_write_begin_t write_begin;
    cosim_table_write_end_t write_end;
    cosim_table_completion_t completion;
    uint64_t route_transaction;

    memset(&route_begin, 0, sizeof(route_begin));
    CHECK(cosim_table_recv(peer->transport, &frame, &route_begin,
                           sizeof(route_begin), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    CHECK(cosim_table_le16_to_cpu(frame.type) == COSIM_TABLE_MSG_ROUTE_BEGIN);
    CHECK(cosim_table_le32_to_cpu(route_begin.entry_count) == 1);
    route_transaction = cosim_table_le64_to_cpu(frame.transaction_id);

    memset(&route, 0, sizeof(route));
    CHECK(cosim_table_recv(peer->transport, &frame, &route, sizeof(route),
                           NULL, 0, TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_ROUTE_ENTRY, route_transaction);
    CHECK(cosim_table_le32_to_cpu(route.route_id) == 0);
    CHECK(cosim_table_le32_to_cpu(route.entry_bytes) == 10);
    CHECK(strcmp((const char *)route.handler_name, "partial") == 0);

    memset(&route_end, 0, sizeof(route_end));
    CHECK(cosim_table_recv(peer->transport, &frame, &route_end,
                           sizeof(route_end), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_ROUTE_END, route_transaction);
    CHECK(route_end.generation == route_begin.generation);

    memset(&write_begin, 0, sizeof(write_begin));
    cosim_table_target_set_identity(&write_begin.target, 0, 0, 0, 0x18, 3);
    write_begin.target.target_type = COSIM_TABLE_TARGET_PF;
    write_begin.target.bar_index = 0;
    write_begin.route_id = cosim_table_cpu_to_le32(0);
    write_begin.entry_index = cosim_table_cpu_to_le32(7);
    write_begin.bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x8000));
    write_begin.payload_bytes = cosim_table_cpu_to_le32(10);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(write_begin), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &write_begin, NULL,
                           TEST_TIMEOUT_MS) == 0);
    send_fragment(peer->transport, transaction_id, 0, 10, 10, peer->seed);
    memset(&write_end, 0, sizeof(write_end));
    write_end.payload_bytes = cosim_table_cpu_to_le32(10);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_END, sizeof(write_end), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &write_end, NULL,
                           TEST_TIMEOUT_MS) == 0);

    memset(&completion, 0, sizeof(completion));
    CHECK(cosim_table_recv(peer->transport, &frame, &completion,
                           sizeof(completion), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_COMPLETION, transaction_id);
    CHECK(cosim_table_le32_to_cpu(completion.status) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(cosim_table_le32_to_cpu(completion.failed_index) == UINT32_MAX);
    CHECK(cosim_table_le32_to_cpu(completion.committed_count) == 1);
    return NULL;
}

static void test_partial_payload_word_is_zero_padded(void)
{
    const uint8_t seed = 0x6b;
    char route_path[64];
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    pthread_t thread;
    uint64_t final_word;

    make_partial_route_file(route_path);
    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.seed = seed;
    CHECK(pthread_create(&thread, NULL, partial_peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    CHECK(table_vcs_register_handler_rc(0, "partial", 0) == 0);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(0) == 0);
    allocation_enable(0);
    CHECK(poll_until_nonidle(0) == 1);
    allocation_check(1, 10);
    allocation_disable();
    CHECK(table_vcs_get_request_payload_bytes_rc(0) == 10);
    CHECK(table_vcs_get_request_payload_u64_rc(0, 0) ==
          payload_word(seed, 0));
    final_word = payload_byte(seed, 8) |
                 ((uint64_t)payload_byte(seed, 9) << 8);
    CHECK(table_vcs_get_request_payload_u64_rc(0, 1) == final_word);
    CHECK(table_vcs_get_request_payload_u64_rc(0, 2) == 0);
    CHECK(table_vcs_complete_rc(0, COSIM_TABLE_ST_SUCCESS, UINT32_MAX,
                                1, 0, 0) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    table_vcs_cleanup_rc(0);
    cosim_table_transport_close(server);
    CHECK(unlink(route_path) == 0);
}

static void *write_limit_peer_main(void *opaque)
{
    peer_context_t *peer = opaque;
    const uint64_t transaction_id = UINT64_C(0x990011);
    cosim_table_frame_hdr_t frame;
    cosim_table_route_begin_t route_begin;
    cosim_table_route_entry_t route;
    cosim_table_route_end_t route_end;
    cosim_table_write_begin_t write_begin;
    unsigned char header[sizeof(cosim_table_route_entry_t)];
    unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];
    uint64_t route_transaction;

    memset(&route_begin, 0, sizeof(route_begin));
    CHECK(cosim_table_recv(peer->transport, &frame, &route_begin,
                           sizeof(route_begin), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    CHECK(cosim_table_le16_to_cpu(frame.type) == COSIM_TABLE_MSG_ROUTE_BEGIN);
    CHECK(cosim_table_le32_to_cpu(route_begin.entry_count) == 1);
    route_transaction = cosim_table_le64_to_cpu(frame.transaction_id);

    memset(&route, 0, sizeof(route));
    CHECK(cosim_table_recv(peer->transport, &frame, &route, sizeof(route),
                           NULL, 0, TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_ROUTE_ENTRY, route_transaction);
    CHECK(cosim_table_le32_to_cpu(route.route_id) == 0);
    CHECK(cosim_table_le32_to_cpu(route.entry_bytes) == 1);

    memset(&route_end, 0, sizeof(route_end));
    CHECK(cosim_table_recv(peer->transport, &frame, &route_end,
                           sizeof(route_end), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_ROUTE_END, route_transaction);

    memset(&write_begin, 0, sizeof(write_begin));
    cosim_table_target_set_identity(&write_begin.target, 0, 0, 0, 0x18, 9);
    write_begin.target.target_type = COSIM_TABLE_TARGET_PF;
    write_begin.target.bar_index = 0;
    write_begin.route_id = cosim_table_cpu_to_le32(0);
    write_begin.entry_index = cosim_table_cpu_to_le32(0);
    write_begin.bar_offset = cosim_table_cpu_to_le64(0);
    write_begin.payload_bytes =
        cosim_table_cpu_to_le32(peer->request_payload_bytes);
    frame = make_frame(COSIM_TABLE_MSG_WRITE_BEGIN, sizeof(write_begin), 0,
                       transaction_id);
    CHECK(cosim_table_send(peer->transport, &frame, &write_begin, NULL,
                           TEST_TIMEOUT_MS) == 0);
    CHECK(cosim_table_recv(peer->transport, &frame, header, sizeof(header),
                           payload, sizeof(payload), -1) == -1);
    return NULL;
}

static void run_write_size_case(const char *route_path,
                                uint32_t payload_bytes,
                                unsigned int expected_alloc_calls)
{
    uint16_t port = reserve_available_port();
    cosim_table_transport_t *server = create_server(port, 0, 0);
    peer_context_t peer;
    pthread_t thread;

    CHECK(server != NULL);
    memset(&peer, 0, sizeof(peer));
    peer.transport = server;
    peer.request_payload_bytes = payload_bytes;
    CHECK(pthread_create(&thread, NULL, write_limit_peer_main, &peer) == 0);
    CHECK(table_vcs_load_routes_rc(0, route_path) == 0);
    CHECK(table_vcs_register_handler_rc(0, "limit", 0) == 0);
    CHECK(table_vcs_init_rc(0, "127.0.0.1", port, 0,
                            TEST_TIMEOUT_MS) == 0);
    CHECK(table_vcs_activate_routes_rc(0) == 0);
    allocation_enable(1);
    CHECK(poll_until_nonidle(0) == -1);
    allocation_check(expected_alloc_calls,
                     expected_alloc_calls != 0 ? payload_bytes : 0);
    allocation_disable();
    CHECK(pthread_join(thread, NULL) == 0);
    table_vcs_cleanup_rc(0);
    cosim_table_transport_close(server);
}

static void test_write_size_limit_precedes_allocation(void)
{
    char route_path[64];

    make_write_limit_route_file(route_path);
    run_write_size_case(route_path, 0, 0);
    run_write_size_case(route_path, COSIM_TABLE_MAX_WRITE_BYTES, 1);
    run_write_size_case(route_path, COSIM_TABLE_MAX_WRITE_BYTES + 1u, 0);
    CHECK(unlink(route_path) == 0);
}

static void test_strict_rc_validation(void)
{
    CHECK(table_vcs_load_routes_rc(-1, TABLE_ROUTE_FIXTURE) == -1);
    CHECK(table_vcs_load_routes_rc(4, TABLE_ROUTE_FIXTURE) == -1);
    CHECK(table_vcs_register_handler_rc(-1, "x", 0) == -1);
    CHECK(table_vcs_register_handler_rc(4, "x", 0) == -1);
    CHECK(table_vcs_init_rc(-1, "127.0.0.1", 10100, 0, 10) == -1);
    CHECK(table_vcs_init_rc(4, "127.0.0.1", 10100, 0, 10) == -1);
    CHECK(table_vcs_activate_routes_rc(-1) == -1);
    CHECK(table_vcs_activate_routes_rc(4) == -1);
    CHECK(table_vcs_poll_request_rc(-1) == -1);
    CHECK(table_vcs_poll_request_rc(4) == -1);
    CHECK(table_vcs_get_request_handler_rc(-1) == NULL);
    CHECK(table_vcs_get_request_handler_rc(4) == NULL);
    CHECK(table_vcs_complete_rc(-1, 0, 0, 0, 0, 0) == -1);
    CHECK(table_vcs_complete_rc(4, 0, 0, 0, 0, 0) == -1);
    table_vcs_interrupt_rc(-1);
    table_vcs_interrupt_rc(4);
    table_vcs_cleanup_rc(-1);
    table_vcs_cleanup_rc(4);
}

static void test_shared_resource_limits(void)
{
    CHECK(COSIM_TABLE_MAX_ROUTES == 65536u);
    CHECK(cosim_table_route_count_supported(1));
    CHECK(cosim_table_route_count_supported(COSIM_TABLE_MAX_ROUTES));
    CHECK(!cosim_table_route_count_supported(0));
    CHECK(!cosim_table_route_count_supported(
        (uint64_t)COSIM_TABLE_MAX_ROUTES + 1));

    CHECK(COSIM_TABLE_MAX_WRITE_BYTES == 64u * 1024u * 1024u);
    CHECK(cosim_table_write_bytes_supported(1));
    CHECK(cosim_table_write_bytes_supported(COSIM_TABLE_MAX_WRITE_BYTES));
    CHECK(!cosim_table_write_bytes_supported(0));
    CHECK(!cosim_table_write_bytes_supported(
        (uint64_t)COSIM_TABLE_MAX_WRITE_BYTES + 1));
}

int main(void)
{
    char route_path[64];

    make_shared_route_file(route_path);
    test_shared_resource_limits();
    test_strict_rc_validation();
    test_per_rc_activation_reassembly_and_completion(route_path);
    test_preflight_uses_bounded_subset_allocator(route_path);
    test_concurrent_activation_publishes_once(route_path);
    test_cleanup_wins_after_activation_end(route_path);
    test_preflight_failure_publishes_no_route_frame(route_path);
    test_rejects_invalid_request_wire(route_path);
    test_idle_poll_is_bounded_and_recoverable(route_path);
    test_fragment_wait_is_bounded_and_resumable(route_path);
    test_cleanup_interrupts_blocked_poll(route_path);
    test_partial_payload_word_is_zero_padded();
    test_write_size_limit_precedes_allocation();
    CHECK(unlink(route_path) == 0);
    printf("test_table_vcs_core: PASS\n");
    return 0;
}
