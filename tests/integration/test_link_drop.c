/* Verify that link-model drop + FC behave correctly when exercised through eth_port. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "eth_port.h"

static void test_drop_reduces_rx(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-drop-%d", (int)getpid());
    eth_shm_unlink(name);

    eth_port_t pa = {0}, pb = {0};
    /* 30% drop at sender, no burst (isolate drop rate). */
    pa.link.drop_rate_ppm = 300000;
    pa.link.burst_drop_len = 1;
    assert(eth_port_open(&pa, name, ETH_ROLE_A, 1) == 0);
    assert(eth_port_open(&pb, name, ETH_ROLE_B, 0) == 0);

    const int N = 1000;
    int tx_ok = 0, tx_dropped = 0, rx = 0;
    for (int i = 0; i < N; i++) {
        eth_frame_t f = {0};
        f.len = 128;
        memset(f.data, 0xAA, f.len);
        int rc = eth_port_send(&pa, &f, (uint64_t)i * 1000);
        if (rc == 0) tx_ok++;
        else if (rc == -3) tx_dropped++;

        eth_frame_t out = {0};
        if (eth_port_recv(&pb, &out, 0) == 0) {
            rx++;
            eth_port_tx_complete(&pa);
        }
    }
    /* Drain. */
    eth_frame_t out = {0};
    while (eth_port_recv(&pb, &out, 0) == 0) {
        rx++;
        eth_port_tx_complete(&pa);
    }

    printf("drop test: tx_ok=%d tx_dropped=%d rx=%d (expected drop ~%d)\n",
           tx_ok, tx_dropped, rx, N * 3 / 10);

    /* Expect ~30% drop; allow 20..40% band. */
    assert(tx_dropped >= N * 2 / 10 && tx_dropped <= N * 4 / 10);
    /* Everything that was not dropped made it through. */
    assert(rx == tx_ok);

    eth_port_close(&pb);
    eth_port_close(&pa);
    printf("  PASS: test_drop_reduces_rx\n");
}

static void test_fc_rejects_beyond_window(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-drop-%d", (int)getpid());
    eth_shm_unlink(name);

    eth_port_t pa = {0}, pb = {0};
    pa.link.fc_window = 4;
    assert(eth_port_open(&pa, name, ETH_ROLE_A, 1) == 0);
    assert(eth_port_open(&pb, name, ETH_ROLE_B, 0) == 0);

    /* Send 4 frames without any recv → fc full on 5th. */
    for (int i = 0; i < 4; i++) {
        eth_frame_t f = {0};
        f.len = 32;
        assert(eth_port_send(&pa, &f, 0) == 0);
    }
    eth_frame_t f5 = {0};
    f5.len = 32;
    assert(eth_port_send(&pa, &f5, 0) == -2);

    /* Drain one on the far side, then we can send once more. */
    eth_frame_t r = {0};
    assert(eth_port_recv(&pb, &r, 1000000) == 0);
    eth_port_tx_complete(&pa);
    assert(eth_port_send(&pa, &f5, 0) == 0);

    eth_port_close(&pb);
    eth_port_close(&pa);
    printf("  PASS: test_fc_rejects_beyond_window\n");
}

int main(void)
{
    printf("=== link_drop tests ===\n");
    test_drop_reduces_rx();
    test_fc_rejects_beyond_window();
    printf("=== ALL PASSED ===\n");
    return 0;
}
