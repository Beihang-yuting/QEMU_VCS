#define _POSIX_C_SOURCE 200809L

#include "cosim_table_transport.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define TABLE_HANDSHAKE_MAGIC UINT32_C(0x48544243)
#define TABLE_HANDSHAKE_VERSION 1u
#define TABLE_DEFAULT_CONNECT_TIMEOUT_MS 5000
#define TABLE_RETRY_INTERVAL_MS 10

typedef struct __attribute__((packed)) {
    cosim_u32 magic;
    cosim_u16 version;
    cosim_u16 rc_id;
    cosim_u32 instance_id;
    cosim_u32 reserved;
} table_handshake_t;

_Static_assert(sizeof(table_handshake_t) == 16,
               "table transport handshake must be 16 bytes");

typedef struct {
    int connection_fd;
    int listener_fd;
    int is_server;
    int connecting;
    int fatal;
    int closing;
    int connect_timeout_ms;
    uint16_t rc_id;
    uint32_t instance_id;
    unsigned int active_operations;
    pthread_mutex_t state_lock;
    pthread_mutex_t send_lock;
    pthread_cond_t idle;
} table_tcp_backend_t;

typedef struct {
    struct timespec expires;
    int infinite;
} table_deadline_t;

void cosim_table_transport_tcp_close(void *opaque);

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
        return -2;
    seconds = (int64_t)deadline->expires.tv_sec - (int64_t)now.tv_sec;
    nanoseconds = (int64_t)deadline->expires.tv_nsec - (int64_t)now.tv_nsec;
    if (nanoseconds < 0) {
        --seconds;
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

/* Returns 0 when ready, 1 on deadline expiration, and -1 on error. */
static int wait_fd(int fd, short events, const table_deadline_t *deadline)
{
    struct pollfd descriptor;

    descriptor.fd = fd;
    descriptor.events = events;
    for (;;) {
        int timeout = deadline_remaining_ms(deadline);
        int result;

        if (timeout == -2)
            return -1;
        descriptor.revents = 0;
        result = poll(&descriptor, 1, timeout);
        if (result == 0)
            return 1;
        if (result < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if ((descriptor.revents & events) != 0)
            return 0;
        if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0)
            return -1;
    }
}

static int send_exact(int fd, const void *buffer, size_t bytes,
                      const table_deadline_t *deadline)
{
    const unsigned char *cursor = buffer;
    size_t sent = 0;

    while (sent < bytes) {
        ssize_t result;

        if (wait_fd(fd, POLLOUT, deadline) != 0)
            return -1;
        result = send(fd, cursor + sent, bytes - sent,
                      MSG_DONTWAIT | MSG_NOSIGNAL);
        if (result < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            return -1;
        }
        if (result == 0)
            return -1;
        sent += (size_t)result;
    }
    return 0;
}

/* A timeout is recoverable only if no byte of this frame was consumed. */
static int recv_exact(int fd, void *buffer, size_t bytes,
                      const table_deadline_t *deadline,
                      int allow_clean_timeout)
{
    unsigned char *cursor = buffer;
    size_t received = 0;

    while (received < bytes) {
        int ready = wait_fd(fd, POLLIN, deadline);
        ssize_t result;

        if (ready == 1)
            return allow_clean_timeout && received == 0 ? 1 : -1;
        if (ready < 0)
            return -1;
        result = recv(fd, cursor + received, bytes - received, MSG_DONTWAIT);
        if (result < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            return -1;
        }
        if (result == 0)
            return -1;
        received += (size_t)result;
    }
    return 0;
}

static int set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int set_connection_options(int fd)
{
    int one = 1;

    return setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

static int open_listener(const char *listen_addr, uint16_t port)
{
    struct addrinfo hints;
    struct addrinfo *addresses = NULL;
    struct addrinfo *address;
    char service[16];
    int listener = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_PASSIVE;
    (void)snprintf(service, sizeof(service), "%u", (unsigned int)port);
    if (getaddrinfo(listen_addr, service, &hints, &addresses) != 0)
        return -1;
    for (address = addresses; address != NULL; address = address->ai_next) {
        int one = 1;

        listener = socket(address->ai_family, address->ai_socktype,
                          address->ai_protocol);
        if (listener < 0)
            continue;
        if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR,
                       &one, sizeof(one)) != 0 ||
            bind(listener, address->ai_addr, address->ai_addrlen) != 0 ||
            listen(listener, 1) != 0 || set_nonblocking(listener) != 0) {
            (void)close(listener);
            listener = -1;
            continue;
        }
        break;
    }
    freeaddrinfo(addresses);
    return listener;
}

static int accept_connection(int listener, const table_deadline_t *deadline)
{
    for (;;) {
        int connection;

        if (wait_fd(listener, POLLIN, deadline) != 0)
            return -1;
        connection = accept(listener, NULL, NULL);
        if (connection >= 0) {
            if (set_nonblocking(connection) != 0) {
                (void)close(connection);
                return -1;
            }
            return connection;
        }
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
            return -1;
    }
}

static int try_connect_address(const struct addrinfo *address,
                               const table_deadline_t *deadline)
{
    int connection;
    int socket_error = 0;
    socklen_t error_bytes = sizeof(socket_error);
    int result;

    connection = socket(address->ai_family, address->ai_socktype,
                        address->ai_protocol);
    if (connection < 0)
        return -1;
    if (set_nonblocking(connection) != 0) {
        (void)close(connection);
        return -1;
    }
    result = connect(connection, address->ai_addr, address->ai_addrlen);
    if (result != 0 && errno != EINPROGRESS && errno != EINTR) {
        (void)close(connection);
        return -1;
    }
    if (result != 0) {
        result = wait_fd(connection, POLLOUT, deadline);
        if (result != 0 ||
            getsockopt(connection, SOL_SOCKET, SO_ERROR,
                       &socket_error, &error_bytes) != 0 ||
            socket_error != 0) {
            (void)close(connection);
            return -1;
        }
    }
    return connection;
}

static int connect_host(const char *remote_host, uint16_t port,
                        const table_deadline_t *deadline)
{
    struct addrinfo hints;
    struct addrinfo *addresses = NULL;
    char service[16];
    int connection = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    (void)snprintf(service, sizeof(service), "%u", (unsigned int)port);
    if (getaddrinfo(remote_host, service, &hints, &addresses) != 0)
        return -1;

    while (deadline_remaining_ms(deadline) > 0 && connection < 0) {
        struct addrinfo *address;

        for (address = addresses; address != NULL; address = address->ai_next) {
            connection = try_connect_address(address, deadline);
            if (connection >= 0)
                break;
        }
        if (connection < 0) {
            int remaining = deadline_remaining_ms(deadline);
            int pause_ms = remaining > TABLE_RETRY_INTERVAL_MS
                ? TABLE_RETRY_INTERVAL_MS : remaining;

            if (pause_ms > 0)
                (void)poll(NULL, 0, pause_ms);
        }
    }
    freeaddrinfo(addresses);
    return connection;
}

static int perform_handshake(int fd, uint16_t rc_id, uint32_t instance_id,
                             int timeout_ms)
{
    table_handshake_t outbound;
    table_handshake_t inbound;
    table_deadline_t deadline;

    memset(&outbound, 0, sizeof(outbound));
    outbound.magic = cosim_table_cpu_to_le32(TABLE_HANDSHAKE_MAGIC);
    outbound.version = cosim_table_cpu_to_le16(TABLE_HANDSHAKE_VERSION);
    outbound.rc_id = cosim_table_cpu_to_le16(rc_id);
    outbound.instance_id = cosim_table_cpu_to_le32(instance_id);
    if (deadline_init(&deadline, timeout_ms) != 0 ||
        send_exact(fd, &outbound, sizeof(outbound), &deadline) != 0 ||
        recv_exact(fd, &inbound, sizeof(inbound), &deadline, 0) != 0)
        return -1;
    if (cosim_table_le32_to_cpu(inbound.magic) != TABLE_HANDSHAKE_MAGIC ||
        cosim_table_le16_to_cpu(inbound.version) != TABLE_HANDSHAKE_VERSION ||
        cosim_table_le16_to_cpu(inbound.rc_id) != rc_id ||
        cosim_table_le32_to_cpu(inbound.instance_id) != instance_id ||
        inbound.reserved != 0)
        return -1;
    return 0;
}

static int expected_header_bytes(cosim_u16 type, cosim_u32 *bytes)
{
    switch (type) {
    case COSIM_TABLE_MSG_HELLO:
        *bytes = sizeof(cosim_table_hello_t);
        break;
    case COSIM_TABLE_MSG_CAPABILITY:
        *bytes = sizeof(cosim_table_capability_t);
        break;
    case COSIM_TABLE_MSG_ROUTE_BEGIN:
        *bytes = sizeof(cosim_table_route_begin_t);
        break;
    case COSIM_TABLE_MSG_ROUTE_ENTRY:
        *bytes = sizeof(cosim_table_route_entry_t);
        break;
    case COSIM_TABLE_MSG_ROUTE_END:
        *bytes = sizeof(cosim_table_route_end_t);
        break;
    case COSIM_TABLE_MSG_WRITE_BEGIN:
        *bytes = sizeof(cosim_table_write_begin_t);
        break;
    case COSIM_TABLE_MSG_WRITE_DATA:
        *bytes = sizeof(cosim_table_write_data_t);
        break;
    case COSIM_TABLE_MSG_WRITE_END:
        *bytes = sizeof(cosim_table_write_end_t);
        break;
    case COSIM_TABLE_MSG_READ_DWORD:
        *bytes = sizeof(cosim_table_read_dword_t);
        break;
    case COSIM_TABLE_MSG_COMPLETION:
        *bytes = sizeof(cosim_table_completion_t);
        break;
    case COSIM_TABLE_MSG_SHUTDOWN:
        *bytes = 0;
        break;
    default:
        return -1;
    }
    return 0;
}

static int validate_frame(const cosim_table_frame_hdr_t *frame,
                          cosim_u32 *header_bytes,
                          cosim_u32 *payload_bytes)
{
    cosim_u16 type;
    cosim_u32 expected;

    if (frame == NULL ||
        cosim_table_le32_to_cpu(frame->magic) != COSIM_TABLE_MAGIC ||
        cosim_table_le16_to_cpu(frame->version) !=
            COSIM_TABLE_PROTOCOL_VERSION ||
        cosim_table_le64_to_cpu(frame->transaction_id) == 0)
        return -1;
    type = cosim_table_le16_to_cpu(frame->type);
    *header_bytes = cosim_table_le32_to_cpu(frame->header_bytes);
    *payload_bytes = cosim_table_le32_to_cpu(frame->payload_bytes);
    if (expected_header_bytes(type, &expected) != 0 ||
        *header_bytes != expected ||
        *payload_bytes > COSIM_TABLE_FRAME_DATA_BYTES)
        return -1;
    if (type != COSIM_TABLE_MSG_WRITE_DATA && *payload_bytes != 0)
        return -1;
    return 0;
}

static void operation_end_locked(table_tcp_backend_t *backend)
{
    if (backend->active_operations > 0)
        --backend->active_operations;
    (void)pthread_cond_broadcast(&backend->idle);
}

static void operation_end(table_tcp_backend_t *backend)
{
    (void)pthread_mutex_lock(&backend->state_lock);
    operation_end_locked(backend);
    (void)pthread_mutex_unlock(&backend->state_lock);
}

/*
 * Acquire one active-operation reference and return the connected socket.
 * Server transports accept and handshake lazily so create() can return the
 * listener to its owner before a VCS client exists.  The provisional accepted
 * socket is published before handshake I/O, allowing interrupt() to shutdown
 * every descriptor on which this function may be blocked.
 */
static int operation_begin(table_tcp_backend_t *backend, int *fd)
{
    table_deadline_t deadline;
    int accepted_fd = -1;
    int listener_fd;
    int listener_to_close = -1;
    int handshake_result;

    if (pthread_mutex_lock(&backend->state_lock) != 0)
        return -1;
    if (backend->closing || backend->fatal) {
        (void)pthread_mutex_unlock(&backend->state_lock);
        return -1;
    }
    ++backend->active_operations;

    while (backend->connecting && !backend->closing && !backend->fatal)
        (void)pthread_cond_wait(&backend->idle, &backend->state_lock);
    if (backend->closing || backend->fatal)
        goto fail_locked;
    if (backend->connection_fd >= 0) {
        *fd = backend->connection_fd;
        (void)pthread_mutex_unlock(&backend->state_lock);
        return 0;
    }
    if (!backend->is_server || backend->listener_fd < 0)
        goto fail_locked;

    backend->connecting = 1;
    listener_fd = backend->listener_fd;
    (void)pthread_mutex_unlock(&backend->state_lock);

    if (deadline_init(&deadline, backend->connect_timeout_ms) == 0)
        accepted_fd = accept_connection(listener_fd, &deadline);
    if (accepted_fd >= 0 && set_connection_options(accepted_fd) != 0) {
        (void)close(accepted_fd);
        accepted_fd = -1;
    }

    (void)pthread_mutex_lock(&backend->state_lock);
    if (accepted_fd < 0 || backend->closing || backend->fatal) {
        if (accepted_fd >= 0)
            (void)close(accepted_fd);
        backend->connecting = 0;
        if (!backend->closing)
            backend->fatal = 1;
        goto fail_locked;
    }
    backend->connection_fd = accepted_fd;
    (void)pthread_mutex_unlock(&backend->state_lock);

    handshake_result = perform_handshake(accepted_fd, backend->rc_id,
                                         backend->instance_id,
                                         backend->connect_timeout_ms);

    (void)pthread_mutex_lock(&backend->state_lock);
    if (handshake_result != 0 || backend->closing || backend->fatal) {
        backend->fatal = 1;
        (void)shutdown(accepted_fd, SHUT_RDWR);
        backend->connecting = 0;
        goto fail_locked;
    }
    listener_to_close = backend->listener_fd;
    backend->listener_fd = -1;
    backend->connecting = 0;
    *fd = accepted_fd;
    (void)pthread_cond_broadcast(&backend->idle);
    (void)pthread_mutex_unlock(&backend->state_lock);
    if (listener_to_close >= 0)
        (void)close(listener_to_close);
    return 0;

fail_locked:
    operation_end_locked(backend);
    (void)pthread_mutex_unlock(&backend->state_lock);
    return -1;
}

static void mark_fatal(table_tcp_backend_t *backend)
{
    (void)pthread_mutex_lock(&backend->state_lock);
    backend->fatal = 1;
    if (backend->connection_fd >= 0)
        (void)shutdown(backend->connection_fd, SHUT_RDWR);
    if (backend->listener_fd >= 0)
        (void)shutdown(backend->listener_fd, SHUT_RDWR);
    (void)pthread_cond_broadcast(&backend->idle);
    (void)pthread_mutex_unlock(&backend->state_lock);
}

static void destroy_unopened_backend(table_tcp_backend_t *backend)
{
    if (backend->listener_fd >= 0)
        (void)close(backend->listener_fd);
    if (backend->connection_fd >= 0)
        (void)close(backend->connection_fd);
    (void)pthread_cond_destroy(&backend->idle);
    (void)pthread_mutex_destroy(&backend->send_lock);
    (void)pthread_mutex_destroy(&backend->state_lock);
    free(backend);
}

void *cosim_table_transport_tcp_open(const cosim_table_transport_cfg_t *cfg)
{
    table_tcp_backend_t *backend;
    table_deadline_t deadline;
    uint64_t port;
    const char *host;
    int timeout_ms;

    if (cfg == NULL || (cfg->is_server != 0 && cfg->is_server != 1) ||
        cfg->table_port_base == 0)
        return NULL;
    port = (uint64_t)cfg->table_port_base + (uint64_t)cfg->instance_id;
    if (port > UINT16_MAX)
        return NULL;
    timeout_ms = cfg->connect_timeout_ms > 0
        ? cfg->connect_timeout_ms : TABLE_DEFAULT_CONNECT_TIMEOUT_MS;

    backend = calloc(1, sizeof(*backend));
    if (backend == NULL)
        return NULL;
    backend->connection_fd = -1;
    backend->listener_fd = -1;
    backend->is_server = cfg->is_server;
    backend->connect_timeout_ms = timeout_ms;
    backend->rc_id = cfg->rc_id;
    backend->instance_id = cfg->instance_id;
    if (pthread_mutex_init(&backend->state_lock, NULL) != 0) {
        free(backend);
        return NULL;
    }
    if (pthread_mutex_init(&backend->send_lock, NULL) != 0) {
        (void)pthread_mutex_destroy(&backend->state_lock);
        free(backend);
        return NULL;
    }
    if (pthread_cond_init(&backend->idle, NULL) != 0) {
        (void)pthread_mutex_destroy(&backend->send_lock);
        (void)pthread_mutex_destroy(&backend->state_lock);
        free(backend);
        return NULL;
    }

    if (cfg->is_server) {
        host = cfg->listen_addr != NULL && cfg->listen_addr[0] != '\0'
            ? cfg->listen_addr : "0.0.0.0";
        backend->listener_fd = open_listener(host, (uint16_t)port);
        if (backend->listener_fd < 0) {
            destroy_unopened_backend(backend);
            return NULL;
        }
        return backend;
    }

    host = cfg->remote_host != NULL && cfg->remote_host[0] != '\0'
        ? cfg->remote_host : "127.0.0.1";
    if (deadline_init(&deadline, timeout_ms) != 0)
        backend->connection_fd = -1;
    else
        backend->connection_fd = connect_host(host, (uint16_t)port,
                                              &deadline);
    if (backend->connection_fd < 0 ||
        set_connection_options(backend->connection_fd) != 0 ||
        perform_handshake(backend->connection_fd, cfg->rc_id,
                          cfg->instance_id, timeout_ms) != 0) {
        destroy_unopened_backend(backend);
        return NULL;
    }
    return backend;
}

int cosim_table_transport_tcp_send(void *opaque,
                                   const cosim_table_frame_hdr_t *frame,
                                   const void *header, const void *payload,
                                   int timeout_ms)
{
    table_tcp_backend_t *backend = opaque;
    table_deadline_t deadline;
    cosim_u32 header_bytes;
    cosim_u32 payload_bytes;
    int fd;
    int result = -1;

    if (backend == NULL ||
        validate_frame(frame, &header_bytes, &payload_bytes) != 0 ||
        (header_bytes != 0 && header == NULL) ||
        (payload_bytes != 0 && payload == NULL) ||
        deadline_init(&deadline, timeout_ms) != 0 ||
        operation_begin(backend, &fd) != 0)
        return -1;

    (void)pthread_mutex_lock(&backend->send_lock);
    if (send_exact(fd, frame, sizeof(*frame), &deadline) == 0 &&
        (header_bytes == 0 ||
         send_exact(fd, header, header_bytes, &deadline) == 0) &&
        (payload_bytes == 0 ||
         send_exact(fd, payload, payload_bytes, &deadline) == 0))
        result = 0;
    (void)pthread_mutex_unlock(&backend->send_lock);
    if (result != 0)
        mark_fatal(backend);
    operation_end(backend);
    return result;
}

int cosim_table_transport_tcp_recv(void *opaque,
                                   cosim_table_frame_hdr_t *frame,
                                   void *header, size_t header_capacity,
                                   void *payload, size_t payload_capacity,
                                   int timeout_ms)
{
    table_tcp_backend_t *backend = opaque;
    cosim_table_frame_hdr_t local_frame;
    unsigned char *local_header = NULL;
    unsigned char *local_payload = NULL;
    cosim_u32 header_bytes;
    cosim_u32 payload_bytes;
    table_deadline_t deadline;
    int fd;
    int result;

    if (backend == NULL || frame == NULL ||
        (header_capacity != 0 && header == NULL) ||
        (payload_capacity != 0 && payload == NULL) ||
        deadline_init(&deadline, timeout_ms) != 0 ||
        operation_begin(backend, &fd) != 0)
        return -1;

    result = recv_exact(fd, &local_frame, sizeof(local_frame), &deadline, 1);
    if (result == 1) {
        operation_end(backend);
        return 1;
    }
    if (result != 0 ||
        validate_frame(&local_frame, &header_bytes, &payload_bytes) != 0 ||
        header_bytes > header_capacity || payload_bytes > payload_capacity ||
        (header_bytes != 0 && header == NULL) ||
        (payload_bytes != 0 && payload == NULL))
        goto fatal;

    if (header_bytes != 0) {
        local_header = malloc(header_bytes);
        if (local_header == NULL ||
            recv_exact(fd, local_header, header_bytes, &deadline, 0) != 0)
            goto fatal;
    }
    if (payload_bytes != 0) {
        local_payload = malloc(payload_bytes);
        if (local_payload == NULL ||
            recv_exact(fd, local_payload, payload_bytes, &deadline, 0) != 0)
            goto fatal;
    }

    if (header_bytes != 0)
        memcpy(header, local_header, header_bytes);
    if (payload_bytes != 0)
        memcpy(payload, local_payload, payload_bytes);
    memcpy(frame, &local_frame, sizeof(*frame));
    free(local_header);
    free(local_payload);
    operation_end(backend);
    return 0;

fatal:
    free(local_header);
    free(local_payload);
    mark_fatal(backend);
    operation_end(backend);
    return -1;
}

void cosim_table_transport_tcp_interrupt(void *opaque)
{
    table_tcp_backend_t *backend = opaque;

    if (backend == NULL)
        return;
    (void)pthread_mutex_lock(&backend->state_lock);
    backend->fatal = 1;
    if (backend->connection_fd >= 0)
        (void)shutdown(backend->connection_fd, SHUT_RDWR);
    if (backend->listener_fd >= 0)
        (void)shutdown(backend->listener_fd, SHUT_RDWR);
    (void)pthread_cond_broadcast(&backend->idle);
    (void)pthread_mutex_unlock(&backend->state_lock);
}

void cosim_table_transport_tcp_close(void *opaque)
{
    table_tcp_backend_t *backend = opaque;
    int connection_fd;
    int listener_fd;

    if (backend == NULL)
        return;
    (void)pthread_mutex_lock(&backend->state_lock);
    backend->closing = 1;
    backend->fatal = 1;
    if (backend->connection_fd >= 0)
        (void)shutdown(backend->connection_fd, SHUT_RDWR);
    if (backend->listener_fd >= 0)
        (void)shutdown(backend->listener_fd, SHUT_RDWR);
    (void)pthread_cond_broadcast(&backend->idle);
    while (backend->active_operations != 0)
        (void)pthread_cond_wait(&backend->idle, &backend->state_lock);
    connection_fd = backend->connection_fd;
    listener_fd = backend->listener_fd;
    backend->connection_fd = -1;
    backend->listener_fd = -1;
    (void)pthread_mutex_unlock(&backend->state_lock);

    if (connection_fd >= 0)
        (void)close(connection_fd);
    if (listener_fd >= 0)
        (void)close(listener_fd);
    (void)pthread_cond_destroy(&backend->idle);
    (void)pthread_mutex_destroy(&backend->send_lock);
    (void)pthread_mutex_destroy(&backend->state_lock);
    free(backend);
}
