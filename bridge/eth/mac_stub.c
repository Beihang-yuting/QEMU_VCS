#include "mac_stub.h"
#include <string.h>
#include <time.h>

static void *mac_stub_worker(void *arg)
{
    mac_stub_t *stub = (mac_stub_t *)arg;
    while (atomic_load(&stub->running)) {
        eth_frame_t f;
        int rc = eth_port_recv(stub->port, &f, 0);
        if (rc == 0) {
            /* Ack outstanding back to sender (best effort — only valid in
             * single-process tests where both ports are local). */
            eth_port_tx_complete(stub->port);
            if (stub->rx_cb) {
                stub->rx_cb(&f, stub->user);
            }
        } else {
            struct timespec ts = { 0, 200 * 1000 };  /* 200us idle sleep */
            nanosleep(&ts, NULL);
        }
    }
    return NULL;
}

int mac_stub_start(mac_stub_t *stub, eth_port_t *port,
                   mac_rx_cb_t rx_cb, void *user)
{
    if (!stub || !port) return -1;
    memset(stub, 0, sizeof(*stub));
    stub->port = port;
    stub->rx_cb = rx_cb;
    stub->user = user;
    atomic_store(&stub->running, 1);
    if (pthread_create(&stub->thread, NULL, mac_stub_worker, stub) != 0) {
        atomic_store(&stub->running, 0);
        return -1;
    }
    atomic_store(&stub->started, 1);
    return 0;
}

int mac_stub_tx(mac_stub_t *stub, eth_frame_t *frame, uint64_t now_ns)
{
    if (!stub || !stub->port || !frame) return -1;
    return eth_port_send(stub->port, frame, now_ns);
}

void mac_stub_stop(mac_stub_t *stub)
{
    if (!stub) return;
    if (atomic_exchange(&stub->started, 0)) {
        atomic_store(&stub->running, 0);
        pthread_join(stub->thread, NULL);
    }
}
