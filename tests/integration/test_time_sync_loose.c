/* Verify loose-coupling time barrier: each node reports its own sim time;
 * peer can read the latest visible event time through eth_shm_peer_time. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "eth_port.h"

int main(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-ts-%d", (int)getpid());
    eth_shm_unlink(name);

    eth_port_t pa = {0}, pb = {0};
    /* Fixed latency so frame timestamps advance in predictable steps. */
    pa.link.latency_ns = 500;
    pb.link.latency_ns = 500;
    assert(eth_port_open(&pa, name, ETH_ROLE_A, 1) == 0);
    assert(eth_port_open(&pb, name, ETH_ROLE_B, 0) == 0);

    /* Baseline: both node times start at 0. */
    assert(eth_shm_peer_time(&pa.shm, ETH_ROLE_A) == 0);
    assert(eth_shm_peer_time(&pb.shm, ETH_ROLE_B) == 0);

    /* A sends at now_ns=1000 → its node_time advances to >= 1000. */
    eth_frame_t f = {0};
    f.len = 64;
    assert(eth_port_send(&pa, &f, 1000) == 0);
    uint64_t tA_from_B = eth_shm_peer_time(&pb.shm, ETH_ROLE_B);
    assert(tA_from_B >= 1000);

    /* B sends at now_ns=2000. */
    eth_frame_t f2 = {0};
    f2.len = 64;
    assert(eth_port_send(&pb, &f2, 2000) == 0);
    uint64_t tB_from_A = eth_shm_peer_time(&pa.shm, ETH_ROLE_A);
    assert(tB_from_A >= 2000);

    /* A's previous publication should still be visible to B. */
    assert(eth_shm_peer_time(&pb.shm, ETH_ROLE_B) == tA_from_B);

    /* Manually advance A further without a frame; peer should see it. */
    eth_shm_advance_time(&pa.shm, ETH_ROLE_A, 5000);
    assert(eth_shm_peer_time(&pb.shm, ETH_ROLE_B) == 5000);

    /* Drain rings to avoid leaking frames into subsequent tests. */
    eth_frame_t drain;
    while (eth_port_recv(&pa, &drain, 0) == 0) eth_port_tx_complete(&pb);
    while (eth_port_recv(&pb, &drain, 0) == 0) eth_port_tx_complete(&pa);

    eth_port_close(&pb);
    eth_port_close(&pa);

    printf("loose time sync: tA=%lu (seen by B), tB=%lu (seen by A)\n",
           (unsigned long)tA_from_B, (unsigned long)tB_from_A);
    return 0;
}
