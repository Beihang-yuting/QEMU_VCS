#ifndef MAC_STUB_H
#define MAC_STUB_H

#include <pthread.h>
#include <stdatomic.h>
#include "eth_port.h"

/* Callback invoked by mac_stub whenever an ETH frame is received from the peer.
 * The callback runs on the poll thread. Copy the frame if you need to retain it.
 */
typedef void (*mac_rx_cb_t)(const eth_frame_t *frame, void *user);

typedef struct {
    eth_port_t *    port;
    mac_rx_cb_t     rx_cb;
    void *          user;
    pthread_t       thread;
    _Atomic int     running;
    _Atomic int     started;
} mac_stub_t;

/* Start the stub: spawns a poll thread that continuously calls eth_port_recv
 * and dispatches to rx_cb. Returns 0 on success.
 */
int  mac_stub_start(mac_stub_t *stub, eth_port_t *port,
                    mac_rx_cb_t rx_cb, void *user);

/* Fire-and-forget TX path. Returns the eth_port_send rc. */
int  mac_stub_tx(mac_stub_t *stub, eth_frame_t *frame, uint64_t now_ns);

/* Stops the poll thread and joins it. Safe to call multiple times. */
void mac_stub_stop(mac_stub_t *stub);

#endif
