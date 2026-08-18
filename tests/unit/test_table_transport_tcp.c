#define _GNU_SOURCE
#include "cosim_table_transport.h"

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
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
    TEST_INSTANCE_ID = 7,
    TEST_RC_ID = 3,
    TEST_PAYLOAD_BYTES = 150000,
    TEST_TIMEOUT_MS = 3000,
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
            CHECK(0 && "child cleanup exceeded its deadline");
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
                        uint16_t type, uint32_t header_bytes,
                        uint32_t payload_bytes, uint64_t transaction_id)
{
    CHECK(cosim_table_le32_to_cpu(frame->magic) == COSIM_TABLE_MAGIC);
    CHECK(cosim_table_le16_to_cpu(frame->version) ==
          COSIM_TABLE_PROTOCOL_VERSION);
    CHECK(cosim_table_le16_to_cpu(frame->type) == type);
    CHECK(cosim_table_le32_to_cpu(frame->header_bytes) == header_bytes);
    CHECK(cosim_table_le32_to_cpu(frame->payload_bytes) == payload_bytes);
    CHECK(cosim_table_le64_to_cpu(frame->transaction_id) == transaction_id);
}

static uint8_t payload_byte(size_t offset)
{
    return (uint8_t)((offset * 29u + 17u) & 0xffu);
}

static void server_main(const cosim_table_transport_cfg_t *cfg, int status_fd)
{
    static const size_t expected_chunks[] = { 65536u, 65536u, 18928u };
    const uint64_t transaction_id = UINT64_C(0x1122334455667788);
    cosim_table_transport_t *transport;
    cosim_table_frame_hdr_t frame;
    cosim_table_hello_t hello;
    cosim_table_write_data_t data_header;
    cosim_table_completion_t completion;
    uint8_t payload[COSIM_TABLE_FRAME_DATA_BYTES];
    size_t total = 0;
    size_t chunk_index;
    int result;

    char marker = 'R';

    transport = cosim_table_transport_create(cfg);
    CHECK(transport != NULL);

    memset(&hello, 0, sizeof(hello));
    result = cosim_table_recv(transport, &frame, &hello, sizeof(hello),
                              NULL, 0, TEST_TIMEOUT_MS);
    CHECK(result == 0);
    check_frame(&frame, COSIM_TABLE_MSG_HELLO, sizeof(hello), 0, 1);
    CHECK(cosim_table_le32_to_cpu(hello.protocol_version) ==
          COSIM_TABLE_PROTOCOL_VERSION);
    CHECK(cosim_table_le32_to_cpu(hello.max_frame_data_bytes) ==
          COSIM_TABLE_FRAME_DATA_BYTES);

    for (chunk_index = 0;
         chunk_index < sizeof(expected_chunks) / sizeof(expected_chunks[0]);
         chunk_index++) {
        size_t byte_index;

        memset(&data_header, 0, sizeof(data_header));
        result = cosim_table_recv(transport, &frame, &data_header,
                                  sizeof(data_header), payload,
                                  sizeof(payload), TEST_TIMEOUT_MS);
        CHECK(result == 0);
        check_frame(&frame, COSIM_TABLE_MSG_WRITE_DATA, sizeof(data_header),
                    expected_chunks[chunk_index], transaction_id);
        CHECK(cosim_table_le64_to_cpu(data_header.data_offset) == total);
        CHECK(cosim_table_le32_to_cpu(data_header.data_bytes) ==
              expected_chunks[chunk_index]);
        for (byte_index = 0; byte_index < expected_chunks[chunk_index];
             byte_index++)
            CHECK(payload[byte_index] == payload_byte(total + byte_index));
        total += expected_chunks[chunk_index];
    }
    CHECK(total == TEST_PAYLOAD_BYTES);

    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    completion.committed_count = cosim_table_cpu_to_le32(1);
    frame = make_frame(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0,
                       transaction_id);
    CHECK(cosim_table_send(transport, &frame, &completion, NULL,
                           TEST_TIMEOUT_MS) == 0);

    CHECK(write(status_fd, &marker, 1) == 1);

    result = cosim_table_recv(transport, &frame, &data_header,
                              sizeof(data_header), payload, sizeof(payload),
                              -1);
    CHECK(result == -1);

    marker = 'D';
    CHECK(write(status_fd, &marker, 1) == 1);
    cosim_table_transport_close(transport);
}

static void test_fragmented_roundtrip_and_shutdown(void)
{
    static const size_t chunk_bytes[] = { 65536u, 65536u, 18928u };
    const uint64_t transaction_id = UINT64_C(0x1122334455667788);
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t server_cfg;
    cosim_table_transport_cfg_t client_cfg;
    cosim_table_transport_t *client;
    cosim_table_frame_hdr_t frame;
    cosim_table_hello_t hello;
    cosim_table_write_data_t data_header;
    cosim_table_completion_t completion;
    uint8_t *payload;
    struct pollfd status_poll;
    pid_t server_child;
    int status_pipe[2];
    size_t offset = 0;
    size_t chunk_index;
    uint64_t close_started_ms;
    char marker;

    memset(&server_cfg, 0, sizeof(server_cfg));
    server_cfg.listen_addr = "127.0.0.1";
    server_cfg.table_port_base = port - TEST_INSTANCE_ID;
    server_cfg.instance_id = TEST_INSTANCE_ID;
    server_cfg.rc_id = TEST_RC_ID;
    server_cfg.is_server = 1;
    server_cfg.connect_timeout_ms = TEST_TIMEOUT_MS;
    CHECK(pipe(status_pipe) == 0);
    server_child = fork();
    CHECK(server_child >= 0);
    if (server_child == 0) {
        CHECK(close(status_pipe[0]) == 0);
        server_main(&server_cfg, status_pipe[1]);
        CHECK(close(status_pipe[1]) == 0);
        _exit(0);
    }
    CHECK(close(status_pipe[1]) == 0);

    memset(&client_cfg, 0, sizeof(client_cfg));
    client_cfg.remote_host = "127.0.0.1";
    client_cfg.table_port_base = port - TEST_INSTANCE_ID;
    client_cfg.instance_id = TEST_INSTANCE_ID;
    client_cfg.rc_id = TEST_RC_ID;
    client_cfg.connect_timeout_ms = TEST_TIMEOUT_MS;
    client = cosim_table_transport_create(&client_cfg);
    CHECK(client != NULL);

    memset(&hello, 0, sizeof(hello));
    hello.protocol_version =
        cosim_table_cpu_to_le32(COSIM_TABLE_PROTOCOL_VERSION);
    hello.max_frame_data_bytes =
        cosim_table_cpu_to_le32(COSIM_TABLE_FRAME_DATA_BYTES);
    hello.capabilities = cosim_table_cpu_to_le32(COSIM_TABLE_CAP_WRITE);
    frame = make_frame(COSIM_TABLE_MSG_HELLO, sizeof(hello), 0, 1);
    CHECK(cosim_table_send(client, &frame, &hello, NULL,
                           TEST_TIMEOUT_MS) == 0);

    payload = malloc(TEST_PAYLOAD_BYTES);
    CHECK(payload != NULL);
    for (offset = 0; offset < TEST_PAYLOAD_BYTES; offset++)
        payload[offset] = payload_byte(offset);

    offset = 0;
    for (chunk_index = 0;
         chunk_index < sizeof(chunk_bytes) / sizeof(chunk_bytes[0]);
         chunk_index++) {
        memset(&data_header, 0, sizeof(data_header));
        data_header.data_offset = cosim_table_cpu_to_le64(offset);
        data_header.data_bytes = cosim_table_cpu_to_le32(chunk_bytes[chunk_index]);
        frame = make_frame(COSIM_TABLE_MSG_WRITE_DATA, sizeof(data_header),
                           chunk_bytes[chunk_index], transaction_id);
        CHECK(cosim_table_send(client, &frame, &data_header, payload + offset,
                               TEST_TIMEOUT_MS) == 0);
        offset += chunk_bytes[chunk_index];
    }
    CHECK(offset == TEST_PAYLOAD_BYTES);
    free(payload);

    memset(&completion, 0, sizeof(completion));
    CHECK(cosim_table_recv(client, &frame, &completion, sizeof(completion),
                           NULL, 0, TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0,
                transaction_id);
    CHECK(cosim_table_le32_to_cpu(completion.status) ==
          COSIM_TABLE_ST_SUCCESS);
    CHECK(cosim_table_le32_to_cpu(completion.committed_count) == 1);

    memset(&status_poll, 0, sizeof(status_poll));
    status_poll.fd = status_pipe[0];
    status_poll.events = POLLIN;
    CHECK(poll(&status_poll, 1, 1000) == 1);
    CHECK(read(status_pipe[0], &marker, 1) == 1);
    CHECK(marker == 'R');
    status_poll.revents = 0;
    CHECK(poll(&status_poll, 1, 50) == 0);
    CHECK(waitpid(server_child, NULL, WNOHANG) == 0);

    close_started_ms = monotonic_ms();
    cosim_table_transport_close(client);
    wait_child_ok(server_child, 1900);
    CHECK(monotonic_ms() - close_started_ms < 2000);
    CHECK(read(status_pipe[0], &marker, 1) == 1);
    CHECK(marker == 'D');
    CHECK(close(status_pipe[0]) == 0);
}

static void test_rejects_port_overflow(void)
{
    cosim_table_transport_cfg_t cfg;

    memset(&cfg, 0, sizeof(cfg));
    cfg.listen_addr = "127.0.0.1";
    cfg.table_port_base = 65535;
    cfg.instance_id = 1;
    cfg.rc_id = TEST_RC_ID;
    cfg.is_server = 1;
    cfg.connect_timeout_ms = 10;
    CHECK(cosim_table_transport_create(&cfg) == NULL);
}

static void test_rejects_mismatched_rc_identity(void)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t server_cfg;
    cosim_table_transport_cfg_t client_cfg;
    cosim_table_transport_t *client;
    pid_t child;

    memset(&server_cfg, 0, sizeof(server_cfg));
    server_cfg.listen_addr = "127.0.0.1";
    server_cfg.table_port_base = port - TEST_INSTANCE_ID;
    server_cfg.instance_id = TEST_INSTANCE_ID;
    server_cfg.rc_id = TEST_RC_ID;
    server_cfg.is_server = 1;
    server_cfg.connect_timeout_ms = 1000;
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        cosim_table_transport_t *server =
            cosim_table_transport_create(&server_cfg);

        CHECK(server == NULL);
        _exit(0);
    }

    memset(&client_cfg, 0, sizeof(client_cfg));
    client_cfg.remote_host = "127.0.0.1";
    client_cfg.table_port_base = port - TEST_INSTANCE_ID;
    client_cfg.instance_id = TEST_INSTANCE_ID;
    client_cfg.rc_id = TEST_RC_ID + 1;
    client_cfg.connect_timeout_ms = 1000;
    client = cosim_table_transport_create(&client_cfg);
    CHECK(client == NULL);

    wait_child_ok(child, 2000);
}

int main(void)
{
    test_rejects_port_overflow();
    test_rejects_mismatched_rc_identity();
    test_fragmented_roundtrip_and_shutdown();
    puts("table TCP transport tests passed");
    return 0;
}
