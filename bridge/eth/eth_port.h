#ifndef ETH_PORT_H
#define ETH_PORT_H

#include <stdint.h>
#include "eth_shm.h"
#include "eth_types.h"
#include "link_model.h"

/* A node-side handle over an ETH SHM link.
 * Role A owns the A→B TX ring and reads from B→A RX ring; Role B is symmetric.
 * Each port has its own link_model used for TX-side drop / rate / FC decisions.
 */
typedef struct {
    eth_shm_t     shm;
    eth_role_t    role;
    link_model_t  link;       /* TX-side model */
    uint32_t      seq_tx;     /* next outgoing sequence number */
    int           owned_shm;  /* 1 if we created the SHM and should unlink on close */
} eth_port_t;

/* Open a port. create=1 creates/initializes the SHM (first starter), 0 attaches.
 * Returns 0 on success. Caller should pre-fill port->link's config fields before
 * calling, or they default to unlimited.
 */
int  eth_port_open(eth_port_t *port, const char *shm_name,
                   eth_role_t role, int create_shm);

/* Send a frame. Returns:
 *   0  : enqueued successfully
 *  -1  : TX ring full
 *  -2  : blocked by flow-control window
 *  -3  : dropped by link model (not an error; caller may retry next frame)
 * The port stamps frame->seq and frame->timestamp_ns before enqueue.
 */
int  eth_port_send(eth_port_t *port, eth_frame_t *frame, uint64_t now_ns);

/* Receive a frame. timeout_ns = 0 → non-blocking; >0 → block up to that many ns.
 * Returns 0 on success, -1 on timeout/empty.
 */
int  eth_port_recv(eth_port_t *port, eth_frame_t *out, uint64_t timeout_ns);

/* Inform the port that a previously-sent frame has been consumed by the peer
 * (decrements outstanding for flow-control accounting). */
void eth_port_tx_complete(eth_port_t *port);

void eth_port_close(eth_port_t *port);

#endif
