/* In-process A↔B frame loopback through eth_port. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "eth_port.h"

int main(void)
{
    char shm_name[64];
    snprintf(shm_name, sizeof(shm_name), "/cosim-eth-lb-%d", (int)getpid());
    eth_shm_unlink(shm_name);

    eth_port_t pa = {0}, pb = {0};
    /* Link model fields default to 0 (no drop / unlimited / no fc). */
    assert(eth_port_open(&pa, shm_name, ETH_ROLE_A, 1) == 0);
    assert(eth_port_open(&pb, shm_name, ETH_ROLE_B, 0) == 0);

    const int N = 500;
    int tx = 0, rx = 0;

    /* Alternate send and recv to avoid back-pressure on the ring. */
    for (int i = 0; i < N; i++) {
        eth_frame_t f = {0};
        f.len = 64;
        memset(f.data, (uint8_t)i, f.len);

        int rc = eth_port_send(&pa, &f, (uint64_t)i * 1000);
        if (rc == 0) tx++;

        eth_frame_t out = {0};
        if (eth_port_recv(&pb, &out, 1000000) == 0) {
            rx++;
            eth_port_tx_complete(&pa);
            assert(out.len == 64);
            assert(out.seq == (uint32_t)(rx - 1));
            assert(out.data[0] == (uint8_t)(rx - 1));
        }
    }

    /* Drain anything still in the ring. */
    eth_frame_t tail = {0};
    while (eth_port_recv(&pb, &tail, 0) == 0) {
        rx++;
        eth_port_tx_complete(&pa);
    }

    printf("loopback: tx=%d rx=%d\n", tx, rx);
    assert(tx == N);
    assert(rx == N);

    eth_port_close(&pb);
    eth_port_close(&pa);
    return 0;
}
