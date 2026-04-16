#include "eth_port.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int eth_port_open(eth_port_t *port, const char *shm_name,
                  eth_role_t role, int create_shm)
{
    if (!port || !shm_name) return -1;
    memset(&port->shm, 0, sizeof(port->shm));
    port->role = role;
    port->seq_tx = 0;
    port->owned_shm = create_shm ? 1 : 0;

    /* link_model config is pre-filled by caller; we only reset runtime state. */
    uint32_t seed = (uint32_t)(role == ETH_ROLE_A ? 0xA11CE : 0xB0B);
    link_model_reset(&port->link, seed);

    if (eth_shm_open(&port->shm, shm_name, create_shm) < 0) {
        return -1;
    }
    eth_shm_mark_ready(&port->shm, role);
    return 0;
}

int eth_port_send(eth_port_t *port, eth_frame_t *frame, uint64_t now_ns)
{
    if (!port || !frame) return -1;

    if (!link_model_fc_can_send(&port->link)) {
        return -2;
    }
    if (link_model_should_drop(&port->link)) {
        return -3;
    }

    /* Stamp sender metadata. */
    frame->seq = port->seq_tx++;
    frame->timestamp_ns = link_model_deadline(&port->link, frame->len, now_ns);

    eth_frame_ring_t *tx = eth_shm_tx_ring(&port->shm, port->role);
    if (eth_shm_enqueue(tx, frame) < 0) {
        return -1;
    }
    link_model_inc_outstanding(&port->link);
    /* Loose-coupling time sync: publish our local sim time as "last event". */
    eth_shm_advance_time(&port->shm, port->role, frame->timestamp_ns);
    return 0;
}

int eth_port_recv(eth_port_t *port, eth_frame_t *out, uint64_t timeout_ns)
{
    if (!port || !out) return -1;
    eth_frame_ring_t *rx = eth_shm_rx_ring(&port->shm, port->role);

    uint64_t start = now_mono_ns();
    for (;;) {
        if (eth_shm_dequeue(rx, out) == 0) {
            return 0;
        }
        if (timeout_ns == 0) {
            return -1;
        }
        if (now_mono_ns() - start > timeout_ns) {
            return -1;
        }
        struct timespec ts = { 0, 100 * 1000 };  /* 100 us polling backoff */
        nanosleep(&ts, NULL);
    }
}

void eth_port_tx_complete(eth_port_t *port)
{
    if (port) link_model_dec_outstanding(&port->link);
}

void eth_port_close(eth_port_t *port)
{
    if (!port) return;
    char saved_name[sizeof(port->shm.name)];
    snprintf(saved_name, sizeof(saved_name), "%s", port->shm.name);
    int owned = port->owned_shm;

    eth_shm_close(&port->shm);
    if (owned && saved_name[0]) {
        eth_shm_unlink(saved_name);
    }
}
