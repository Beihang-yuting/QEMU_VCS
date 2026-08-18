#define _GNU_SOURCE
#include "table_client.h"

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__,         \
                    #condition);                                               \
            abort();                                                           \
        }                                                                      \
    } while (0)

enum {
    TEST_INSTANCE_ID = 6,
    TEST_RC_ID = 4,
    TEST_TIMEOUT_MS = 3000,
    TEST_ENTRY_BYTES = 50000,
    TEST_ENTRY_COUNT = 3,
    TEST_PAYLOAD_BYTES = TEST_ENTRY_BYTES * TEST_ENTRY_COUNT,
};

static uint64_t monotonic_ms(void)
{
    struct timespec now;

    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

static void wait_child_ok(pid_t child, int timeout_ms)
{
    uint64_t deadline = monotonic_ms() + (uint64_t)timeout_ms;
    int status = 0;

    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);

        if (result == child)
            break;
        CHECK(result == 0 || (result < 0 && errno == EINTR));
        if (monotonic_ms() >= deadline) {
            (void)kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR)
                ;
            CHECK(0 && "mock VCS peer exceeded its deadline");
        }
        (void)poll(NULL, 0, 1);
    }
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);
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
    CHECK(ntohs(address.sin_port) > TEST_INSTANCE_ID);
    return ntohs(address.sin_port);
}

static cosim_table_frame_hdr_t frame_header(uint16_t type,
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

static uint8_t payload_byte(size_t offset)
{
    return (uint8_t)((offset * 19u + 11u) & 0xffu);
}

static cosim_table_route_entry_t make_route(uint32_t generation)
{
    cosim_table_route_entry_t route;

    memset(&route, 0, sizeof(route));
    route.route_id = cosim_table_cpu_to_le32(23);
    route.target.rc_id = cosim_table_cpu_to_le16(TEST_RC_ID);
    route.target.device_instance = cosim_table_cpu_to_le16(0);
    route.target.target_type = COSIM_TABLE_TARGET_PF;
    route.target.pf_index = 0;
    route.target.bar_index = 0;
    (void)generation;
    route.operation_mask = cosim_table_cpu_to_le32(
        COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD);
    route.start_offset = cosim_table_cpu_to_le64(UINT64_C(0x1000));
    route.end_offset = cosim_table_cpu_to_le64(
        UINT64_C(0x1000) + TEST_ENTRY_BYTES * 4u);
    route.entry_bytes = cosim_table_cpu_to_le32(TEST_ENTRY_BYTES);
    route.stride_bytes = cosim_table_cpu_to_le32(TEST_ENTRY_BYTES);
    route.index_base = cosim_table_cpu_to_le32(40);
    memcpy(route.handler_name, "mock_table", sizeof("mock_table"));
    return route;
}

typedef struct {
    cosim_table_client_t *client;
    cosim_table_read_dword_t request;
    cosim_table_completion_t completion;
    cosim_table_status_t status;
} read_thread_args_t;

static void *read_thread_main(void *opaque)
{
    read_thread_args_t *args = opaque;

    args->status = cosim_table_client_read_dword(
        args->client, &args->request, &args->completion, 1000);
    return NULL;
}

static void send_route_generation(cosim_table_transport_t *transport,
                                  uint32_t begin_generation,
                                  uint32_t end_generation,
                                  uint64_t transaction_id)
{
    cosim_table_route_begin_t begin;
    cosim_table_route_entry_t route = make_route(begin_generation);
    cosim_table_route_end_t end;
    cosim_table_frame_hdr_t frame;

    memset(&begin, 0, sizeof(begin));
    begin.generation = cosim_table_cpu_to_le32(begin_generation);
    begin.entry_count = cosim_table_cpu_to_le32(1);
    frame = frame_header(COSIM_TABLE_MSG_ROUTE_BEGIN, sizeof(begin), 0,
                         transaction_id);
    CHECK(cosim_table_send(transport, &frame, &begin, NULL,
                           TEST_TIMEOUT_MS) == 0);

    frame = frame_header(COSIM_TABLE_MSG_ROUTE_ENTRY, sizeof(route), 0,
                         transaction_id);
    CHECK(cosim_table_send(transport, &frame, &route, NULL,
                           TEST_TIMEOUT_MS) == 0);

    memset(&end, 0, sizeof(end));
    end.generation = cosim_table_cpu_to_le32(end_generation);
    frame = frame_header(COSIM_TABLE_MSG_ROUTE_END, sizeof(end), 0,
                         transaction_id);
    CHECK(cosim_table_send(transport, &frame, &end, NULL,
                           TEST_TIMEOUT_MS) == 0);
}

static void mock_vcs_main(uint16_t port)
{
    const uint64_t write_transaction = 1;
    cosim_table_transport_cfg_t cfg;
    cosim_table_transport_t *transport;
    cosim_table_frame_hdr_t frame;
    cosim_table_write_begin_t write_begin;
    cosim_table_write_data_t write_data;
    cosim_table_write_end_t write_end;
    cosim_table_read_dword_t read_request;
    cosim_table_completion_t completion;
    uint8_t payload[COSIM_TABLE_FRAME_DATA_BYTES];
    size_t received = 0;
    int result;

    memset(&cfg, 0, sizeof(cfg));
    cfg.remote_host = "127.0.0.1";
    cfg.table_port_base = port - TEST_INSTANCE_ID;
    cfg.instance_id = TEST_INSTANCE_ID;
    cfg.rc_id = TEST_RC_ID;
    cfg.is_server = 0;
    cfg.connect_timeout_ms = TEST_TIMEOUT_MS;
    transport = cosim_table_transport_create(&cfg);
    CHECK(transport != NULL);

    send_route_generation(transport, 0x1234u, 0x1234u, 10);
    send_route_generation(transport, 0x5678u, 0x5679u, 20);

    memset(&write_begin, 0, sizeof(write_begin));
    CHECK(cosim_table_recv(transport, &frame, &write_begin,
                           sizeof(write_begin), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_WRITE_BEGIN, write_transaction);
    CHECK(cosim_table_le32_to_cpu(write_begin.route_id) == 23);
    CHECK(cosim_table_le32_to_cpu(write_begin.entry_index) == 41);
    CHECK(cosim_table_le32_to_cpu(write_begin.payload_bytes) ==
          TEST_PAYLOAD_BYTES);

    while (received < TEST_PAYLOAD_BYTES) {
        size_t i;
        uint32_t bytes;

        memset(&write_data, 0, sizeof(write_data));
        CHECK(cosim_table_recv(transport, &frame, &write_data,
                               sizeof(write_data), payload, sizeof(payload),
                               TEST_TIMEOUT_MS) == 0);
        check_frame(&frame, COSIM_TABLE_MSG_WRITE_DATA, write_transaction);
        bytes = cosim_table_le32_to_cpu(write_data.data_bytes);
        CHECK(bytes > 0 && bytes <= COSIM_TABLE_FRAME_DATA_BYTES);
        CHECK(cosim_table_le64_to_cpu(write_data.data_offset) == received);
        CHECK(cosim_table_le32_to_cpu(frame.payload_bytes) == bytes);
        for (i = 0; i < bytes; i++)
            CHECK(payload[i] == payload_byte(received + i));
        received += bytes;
    }
    CHECK(received == TEST_PAYLOAD_BYTES);
    memset(&write_end, 0, sizeof(write_end));
    CHECK(cosim_table_recv(transport, &frame, &write_end, sizeof(write_end),
                           NULL, 0, TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_WRITE_END, write_transaction);
    CHECK(cosim_table_le32_to_cpu(write_end.payload_bytes) ==
          TEST_PAYLOAD_BYTES);

    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    completion.failed_index = cosim_table_cpu_to_le32(UINT32_MAX);
    completion.committed_count = cosim_table_cpu_to_le32(TEST_ENTRY_COUNT);
    frame = frame_header(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0,
                         write_transaction);
    CHECK(cosim_table_send(transport, &frame, &completion, NULL,
                           TEST_TIMEOUT_MS) == 0);

    memset(&read_request, 0, sizeof(read_request));
    CHECK(cosim_table_recv(transport, &frame, &read_request,
                           sizeof(read_request), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_READ_DWORD, 2);
    CHECK(cosim_table_le32_to_cpu(read_request.route_id) == 23);
    CHECK(cosim_table_le64_to_cpu(read_request.bar_offset) ==
          UINT64_C(0x1004));
    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    completion.failed_index = cosim_table_cpu_to_le32(UINT32_MAX);
    completion.returned_dword = cosim_table_cpu_to_le32(UINT32_C(0x78563412));
    frame = frame_header(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0, 2);
    CHECK(cosim_table_send(transport, &frame, &completion, NULL,
                           TEST_TIMEOUT_MS) == 0);

    /* Hold one serialized request so a second caller can test its deadline. */
    CHECK(cosim_table_recv(transport, &frame, &read_request,
                           sizeof(read_request), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_READ_DWORD, 3);
    (void)poll(NULL, 0, 200);
    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    completion.failed_index = cosim_table_cpu_to_le32(UINT32_MAX);
    completion.returned_dword = cosim_table_cpu_to_le32(UINT32_C(0x01020304));
    frame = frame_header(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0, 3);
    CHECK(cosim_table_send(transport, &frame, &completion, NULL,
                           TEST_TIMEOUT_MS) == 0);

    /* A semantically invalid SUCCESS must become a hard PROTOCOL result. */
    CHECK(cosim_table_recv(transport, &frame, &read_request,
                           sizeof(read_request), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_READ_DWORD, 4);
    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    completion.failed_index = cosim_table_cpu_to_le32(UINT32_MAX);
    completion.committed_count = cosim_table_cpu_to_le32(1);
    frame = frame_header(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0, 4);
    CHECK(cosim_table_send(transport, &frame, &completion, NULL,
                           TEST_TIMEOUT_MS) == 0);

    /* Consume one more request but deliberately publish no frame. */
    result = cosim_table_recv(transport, &frame, &read_request,
                              sizeof(read_request), NULL, 0,
                              TEST_TIMEOUT_MS);
    CHECK(result == 0);
    check_frame(&frame, COSIM_TABLE_MSG_READ_DWORD, 5);
    (void)poll(NULL, 0, 300);
    cosim_table_transport_close(transport);
}

#define RAW_HANDSHAKE_MAGIC UINT32_C(0x48544243)
#define RAW_HANDSHAKE_VERSION 1u

typedef struct __attribute__((packed)) {
    cosim_u32 magic;
    cosim_u16 version;
    cosim_u16 rc_id;
    cosim_u32 instance_id;
    cosim_u32 reserved;
} raw_handshake_t;

typedef enum {
    WIRE_WRONG_TRANSACTION,
    WIRE_WRONG_TYPE,
    WIRE_WRONG_HEADER_LENGTH,
    WIRE_WRONG_PAYLOAD_LENGTH,
    WIRE_UNKNOWN_STATUS,
    WIRE_REMOTE_SLOT_BUSY,
    WIRE_SUCCESS_BAD_COUNT,
    WIRE_EXEC_VALID_ONE_COMMIT,
    WIRE_EXEC_BAD_COMMITTED,
    WIRE_EXEC_BAD_FAILED_INDEX,
} wire_case_t;

typedef struct {
    wire_case_t kind;
    cosim_table_status_t expected;
    int is_write;
} wire_case_spec_t;

static void raw_send_exact(int fd, const void *buffer, size_t bytes)
{
    const uint8_t *cursor = buffer;
    size_t sent = 0;

    while (sent < bytes) {
        ssize_t result = send(fd, cursor + sent, bytes - sent, MSG_NOSIGNAL);

        if (result < 0 && errno == EINTR)
            continue;
        CHECK(result > 0);
        sent += (size_t)result;
    }
}

static void raw_recv_exact(int fd, void *buffer, size_t bytes)
{
    uint8_t *cursor = buffer;
    size_t received = 0;

    while (received < bytes) {
        ssize_t result = recv(fd, cursor + received, bytes - received, 0);

        if (result < 0 && errno == EINTR)
            continue;
        CHECK(result > 0);
        received += (size_t)result;
    }
}

static int raw_connect(uint16_t port)
{
    struct sockaddr_in address;
    uint64_t deadline = monotonic_ms() + TEST_TIMEOUT_MS;

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    while (monotonic_ms() < deadline) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);

        CHECK(fd >= 0);
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0)
            return fd;
        CHECK(errno == ECONNREFUSED || errno == EINTR);
        CHECK(close(fd) == 0);
        (void)poll(NULL, 0, 5);
    }
    CHECK(0 && "raw peer connect exceeded deadline");
    return -1;
}

static void raw_handshake(int fd)
{
    raw_handshake_t outbound;
    raw_handshake_t inbound;

    memset(&outbound, 0, sizeof(outbound));
    outbound.magic = cosim_table_cpu_to_le32(RAW_HANDSHAKE_MAGIC);
    outbound.version = cosim_table_cpu_to_le16(RAW_HANDSHAKE_VERSION);
    outbound.rc_id = cosim_table_cpu_to_le16(TEST_RC_ID);
    outbound.instance_id = cosim_table_cpu_to_le32(TEST_INSTANCE_ID);
    raw_send_exact(fd, &outbound, sizeof(outbound));
    raw_recv_exact(fd, &inbound, sizeof(inbound));
    CHECK(memcmp(&outbound, &inbound, sizeof(outbound)) == 0);
}

static void raw_send_frame(int fd, const cosim_table_frame_hdr_t *frame,
                           const void *header, size_t header_bytes,
                           const void *payload, size_t payload_bytes)
{
    raw_send_exact(fd, frame, sizeof(*frame));
    if (header_bytes != 0)
        raw_send_exact(fd, header, header_bytes);
    if (payload_bytes != 0)
        raw_send_exact(fd, payload, payload_bytes);
}

static void raw_publish_small_route(int fd)
{
    const uint64_t transaction_id = 99;
    cosim_table_route_begin_t begin;
    cosim_table_route_entry_t route;
    cosim_table_route_end_t end;
    cosim_table_frame_hdr_t frame;

    memset(&begin, 0, sizeof(begin));
    begin.generation = cosim_table_cpu_to_le32(1);
    begin.entry_count = cosim_table_cpu_to_le32(1);
    frame = frame_header(COSIM_TABLE_MSG_ROUTE_BEGIN, sizeof(begin), 0,
                         transaction_id);
    raw_send_frame(fd, &frame, &begin, sizeof(begin), NULL, 0);

    memset(&route, 0, sizeof(route));
    route.route_id = cosim_table_cpu_to_le32(7);
    route.target.rc_id = cosim_table_cpu_to_le16(TEST_RC_ID);
    route.target.target_type = COSIM_TABLE_TARGET_PF;
    route.target.pf_index = 0;
    route.target.bar_index = 0;
    route.operation_mask = cosim_table_cpu_to_le32(
        COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD);
    route.start_offset = cosim_table_cpu_to_le64(UINT64_C(0x1000));
    route.end_offset = cosim_table_cpu_to_le64(UINT64_C(0x1040));
    route.entry_bytes = cosim_table_cpu_to_le32(16);
    route.stride_bytes = cosim_table_cpu_to_le32(16);
    route.index_base = cosim_table_cpu_to_le32(10);
    memcpy(route.handler_name, "wire_case", sizeof("wire_case"));
    frame = frame_header(COSIM_TABLE_MSG_ROUTE_ENTRY, sizeof(route), 0,
                         transaction_id);
    raw_send_frame(fd, &frame, &route, sizeof(route), NULL, 0);

    memset(&end, 0, sizeof(end));
    end.generation = begin.generation;
    frame = frame_header(COSIM_TABLE_MSG_ROUTE_END, sizeof(end), 0,
                         transaction_id);
    raw_send_frame(fd, &frame, &end, sizeof(end), NULL, 0);
}

static void raw_drain_request(int fd, int is_write)
{
    cosim_table_frame_hdr_t frame;
    uint8_t header[sizeof(cosim_table_write_begin_t)];
    uint8_t payload[COSIM_TABLE_FRAME_DATA_BYTES];
    uint16_t type;
    uint32_t header_bytes;
    uint32_t payload_bytes;

    do {
        raw_recv_exact(fd, &frame, sizeof(frame));
        header_bytes = cosim_table_le32_to_cpu(frame.header_bytes);
        payload_bytes = cosim_table_le32_to_cpu(frame.payload_bytes);
        CHECK(header_bytes <= sizeof(header));
        CHECK(payload_bytes <= sizeof(payload));
        raw_recv_exact(fd, header, header_bytes);
        raw_recv_exact(fd, payload, payload_bytes);
        type = cosim_table_le16_to_cpu(frame.type);
        if (!is_write)
            CHECK(type == COSIM_TABLE_MSG_READ_DWORD);
    } while (is_write && type != COSIM_TABLE_MSG_WRITE_END);
}

static void raw_completion_peer(uint16_t port, wire_case_t kind,
                                int is_write)
{
    cosim_table_completion_t completion;
    cosim_table_route_end_t wrong_type;
    cosim_table_frame_hdr_t frame;
    int fd = raw_connect(port);

    raw_handshake(fd);
    raw_publish_small_route(fd);
    raw_drain_request(fd, is_write);

    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    completion.failed_index = cosim_table_cpu_to_le32(UINT32_MAX);
    completion.committed_count = cosim_table_cpu_to_le32(is_write ? 3 : 0);
    if (!is_write)
        completion.returned_dword = cosim_table_cpu_to_le32(0x12345678u);

    if (kind == WIRE_WRONG_TYPE) {
        memset(&wrong_type, 0, sizeof(wrong_type));
        wrong_type.generation = cosim_table_cpu_to_le32(1);
        frame = frame_header(COSIM_TABLE_MSG_ROUTE_END, sizeof(wrong_type),
                             0, 1);
        raw_send_frame(fd, &frame, &wrong_type, sizeof(wrong_type), NULL, 0);
    } else if (kind == WIRE_WRONG_HEADER_LENGTH) {
        frame = frame_header(COSIM_TABLE_MSG_COMPLETION,
                             sizeof(completion) - 1, 0, 1);
        raw_send_frame(fd, &frame, NULL, 0, NULL, 0);
    } else if (kind == WIRE_WRONG_PAYLOAD_LENGTH) {
        frame = frame_header(COSIM_TABLE_MSG_COMPLETION,
                             sizeof(completion), 1, 1);
        raw_send_frame(fd, &frame, NULL, 0, NULL, 0);
    } else {
        uint64_t transaction_id = kind == WIRE_WRONG_TRANSACTION ? 2 : 1;

        if (kind == WIRE_UNKNOWN_STATUS)
            completion.status = cosim_table_cpu_to_le32(99);
        else if (kind == WIRE_REMOTE_SLOT_BUSY)
            completion.status =
                cosim_table_cpu_to_le32(COSIM_TABLE_ST_SLOT_BUSY);
        else if (kind == WIRE_SUCCESS_BAD_COUNT)
            completion.committed_count = cosim_table_cpu_to_le32(2);
        else if (kind == WIRE_EXEC_VALID_ONE_COMMIT) {
            completion.status =
                cosim_table_cpu_to_le32(COSIM_TABLE_ST_EXEC_ERROR);
            completion.committed_count = cosim_table_cpu_to_le32(1);
            completion.failed_index = cosim_table_cpu_to_le32(11);
            completion.handler_error = cosim_table_cpu_to_le32(5);
        } else if (kind == WIRE_EXEC_BAD_COMMITTED) {
            completion.status =
                cosim_table_cpu_to_le32(COSIM_TABLE_ST_EXEC_ERROR);
            completion.committed_count = cosim_table_cpu_to_le32(3);
            completion.failed_index = cosim_table_cpu_to_le32(13);
        } else if (kind == WIRE_EXEC_BAD_FAILED_INDEX) {
            completion.status =
                cosim_table_cpu_to_le32(COSIM_TABLE_ST_EXEC_ERROR);
            completion.committed_count = cosim_table_cpu_to_le32(1);
            completion.failed_index = cosim_table_cpu_to_le32(12);
        }
        frame = frame_header(COSIM_TABLE_MSG_COMPLETION, sizeof(completion),
                             0, transaction_id);
        raw_send_frame(fd, &frame, &completion, sizeof(completion), NULL, 0);
    }
    (void)poll(NULL, 0, 20);
    CHECK(close(fd) == 0);
}

static void run_wire_case(const wire_case_spec_t *spec)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t cfg;
    cosim_table_transport_t *transport;
    cosim_table_client_t *client;
    cosim_table_target_t target;
    cosim_table_completion_t completion;
    cosim_table_status_t status;
    pid_t child;

    memset(&cfg, 0, sizeof(cfg));
    cfg.listen_addr = "127.0.0.1";
    cfg.table_port_base = port - TEST_INSTANCE_ID;
    cfg.instance_id = TEST_INSTANCE_ID;
    cfg.rc_id = TEST_RC_ID;
    cfg.is_server = 1;
    cfg.connect_timeout_ms = TEST_TIMEOUT_MS;
    transport = cosim_table_transport_create(&cfg);
    CHECK(transport != NULL);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        raw_completion_peer(port, spec->kind, spec->is_write);
        _exit(0);
    }

    client = cosim_table_client_create(transport, TEST_RC_ID);
    CHECK(client != NULL);
    CHECK(cosim_table_client_wait_routes(client, TEST_TIMEOUT_MS) == 0);
    memset(&target, 0, sizeof(target));
    target.rc_id = cosim_table_cpu_to_le16(TEST_RC_ID);
    target.target_type = COSIM_TABLE_TARGET_PF;
    target.pf_index = 0;
    target.bar_index = 0;
    if (spec->is_write) {
        cosim_table_write_begin_t request;
        uint8_t payload[48];

        memset(&request, 0, sizeof(request));
        request.target = target;
        request.bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x1000));
        request.payload_bytes = cosim_table_cpu_to_le32(sizeof(payload));
        memset(payload, 0x5a, sizeof(payload));
        status = cosim_table_client_write(client, &request, payload,
                                          &completion, TEST_TIMEOUT_MS);
    } else {
        cosim_table_read_dword_t request;

        memset(&request, 0, sizeof(request));
        request.target = target;
        request.bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x1004));
        status = cosim_table_client_read_dword(client, &request, &completion,
                                               TEST_TIMEOUT_MS);
    }
    if (status != spec->expected) {
        fprintf(stderr, "wire case %d returned %d, expected %d\n",
                (int)spec->kind, (int)status, (int)spec->expected);
    }
    CHECK(status == spec->expected);
    CHECK(completion.status == (cosim_u32)spec->expected);
    if (spec->kind == WIRE_EXEC_VALID_ONE_COMMIT) {
        CHECK(completion.committed_count == 1);
        CHECK(completion.failed_index == 11);
        CHECK(completion.handler_error == 5);
    }
    CHECK(!cosim_table_status_may_frontdoor(status));
    cosim_table_client_destroy(client);
    cosim_table_transport_close(transport);
    wait_child_ok(child, TEST_TIMEOUT_MS);
}

static void test_wire_completion_validation_matrix(void)
{
    static const wire_case_spec_t cases[] = {
        { WIRE_WRONG_TRANSACTION, COSIM_TABLE_ST_PROTOCOL, 0 },
        { WIRE_WRONG_TYPE, COSIM_TABLE_ST_PROTOCOL, 0 },
        { WIRE_WRONG_HEADER_LENGTH, COSIM_TABLE_ST_PROTOCOL, 0 },
        { WIRE_WRONG_PAYLOAD_LENGTH, COSIM_TABLE_ST_PROTOCOL, 0 },
        { WIRE_UNKNOWN_STATUS, COSIM_TABLE_ST_PROTOCOL, 0 },
        { WIRE_REMOTE_SLOT_BUSY, COSIM_TABLE_ST_PROTOCOL, 0 },
        { WIRE_SUCCESS_BAD_COUNT, COSIM_TABLE_ST_PROTOCOL, 1 },
        { WIRE_EXEC_VALID_ONE_COMMIT, COSIM_TABLE_ST_EXEC_ERROR, 1 },
        { WIRE_EXEC_BAD_COMMITTED, COSIM_TABLE_ST_PROTOCOL, 1 },
        { WIRE_EXEC_BAD_FAILED_INDEX, COSIM_TABLE_ST_PROTOCOL, 1 },
    };
    size_t i;

    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run_wire_case(&cases[i]);
}

static void test_semantic_roundtrip(void)
{
    const uint16_t port = reserve_available_port();
    const uint64_t write_offset = UINT64_C(0x1000) + TEST_ENTRY_BYTES;
    cosim_table_transport_cfg_t cfg;
    cosim_table_transport_t *transport;
    cosim_table_client_t *client;
    cosim_table_target_t target;
    cosim_table_write_begin_t write_request;
    cosim_table_read_dword_t read_request;
    cosim_table_completion_t completion;
    const cosim_table_route_entry_t *route;
    uint8_t *payload;
    uint64_t started;
    pid_t child;
    pthread_t read_thread;
    read_thread_args_t thread_args;
    cosim_table_completion_t contended_completion;
    size_t i;

    memset(&cfg, 0, sizeof(cfg));
    cfg.listen_addr = "127.0.0.1";
    cfg.table_port_base = port - TEST_INSTANCE_ID;
    cfg.instance_id = TEST_INSTANCE_ID;
    cfg.rc_id = TEST_RC_ID;
    cfg.is_server = 1;
    cfg.connect_timeout_ms = TEST_TIMEOUT_MS;
    transport = cosim_table_transport_create(&cfg);
    CHECK(transport != NULL);

    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        mock_vcs_main(port);
        _exit(0);
    }

    client = cosim_table_client_create(transport, TEST_RC_ID);
    CHECK(client != NULL);
    CHECK(cosim_table_client_wait_routes(client, TEST_TIMEOUT_MS) == 0);

    memset(&target, 0, sizeof(target));
    target.rc_id = cosim_table_cpu_to_le16(TEST_RC_ID);
    target.device_instance = cosim_table_cpu_to_le16(0);
    target.target_type = COSIM_TABLE_TARGET_PF;
    target.pf_index = 0;
    target.bar_index = 0;
    target.generation = cosim_table_cpu_to_le32(0x1234u);
    route = cosim_table_client_match(client, &target, write_offset,
                                     COSIM_TABLE_OP_WRITE);
    CHECK(route != NULL);
    CHECK(cosim_table_le32_to_cpu(route->route_id) == 23);

    /* A malformed replacement is rejected without destroying the old map. */
    CHECK(cosim_table_client_wait_routes(client, TEST_TIMEOUT_MS) != 0);
    CHECK(cosim_table_client_match(client, &target, write_offset,
                                   COSIM_TABLE_OP_WRITE) == route);

    payload = malloc(TEST_PAYLOAD_BYTES);
    CHECK(payload != NULL);
    for (i = 0; i < TEST_PAYLOAD_BYTES; i++)
        payload[i] = payload_byte(i);
    memset(&write_request, 0, sizeof(write_request));
    write_request.target = target;
    write_request.route_id = cosim_table_cpu_to_le32(UINT32_MAX);
    write_request.entry_index = cosim_table_cpu_to_le32(UINT32_MAX);
    write_request.bar_offset = cosim_table_cpu_to_le64(write_offset);
    write_request.payload_bytes = cosim_table_cpu_to_le32(TEST_PAYLOAD_BYTES);
    memset(&completion, 0xa5, sizeof(completion));
    CHECK(cosim_table_client_write(client, &write_request, payload,
                                   &completion, TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(completion.status == COSIM_TABLE_ST_SUCCESS);
    CHECK(completion.failed_index == UINT32_MAX);
    CHECK(completion.committed_count == TEST_ENTRY_COUNT);
    free(payload);

    memset(&read_request, 0, sizeof(read_request));
    read_request.target = target;
    read_request.bar_offset = cosim_table_cpu_to_le64(UINT64_C(0x1004));
    read_request.route_id = cosim_table_cpu_to_le32(UINT32_MAX);
    memset(&completion, 0xa5, sizeof(completion));
    CHECK(cosim_table_client_read_dword(client, &read_request, &completion,
                                        TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(completion.status == COSIM_TABLE_ST_SUCCESS);
    CHECK(completion.returned_dword == UINT32_C(0x78563412));

    memset(&thread_args, 0, sizeof(thread_args));
    thread_args.client = client;
    thread_args.request = read_request;
    CHECK(pthread_create(&read_thread, NULL, read_thread_main,
                         &thread_args) == 0);
    (void)poll(NULL, 0, 20);
    started = monotonic_ms();
    CHECK(cosim_table_client_read_dword(client, &read_request,
                                        &contended_completion, 50) ==
          COSIM_TABLE_ST_TIMEOUT);
    CHECK(monotonic_ms() - started < 200);
    CHECK(pthread_join(read_thread, NULL) == 0);
    CHECK(thread_args.status == COSIM_TABLE_ST_SUCCESS);
    CHECK(thread_args.completion.returned_dword == UINT32_C(0x01020304));

    CHECK(cosim_table_client_read_dword(client, &read_request, &completion,
                                        TEST_TIMEOUT_MS) ==
          COSIM_TABLE_ST_PROTOCOL);
    CHECK(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_PROTOCOL));

    started = monotonic_ms();
    CHECK(cosim_table_client_read_dword(client, &read_request, &completion,
                                        100) == COSIM_TABLE_ST_TIMEOUT);
    CHECK(monotonic_ms() - started < 1000);
    CHECK(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_TIMEOUT));

    cosim_table_client_destroy(client);
    cosim_table_transport_close(transport);
    wait_child_ok(child, TEST_TIMEOUT_MS);
}

int main(void)
{
    test_semantic_roundtrip();
    test_wire_completion_validation_matrix();
    puts("table semantic roundtrip: PASS");
    return 0;
}
