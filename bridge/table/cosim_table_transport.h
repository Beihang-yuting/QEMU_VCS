#ifndef COSIM_TABLE_TRANSPORT_H
#define COSIM_TABLE_TRANSPORT_H

#include "cosim_table_protocol.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cosim_table_transport cosim_table_transport_t;

typedef struct {
    const char *remote_host;
    const char *listen_addr;
    uint32_t table_port_base;
    uint32_t instance_id;
    uint16_t rc_id;
    int is_server;
    int connect_timeout_ms;
} cosim_table_transport_cfg_t;

/*
 * Frame and message-specific header fields are little-endian wire values as
 * defined by cosim_table_protocol.h.  Calls return 0 on success, 1 only when
 * receive times out before consuming a frame, and -1 on all other failures.
 * A -1 return always sets errno: EINVAL denotes an invalid API argument,
 * EPROTO an invalid wire frame, ETIMEDOUT an expired deadline, and ESHUTDOWN
 * an interrupted or terminal transport.  Socket and pthread failures retain
 * their specific errno value (for example ECONNRESET, EPIPE, or EBADF).
 * A send deadline expiration makes the connection terminal because a partial
 * frame may have reached the peer.  A partial-frame receive failure is also
 * terminal; only the clean receive timeout reported as 1 is recoverable.
 * Sends are serialized internally, but callers must use only one receiver.
 * interrupt() may run concurrently with a blocked accept, send, or receive.
 * Before close(), the owner must prevent new API calls and join all I/O
 * threads; close() does not synchronize with calls that begin concurrently.
 */
cosim_table_transport_t *cosim_table_transport_create(
    const cosim_table_transport_cfg_t *cfg);
int cosim_table_send(cosim_table_transport_t *transport,
                     const cosim_table_frame_hdr_t *frame,
                     const void *header, const void *payload, int timeout_ms);
int cosim_table_recv(cosim_table_transport_t *transport,
                     cosim_table_frame_hdr_t *frame,
                     void *header, size_t header_capacity,
                     void *payload, size_t payload_capacity, int timeout_ms);
void cosim_table_transport_interrupt(cosim_table_transport_t *transport);
void cosim_table_transport_close(cosim_table_transport_t *transport);

#ifdef __cplusplus
}
#endif

#endif /* COSIM_TABLE_TRANSPORT_H */
