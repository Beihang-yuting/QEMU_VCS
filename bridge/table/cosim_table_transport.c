#include "cosim_table_transport.h"

#include <errno.h>
#include <stdlib.h>

typedef int (*table_send_fn)(void *, const cosim_table_frame_hdr_t *,
                             const void *, const void *, int);
typedef int (*table_recv_fn)(void *, cosim_table_frame_hdr_t *,
                             void *, size_t, void *, size_t, int);
typedef int (*table_peer_closed_fn)(void *);
typedef void (*table_interrupt_fn)(void *);
typedef void (*table_close_fn)(void *);

struct cosim_table_transport {
    void *backend;
    table_send_fn send;
    table_recv_fn recv;
    table_peer_closed_fn peer_closed;
    table_interrupt_fn interrupt;
    table_close_fn close;
};

void *cosim_table_transport_tcp_open(const cosim_table_transport_cfg_t *cfg);
int cosim_table_transport_tcp_send(void *backend,
                                   const cosim_table_frame_hdr_t *frame,
                                   const void *header, const void *payload,
                                   int timeout_ms);
int cosim_table_transport_tcp_recv(void *backend,
                                   cosim_table_frame_hdr_t *frame,
                                   void *header, size_t header_capacity,
                                   void *payload, size_t payload_capacity,
                                   int timeout_ms);
int cosim_table_transport_tcp_peer_closed(void *backend);
void cosim_table_transport_tcp_interrupt(void *backend);
void cosim_table_transport_tcp_close(void *backend);
int cosim_table_transport_tcp_test_inject_payload_split(
    void *backend, size_t payload_bytes, size_t split, unsigned int pause_ms);

cosim_table_transport_t *cosim_table_transport_create(
    const cosim_table_transport_cfg_t *cfg)
{
    cosim_table_transport_t *transport;
    void *backend = cosim_table_transport_tcp_open(cfg);

    if (backend == NULL)
        return NULL;
    transport = calloc(1, sizeof(*transport));
    if (transport == NULL) {
        int saved_errno = errno;

        cosim_table_transport_tcp_close(backend);
        errno = saved_errno;
        return NULL;
    }
    transport->backend = backend;
    transport->send = cosim_table_transport_tcp_send;
    transport->recv = cosim_table_transport_tcp_recv;
    transport->peer_closed = cosim_table_transport_tcp_peer_closed;
    transport->interrupt = cosim_table_transport_tcp_interrupt;
    transport->close = cosim_table_transport_tcp_close;
    return transport;
}

int cosim_table_send(cosim_table_transport_t *transport,
                     const cosim_table_frame_hdr_t *frame,
                     const void *header, const void *payload, int timeout_ms)
{
    if (transport == NULL || transport->send == NULL) {
        errno = EINVAL;
        return -1;
    }
    return transport->send(transport->backend, frame, header, payload,
                           timeout_ms);
}

int cosim_table_recv(cosim_table_transport_t *transport,
                     cosim_table_frame_hdr_t *frame,
                     void *header, size_t header_capacity,
                     void *payload, size_t payload_capacity, int timeout_ms)
{
    if (transport == NULL || transport->recv == NULL) {
        errno = EINVAL;
        return -1;
    }
    return transport->recv(transport->backend, frame,
                           header, header_capacity,
                           payload, payload_capacity, timeout_ms);
}

int cosim_table_transport_peer_closed(cosim_table_transport_t *transport)
{
    if (transport == NULL || transport->peer_closed == NULL) {
        errno = EINVAL;
        return -1;
    }
    return transport->peer_closed(transport->backend);
}

void cosim_table_transport_interrupt(cosim_table_transport_t *transport)
{
    if (transport != NULL && transport->interrupt != NULL)
        transport->interrupt(transport->backend);
}

void cosim_table_transport_close(cosim_table_transport_t *transport)
{
    if (transport == NULL)
        return;
    if (transport->close != NULL)
        transport->close(transport->backend);
    free(transport);
}

int cosim_table_transport_test_inject_tcp_payload_split(
    cosim_table_transport_t *transport, size_t payload_bytes, size_t split,
    unsigned int pause_ms)
{
    if (transport == NULL ||
        transport->send != cosim_table_transport_tcp_send ||
        transport->recv != cosim_table_transport_tcp_recv) {
        errno = EINVAL;
        return -1;
    }
    return cosim_table_transport_tcp_test_inject_payload_split(
        transport->backend, payload_bytes, split, pause_ms);
}
