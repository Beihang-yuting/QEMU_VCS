#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "eth_shm.h"

static void make_frame(eth_frame_t *f, uint32_t seq, uint16_t len, uint8_t fill)
{
    memset(f, 0, sizeof(*f));
    f->seq = seq;
    f->len = len;
    f->timestamp_ns = seq * 1000ull;
    memset(f->data, fill, len);
}

static void test_open_close_unlink(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-test-%d", (int)getpid());
    eth_shm_unlink(name);

    eth_shm_t shm_creator = {0};
    assert(eth_shm_open(&shm_creator, name, 1) == 0);
    assert(shm_creator.ctrl->magic == ETH_SHM_MAGIC);
    assert(shm_creator.a_to_b->depth == ETH_FRAME_RING_DEPTH);

    /* attach from another handle */
    eth_shm_t shm_peer = {0};
    assert(eth_shm_open(&shm_peer, name, 0) == 0);
    assert(shm_peer.ctrl->magic == ETH_SHM_MAGIC);

    eth_shm_close(&shm_peer);
    eth_shm_close(&shm_creator);
    eth_shm_unlink(name);
    printf("  PASS: test_open_close_unlink\n");
}

static void test_enqueue_dequeue_order(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-test-%d", (int)getpid());
    eth_shm_unlink(name);
    eth_shm_t shm = {0};
    assert(eth_shm_open(&shm, name, 1) == 0);

    eth_frame_ring_t *ring = shm.a_to_b;
    eth_frame_t f;
    for (uint32_t i = 0; i < 10; i++) {
        make_frame(&f, i, 64, (uint8_t)i);
        assert(eth_shm_enqueue(ring, &f) == 0);
    }
    for (uint32_t i = 0; i < 10; i++) {
        eth_frame_t out;
        assert(eth_shm_dequeue(ring, &out) == 0);
        assert(out.seq == i);
        assert(out.len == 64);
        assert(out.data[0] == (uint8_t)i);
    }
    assert(eth_shm_dequeue(ring, &f) == -1);  /* empty */

    eth_shm_close(&shm);
    eth_shm_unlink(name);
    printf("  PASS: test_enqueue_dequeue_order\n");
}

static void test_ring_full(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-test-%d", (int)getpid());
    eth_shm_unlink(name);
    eth_shm_t shm = {0};
    assert(eth_shm_open(&shm, name, 1) == 0);

    eth_frame_t f;
    uint32_t pushed = 0;
    while (1) {
        make_frame(&f, pushed, 32, 0xAB);
        if (eth_shm_enqueue(shm.a_to_b, &f) < 0) break;
        pushed++;
    }
    /* ring capacity = depth - 1 (SPSC convention) */
    assert(pushed == ETH_FRAME_RING_DEPTH - 1);

    eth_shm_close(&shm);
    eth_shm_unlink(name);
    printf("  PASS: test_ring_full\n");
}

static void test_roles_are_opposite(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-test-%d", (int)getpid());
    eth_shm_unlink(name);
    eth_shm_t shm = {0};
    assert(eth_shm_open(&shm, name, 1) == 0);

    assert(eth_shm_tx_ring(&shm, ETH_ROLE_A) == shm.a_to_b);
    assert(eth_shm_rx_ring(&shm, ETH_ROLE_A) == shm.b_to_a);
    assert(eth_shm_tx_ring(&shm, ETH_ROLE_B) == shm.b_to_a);
    assert(eth_shm_rx_ring(&shm, ETH_ROLE_B) == shm.a_to_b);

    eth_shm_close(&shm);
    eth_shm_unlink(name);
    printf("  PASS: test_roles_are_opposite\n");
}

static void test_ready_flag_and_time(void)
{
    char name[64];
    snprintf(name, sizeof(name), "/cosim-eth-test-%d", (int)getpid());
    eth_shm_unlink(name);
    eth_shm_t shm = {0};
    assert(eth_shm_open(&shm, name, 1) == 0);

    assert(eth_shm_peer_ready(&shm, ETH_ROLE_A) == 0);
    eth_shm_mark_ready(&shm, ETH_ROLE_B);
    assert(eth_shm_peer_ready(&shm, ETH_ROLE_A) == 1);

    eth_shm_advance_time(&shm, ETH_ROLE_A, 12345);
    assert(eth_shm_peer_time(&shm, ETH_ROLE_B) == 12345);
    eth_shm_advance_time(&shm, ETH_ROLE_B, 67890);
    assert(eth_shm_peer_time(&shm, ETH_ROLE_A) == 67890);

    eth_shm_close(&shm);
    eth_shm_unlink(name);
    printf("  PASS: test_ready_flag_and_time\n");
}

int main(void)
{
    printf("=== eth_shm tests ===\n");
    test_open_close_unlink();
    test_enqueue_dequeue_order();
    test_ring_full();
    test_roles_are_opposite();
    test_ready_flag_and_time();
    printf("=== ALL PASSED ===\n");
    return 0;
}
