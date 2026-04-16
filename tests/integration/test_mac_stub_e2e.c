/* MAC stub end-to-end test (single process, no real PCIe).
 *
 * Spawns two eth_ports A/B on one SHM, attaches a mac_stub to each with an
 * rx callback that pushes received frames into a small in-memory queue.
 * Node A sends three frames via its stub; node B should receive them.
 */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "eth_port.h"
#include "mac_stub.h"

#define RX_Q_CAP 16

typedef struct {
    eth_frame_t     frames[RX_Q_CAP];
    int             count;
    pthread_mutex_t mtx;
} rx_queue_t;

static void rx_cb(const eth_frame_t *f, void *user)
{
    rx_queue_t *q = (rx_queue_t *)user;
    pthread_mutex_lock(&q->mtx);
    if (q->count < RX_Q_CAP) {
        q->frames[q->count++] = *f;
    }
    pthread_mutex_unlock(&q->mtx);
}

static int rx_q_count(rx_queue_t *q)
{
    pthread_mutex_lock(&q->mtx);
    int n = q->count;
    pthread_mutex_unlock(&q->mtx);
    return n;
}

int main(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-mac-%d", (int)getpid());
    eth_shm_unlink(name);

    eth_port_t pa = {0}, pb = {0};
    assert(eth_port_open(&pa, name, ETH_ROLE_A, 1) == 0);
    assert(eth_port_open(&pb, name, ETH_ROLE_B, 0) == 0);

    rx_queue_t qa = {0}, qb = {0};
    pthread_mutex_init(&qa.mtx, NULL);
    pthread_mutex_init(&qb.mtx, NULL);

    mac_stub_t sa = {0}, sb = {0};
    assert(mac_stub_start(&sa, &pa, rx_cb, &qa) == 0);
    assert(mac_stub_start(&sb, &pb, rx_cb, &qb) == 0);

    /* Node A sends 3 frames to node B. */
    for (int i = 0; i < 3; i++) {
        eth_frame_t f = {0};
        f.len = 128;
        memset(f.data, (uint8_t)(0x10 + i), f.len);
        int rc = -1;
        for (int retry = 0; retry < 100 && rc != 0; retry++) {
            rc = mac_stub_tx(&sa, &f, 0);
            if (rc != 0) {
                struct timespec ts = {0, 1 * 1000 * 1000};
                nanosleep(&ts, NULL);
            }
        }
        assert(rc == 0);
    }

    /* Wait up to ~1s for all 3 to arrive at B. */
    for (int i = 0; i < 500 && rx_q_count(&qb) < 3; i++) {
        struct timespec ts = {0, 2 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    assert(rx_q_count(&qb) == 3);

    /* Validate contents, in order. */
    pthread_mutex_lock(&qb.mtx);
    for (int i = 0; i < 3; i++) {
        assert(qb.frames[i].len == 128);
        assert(qb.frames[i].data[0] == (uint8_t)(0x10 + i));
        assert(qb.frames[i].seq == (uint32_t)i);
    }
    pthread_mutex_unlock(&qb.mtx);

    /* B has not sent anything, so qa should be empty. */
    assert(rx_q_count(&qa) == 0);

    mac_stub_stop(&sa);
    mac_stub_stop(&sb);
    eth_port_close(&pb);
    eth_port_close(&pa);
    pthread_mutex_destroy(&qa.mtx);
    pthread_mutex_destroy(&qb.mtx);

    printf("mac_stub e2e: 3/3 frames delivered\n");
    return 0;
}
