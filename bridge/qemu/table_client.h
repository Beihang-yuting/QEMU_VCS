#ifndef COSIM_TABLE_CLIENT_H
#define COSIM_TABLE_CLIENT_H

#include "cosim_table_route.h"
#include "cosim_table_transport.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cosim_table_client cosim_table_client_t;

/* The caller retains ownership of transport and closes it after destroy.
 * Requests and target fields use protocol little-endian encoding.  Completion
 * fields returned by write/read are decoded to host byte order.  A send or
 * completion-wait timeout after an RPC starts makes the client terminal;
 * later read/write calls return TARGET_GONE without using the wire. */
cosim_table_client_t *cosim_table_client_create(
    cosim_table_transport_t *transport, uint16_t rc_id);
int cosim_table_client_wait_routes(cosim_table_client_t *client,
                                   int timeout_ms);
const cosim_table_route_entry_t *cosim_table_client_match(
    cosim_table_client_t *client, const cosim_table_target_t *target,
    uint64_t offset, uint8_t operation);
cosim_table_status_t cosim_table_client_write(
    cosim_table_client_t *client, const cosim_table_write_begin_t *request,
    const uint8_t *payload, cosim_table_completion_t *completion,
    int timeout_ms);
cosim_table_status_t cosim_table_client_read_dword(
    cosim_table_client_t *client, const cosim_table_read_dword_t *request,
    cosim_table_completion_t *completion, int timeout_ms);
void cosim_table_client_destroy(cosim_table_client_t *client);

#ifdef __cplusplus
}
#endif

#endif /* COSIM_TABLE_CLIENT_H */
