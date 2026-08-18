#define _GNU_SOURCE
#include "cosim_table_transport.h"

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

typedef struct {
    cosim_table_transport_t *transport;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    int started;
    int finished;
    int result;
} blocking_recv_ctx_t;

static void blocking_recv_ctx_init(blocking_recv_ctx_t *ctx,
                                   cosim_table_transport_t *transport)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->transport = transport;
    CHECK(pthread_mutex_init(&ctx->lock, NULL) == 0);
    CHECK(pthread_cond_init(&ctx->condition, NULL) == 0);
}

static void blocking_recv_ctx_destroy(blocking_recv_ctx_t *ctx)
{
    CHECK(pthread_cond_destroy(&ctx->condition) == 0);
    CHECK(pthread_mutex_destroy(&ctx->lock) == 0);
}

static void *blocking_recv_main(void *opaque)
{
    blocking_recv_ctx_t *ctx = opaque;
    cosim_table_frame_hdr_t frame;
    unsigned char header[sizeof(cosim_table_route_entry_t)];
    unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];

    CHECK(pthread_mutex_lock(&ctx->lock) == 0);
    ctx->started = 1;
    CHECK(pthread_cond_broadcast(&ctx->condition) == 0);
    CHECK(pthread_mutex_unlock(&ctx->lock) == 0);

    ctx->result = cosim_table_recv(ctx->transport, &frame,
                                   header, sizeof(header),
                                   payload, sizeof(payload), -1);

    CHECK(pthread_mutex_lock(&ctx->lock) == 0);
    ctx->finished = 1;
    CHECK(pthread_cond_broadcast(&ctx->condition) == 0);
    CHECK(pthread_mutex_unlock(&ctx->lock) == 0);
    return NULL;
}

static void require_recv_is_blocked(blocking_recv_ctx_t *ctx)
{
    struct timespec deadline;
    int wait_result = 0;

    CHECK(pthread_mutex_lock(&ctx->lock) == 0);
    while (!ctx->started)
        CHECK(pthread_cond_wait(&ctx->condition, &ctx->lock) == 0);
    deadline = realtime_after_ms(50);
    while (!ctx->finished && wait_result == 0)
        wait_result = pthread_cond_timedwait(&ctx->condition, &ctx->lock,
                                             &deadline);
    CHECK(!ctx->finished);
    CHECK(wait_result == ETIMEDOUT);
    CHECK(pthread_mutex_unlock(&ctx->lock) == 0);
}

static void interrupt_and_join(cosim_table_transport_t *transport,
                               blocking_recv_ctx_t *ctx,
                               pthread_t thread)
{
    struct timespec deadline = realtime_after_ms(2000);
    uint64_t started_ms = monotonic_ms();

    cosim_table_transport_interrupt(transport);
    CHECK(pthread_timedjoin_np(thread, NULL, &deadline) == 0);
    CHECK(monotonic_ms() - started_ms < 2000);
    CHECK(ctx->result == -1);
}

static cosim_table_transport_cfg_t make_server_cfg(uint16_t port,
                                                    int timeout_ms)
{
    cosim_table_transport_cfg_t cfg;

    memset(&cfg, 0, sizeof(cfg));
    cfg.listen_addr = "127.0.0.1";
    cfg.table_port_base = port - TEST_INSTANCE_ID;
    cfg.instance_id = TEST_INSTANCE_ID;
    cfg.rc_id = TEST_RC_ID;
    cfg.is_server = 1;
    cfg.connect_timeout_ms = timeout_ms;
    return cfg;
}

static cosim_table_transport_cfg_t make_client_cfg(uint16_t port,
                                                    int timeout_ms)
{
    cosim_table_transport_cfg_t cfg;

    memset(&cfg, 0, sizeof(cfg));
    cfg.remote_host = "127.0.0.1";
    cfg.table_port_base = port - TEST_INSTANCE_ID;
    cfg.instance_id = TEST_INSTANCE_ID;
    cfg.rc_id = TEST_RC_ID;
    cfg.connect_timeout_ms = timeout_ms;
    return cfg;
}

static void test_server_create_returns_before_accept(void)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t cfg = make_server_cfg(port, 500);
    cosim_table_transport_t *server;
    uint64_t started_ms = monotonic_ms();

    server = cosim_table_transport_create(&cfg);
    CHECK(server != NULL);
    CHECK(monotonic_ms() - started_ms < 200);
    cosim_table_transport_close(server);
}

static void test_interrupts_listener_accept(void)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t cfg = make_server_cfg(port, 5000);
    cosim_table_transport_t *server;
    blocking_recv_ctx_t recv_ctx;
    pthread_t recv_thread;

    server = cosim_table_transport_create(&cfg);
    CHECK(server != NULL);
    blocking_recv_ctx_init(&recv_ctx, server);
    CHECK(pthread_create(&recv_thread, NULL,
                         blocking_recv_main, &recv_ctx) == 0);
    require_recv_is_blocked(&recv_ctx);
    interrupt_and_join(server, &recv_ctx, recv_thread);
    blocking_recv_ctx_destroy(&recv_ctx);
    cosim_table_transport_close(server);
}

static void test_interrupts_connected_blocking_receive(void)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t server_cfg =
        make_server_cfg(port, TEST_TIMEOUT_MS);
    cosim_table_transport_cfg_t client_cfg =
        make_client_cfg(port, TEST_TIMEOUT_MS);
    cosim_table_transport_t *server;
    cosim_table_transport_t *client;
    blocking_recv_ctx_t recv_ctx;
    pthread_t recv_thread;

    server = cosim_table_transport_create(&server_cfg);
    CHECK(server != NULL);
    blocking_recv_ctx_init(&recv_ctx, server);
    CHECK(pthread_create(&recv_thread, NULL,
                         blocking_recv_main, &recv_ctx) == 0);
    client = cosim_table_transport_create(&client_cfg);
    CHECK(client != NULL);

    require_recv_is_blocked(&recv_ctx);
    interrupt_and_join(server, &recv_ctx, recv_thread);
    blocking_recv_ctx_destroy(&recv_ctx);
    cosim_table_transport_close(client);
    cosim_table_transport_close(server);
}

static void test_accept_timeout_then_late_client_roundtrip(void)
{
    const uint64_t transaction_id = UINT64_C(0x8877665544332211);
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t server_cfg = make_server_cfg(port, 100);
    cosim_table_transport_cfg_t client_cfg = make_client_cfg(port, 1000);
    cosim_table_transport_t *server;
    cosim_table_transport_t *client;
    blocking_recv_ctx_t recv_ctx;
    cosim_table_frame_hdr_t frame;
    cosim_table_hello_t hello;
    cosim_table_completion_t completion;
    unsigned char header[sizeof(cosim_table_route_entry_t)];
    unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];
    pthread_t recv_thread;
    struct timespec deadline;

    server = cosim_table_transport_create(&server_cfg);
    CHECK(server != NULL);
    CHECK(cosim_table_recv(server, &frame, header, sizeof(header),
                           payload, sizeof(payload), 1000) == 1);

    blocking_recv_ctx_init(&recv_ctx, server);
    CHECK(pthread_create(&recv_thread, NULL,
                         blocking_recv_main, &recv_ctx) == 0);
    client = cosim_table_transport_create(&client_cfg);
    CHECK(client != NULL);

    memset(&hello, 0, sizeof(hello));
    hello.protocol_version =
        cosim_table_cpu_to_le32(COSIM_TABLE_PROTOCOL_VERSION);
    hello.max_frame_data_bytes =
        cosim_table_cpu_to_le32(COSIM_TABLE_FRAME_DATA_BYTES);
    frame = make_frame(COSIM_TABLE_MSG_HELLO, sizeof(hello), 0,
                       transaction_id);
    CHECK(cosim_table_send(client, &frame, &hello, NULL, 1000) == 0);

    deadline = realtime_after_ms(2000);
    CHECK(pthread_timedjoin_np(recv_thread, NULL, &deadline) == 0);
    CHECK(recv_ctx.result == 0);
    blocking_recv_ctx_destroy(&recv_ctx);

    memset(&completion, 0, sizeof(completion));
    completion.status = cosim_table_cpu_to_le32(COSIM_TABLE_ST_SUCCESS);
    frame = make_frame(COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0,
                       transaction_id);
    CHECK(cosim_table_send(server, &frame, &completion, NULL, 1000) == 0);
    memset(&completion, 0, sizeof(completion));
    CHECK(cosim_table_recv(client, &frame, &completion, sizeof(completion),
                           NULL, 0, 1000) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_COMPLETION, sizeof(completion), 0,
                transaction_id);
    CHECK(cosim_table_le32_to_cpu(completion.status) ==
          COSIM_TABLE_ST_SUCCESS);

    cosim_table_transport_close(client);
    cosim_table_transport_close(server);
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
        cosim_table_frame_hdr_t frame;
        unsigned char header[sizeof(cosim_table_route_entry_t)];
        unsigned char payload[COSIM_TABLE_FRAME_DATA_BYTES];
        cosim_table_transport_t *server =
            cosim_table_transport_create(&server_cfg);

        CHECK(server != NULL);
        CHECK(cosim_table_recv(server, &frame, header, sizeof(header),
                               payload, sizeof(payload), -1) == -1);
        cosim_table_transport_close(server);
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

static int find_connection_fd(uint16_t port, int match_peer)
{
    int fd;

    for (fd = 3; fd < 1024; fd++) {
        struct sockaddr_in local;
        struct sockaddr_in peer;
        socklen_t local_bytes = sizeof(local);
        socklen_t peer_bytes = sizeof(peer);
        uint16_t selected_port;

        if (getsockname(fd, (struct sockaddr *)&local, &local_bytes) != 0 ||
            getpeername(fd, (struct sockaddr *)&peer, &peer_bytes) != 0 ||
            local.sin_family != AF_INET || peer.sin_family != AF_INET)
            continue;
        selected_port = ntohs(match_peer ? peer.sin_port : local.sin_port);
        if (selected_port == port)
            return fd;
    }
    return -1;
}

static void set_connection_buffer(uint16_t port, int match_peer,
                                  int option)
{
    const int buffer_bytes = 4096;
    int fd = find_connection_fd(port, match_peer);

    CHECK(fd >= 0);
    CHECK(setsockopt(fd, SOL_SOCKET, option, &buffer_bytes,
                     sizeof(buffer_bytes)) == 0);
}

static void fill_connection_send_buffer(uint16_t port)
{
    uint8_t bytes[4096];
    int fd = find_connection_fd(port, 1);

    CHECK(fd >= 0);
    memset(bytes, 0xa7, sizeof(bytes));
    for (;;) {
        ssize_t result = send(fd, bytes, sizeof(bytes),
                              MSG_DONTWAIT | MSG_NOSIGNAL);

        if (result > 0)
            continue;
        CHECK(result < 0);
        CHECK(errno == EAGAIN || errno == EWOULDBLOCK);
        return;
    }
}

static void backpressure_server_main(const cosim_table_transport_cfg_t *cfg,
                                     uint16_t port, int ready_fd,
                                     int release_fd)
{
    cosim_table_transport_t *transport;
    cosim_table_frame_hdr_t frame;
    cosim_table_hello_t hello;
    char marker = 'R';

    transport = cosim_table_transport_create(cfg);
    CHECK(transport != NULL);
    CHECK(cosim_table_recv(transport, &frame, &hello, sizeof(hello), NULL, 0,
                           TEST_TIMEOUT_MS) == 0);
    check_frame(&frame, COSIM_TABLE_MSG_HELLO, sizeof(hello), 0, 1);
    set_connection_buffer(port, 0, SO_RCVBUF);
    CHECK(write(ready_fd, &marker, 1) == 1);
    CHECK(read(release_fd, &marker, 1) == 1);
    CHECK(marker == 'D');
    cosim_table_transport_close(transport);
}

static void test_send_timeout_reports_etimedout(void)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t server_cfg =
        make_server_cfg(port, TEST_TIMEOUT_MS);
    cosim_table_transport_cfg_t client_cfg =
        make_client_cfg(port, TEST_TIMEOUT_MS);
    cosim_table_transport_t *client;
    cosim_table_frame_hdr_t frame;
    cosim_table_hello_t hello;
    cosim_table_write_data_t data_header;
    uint8_t payload[COSIM_TABLE_FRAME_DATA_BYTES];
    uint64_t started_ms;
    pid_t child;
    int ready_pipe[2];
    int release_pipe[2];
    int result = 0;
    int saved_errno = 0;
    unsigned int attempt;
    char marker;

    CHECK(pipe(ready_pipe) == 0);
    CHECK(pipe(release_pipe) == 0);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        CHECK(close(ready_pipe[0]) == 0);
        CHECK(close(release_pipe[1]) == 0);
        backpressure_server_main(&server_cfg, port, ready_pipe[1],
                                 release_pipe[0]);
        CHECK(close(ready_pipe[1]) == 0);
        CHECK(close(release_pipe[0]) == 0);
        _exit(0);
    }
    CHECK(close(ready_pipe[1]) == 0);
    CHECK(close(release_pipe[0]) == 0);

    client = cosim_table_transport_create(&client_cfg);
    CHECK(client != NULL);
    set_connection_buffer(port, 1, SO_SNDBUF);
    memset(&hello, 0, sizeof(hello));
    frame = make_frame(COSIM_TABLE_MSG_HELLO, sizeof(hello), 0, 1);
    CHECK(cosim_table_send(client, &frame, &hello, NULL,
                           TEST_TIMEOUT_MS) == 0);
    CHECK(read(ready_pipe[0], &marker, 1) == 1);
    CHECK(marker == 'R');

    memset(payload, 0x5a, sizeof(payload));
    memset(&data_header, 0, sizeof(data_header));
    data_header.data_bytes = cosim_table_cpu_to_le32(sizeof(payload));
    started_ms = monotonic_ms();
    for (attempt = 0; attempt < 4096; attempt++) {
        frame = make_frame(COSIM_TABLE_MSG_WRITE_DATA, sizeof(data_header),
                           sizeof(payload), attempt + 2u);
        errno = 0;
        result = cosim_table_send(client, &frame, &data_header, payload, 10);
        if (result != 0) {
            saved_errno = errno;
            break;
        }
    }
    CHECK(result == -1);
    CHECK(saved_errno == ETIMEDOUT);
    CHECK(monotonic_ms() - started_ms < 2000);
    frame = make_frame(COSIM_TABLE_MSG_HELLO, sizeof(hello), 0,
                       UINT64_C(0xffff));
    CHECK(cosim_table_send(client, &frame, &hello, NULL, 100) == -1);

    marker = 'D';
    CHECK(write(release_pipe[1], &marker, 1) == 1);
    CHECK(close(release_pipe[1]) == 0);
    CHECK(close(ready_pipe[0]) == 0);
    cosim_table_transport_close(client);
    wait_child_ok(child, TEST_TIMEOUT_MS);
}

typedef struct {
    cosim_table_transport_t *transport;
    cosim_table_frame_hdr_t frame;
    cosim_table_write_data_t header;
    const uint8_t *payload;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    int started;
    int finished;
    int result;
    int saved_errno;
} blocking_send_ctx_t;

static void *blocking_send_main(void *opaque)
{
    blocking_send_ctx_t *ctx = opaque;

    CHECK(pthread_mutex_lock(&ctx->lock) == 0);
    ctx->started = 1;
    CHECK(pthread_cond_broadcast(&ctx->condition) == 0);
    CHECK(pthread_mutex_unlock(&ctx->lock) == 0);

    errno = 0;
    ctx->result = cosim_table_send(ctx->transport, &ctx->frame, &ctx->header,
                                   ctx->payload, 1000);
    ctx->saved_errno = errno;

    CHECK(pthread_mutex_lock(&ctx->lock) == 0);
    ctx->finished = 1;
    CHECK(pthread_cond_broadcast(&ctx->condition) == 0);
    CHECK(pthread_mutex_unlock(&ctx->lock) == 0);
    return NULL;
}

static void require_send_is_blocked(blocking_send_ctx_t *ctx)
{
    struct timespec deadline;
    int wait_result = 0;

    CHECK(pthread_mutex_lock(&ctx->lock) == 0);
    while (!ctx->started)
        CHECK(pthread_cond_wait(&ctx->condition, &ctx->lock) == 0);
    deadline = realtime_after_ms(50);
    while (!ctx->finished && wait_result == 0)
        wait_result = pthread_cond_timedwait(&ctx->condition, &ctx->lock,
                                             &deadline);
    CHECK(!ctx->finished);
    CHECK(wait_result == ETIMEDOUT);
    CHECK(pthread_mutex_unlock(&ctx->lock) == 0);
}

static void test_send_lock_wait_obeys_deadline(void)
{
    const uint16_t port = reserve_available_port();
    cosim_table_transport_cfg_t server_cfg =
        make_server_cfg(port, TEST_TIMEOUT_MS);
    cosim_table_transport_cfg_t client_cfg =
        make_client_cfg(port, TEST_TIMEOUT_MS);
    cosim_table_transport_t *client;
    cosim_table_frame_hdr_t frame;
    cosim_table_hello_t hello;
    cosim_table_write_data_t data_header;
    blocking_send_ctx_t send_ctx;
    uint8_t payload[COSIM_TABLE_FRAME_DATA_BYTES];
    struct timespec join_deadline;
    pthread_t send_thread;
    uint64_t started_ms;
    pid_t child;
    int ready_pipe[2];
    int release_pipe[2];
    int result;
    int saved_errno;
    char marker;

    CHECK(pipe(ready_pipe) == 0);
    CHECK(pipe(release_pipe) == 0);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        CHECK(close(ready_pipe[0]) == 0);
        CHECK(close(release_pipe[1]) == 0);
        backpressure_server_main(&server_cfg, port, ready_pipe[1],
                                 release_pipe[0]);
        CHECK(close(ready_pipe[1]) == 0);
        CHECK(close(release_pipe[0]) == 0);
        _exit(0);
    }
    CHECK(close(ready_pipe[1]) == 0);
    CHECK(close(release_pipe[0]) == 0);

    client = cosim_table_transport_create(&client_cfg);
    CHECK(client != NULL);
    set_connection_buffer(port, 1, SO_SNDBUF);
    memset(&hello, 0, sizeof(hello));
    frame = make_frame(COSIM_TABLE_MSG_HELLO, sizeof(hello), 0, 1);
    CHECK(cosim_table_send(client, &frame, &hello, NULL,
                           TEST_TIMEOUT_MS) == 0);
    CHECK(read(ready_pipe[0], &marker, 1) == 1);
    CHECK(marker == 'R');
    fill_connection_send_buffer(port);

    memset(payload, 0x3c, sizeof(payload));
    memset(&data_header, 0, sizeof(data_header));
    data_header.data_bytes = cosim_table_cpu_to_le32(sizeof(payload));
    memset(&send_ctx, 0, sizeof(send_ctx));
    send_ctx.transport = client;
    send_ctx.frame = make_frame(COSIM_TABLE_MSG_WRITE_DATA,
                                sizeof(data_header), sizeof(payload), 2);
    send_ctx.header = data_header;
    send_ctx.payload = payload;
    CHECK(pthread_mutex_init(&send_ctx.lock, NULL) == 0);
    CHECK(pthread_cond_init(&send_ctx.condition, NULL) == 0);
    CHECK(pthread_create(&send_thread, NULL, blocking_send_main,
                         &send_ctx) == 0);
    require_send_is_blocked(&send_ctx);

    frame = make_frame(COSIM_TABLE_MSG_WRITE_DATA, sizeof(data_header),
                       sizeof(payload), 3);
    started_ms = monotonic_ms();
    errno = 0;
    result = cosim_table_send(client, &frame, &data_header, payload, 50);
    saved_errno = errno;
    CHECK(result == -1);
    CHECK(saved_errno == ETIMEDOUT);
    CHECK(monotonic_ms() - started_ms < 300);

    join_deadline = realtime_after_ms(2000);
    CHECK(pthread_timedjoin_np(send_thread, NULL, &join_deadline) == 0);
    CHECK(send_ctx.result == -1);
    CHECK(pthread_cond_destroy(&send_ctx.condition) == 0);
    CHECK(pthread_mutex_destroy(&send_ctx.lock) == 0);

    marker = 'D';
    CHECK(write(release_pipe[1], &marker, 1) == 1);
    CHECK(close(release_pipe[1]) == 0);
    CHECK(close(ready_pipe[0]) == 0);
    cosim_table_transport_close(client);
    wait_child_ok(child, TEST_TIMEOUT_MS);
}

int main(void)
{
    test_rejects_port_overflow();
    test_server_create_returns_before_accept();
    test_interrupts_listener_accept();
    test_interrupts_connected_blocking_receive();
    test_accept_timeout_then_late_client_roundtrip();
    test_rejects_mismatched_rc_identity();
    test_send_timeout_reports_etimedout();
    test_send_lock_wait_obeys_deadline();
    test_fragmented_roundtrip_and_shutdown();
    puts("table TCP transport tests passed");
    return 0;
}
