#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "ring_buffer.h"
#include "cosim_types.h"

static void test_init(void) {
    uint8_t buf[1024];
    ring_buf_t rb;
    int ret = ring_buf_init(&rb, buf, sizeof(buf), sizeof(uint32_t));
    assert(ret == 0);
    assert(ring_buf_is_empty(&rb));
    assert(!ring_buf_is_full(&rb));
    assert(ring_buf_count(&rb) == 0);
    printf("  PASS: test_init\n");
}

static void test_enqueue_dequeue_single(void) {
    uint8_t buf[1024];
    ring_buf_t rb;
    ring_buf_init(&rb, buf, sizeof(buf), sizeof(uint32_t));

    uint32_t val_in = 0xDEADBEEF;
    int ret = ring_buf_enqueue(&rb, &val_in);
    assert(ret == 0);
    assert(ring_buf_count(&rb) == 1);
    assert(!ring_buf_is_empty(&rb));

    uint32_t val_out = 0;
    ret = ring_buf_dequeue(&rb, &val_out);
    assert(ret == 0);
    assert(val_out == 0xDEADBEEF);
    assert(ring_buf_is_empty(&rb));
    printf("  PASS: test_enqueue_dequeue_single\n");
}

static void test_fill_and_drain(void) {
    uint8_t buf[sizeof(uint32_t) * 16 + 64];
    ring_buf_t rb;
    ring_buf_init(&rb, buf, sizeof(buf), sizeof(uint32_t));
    uint32_t cap = ring_buf_capacity(&rb);
    assert(cap > 0);

    for (uint32_t i = 0; i < cap; i++) {
        uint32_t val = i + 100;
        int ret = ring_buf_enqueue(&rb, &val);
        assert(ret == 0);
    }
    assert(ring_buf_is_full(&rb));

    uint32_t extra = 999;
    int ret = ring_buf_enqueue(&rb, &extra);
    assert(ret == -1);

    for (uint32_t i = 0; i < cap; i++) {
        uint32_t val = 0;
        ret = ring_buf_dequeue(&rb, &val);
        assert(ret == 0);
        assert(val == i + 100);
    }
    assert(ring_buf_is_empty(&rb));

    uint32_t dummy;
    ret = ring_buf_dequeue(&rb, &dummy);
    assert(ret == -1);

    printf("  PASS: test_fill_and_drain\n");
}

static void test_wrap_around(void) {
    uint8_t buf[sizeof(uint32_t) * 4 + 64];
    ring_buf_t rb;
    ring_buf_init(&rb, buf, sizeof(buf), sizeof(uint32_t));
    uint32_t cap = ring_buf_capacity(&rb);

    for (int round = 0; round < 5; round++) {
        for (uint32_t i = 0; i < cap; i++) {
            uint32_t val = round * 1000 + i;
            assert(ring_buf_enqueue(&rb, &val) == 0);
        }
        for (uint32_t i = 0; i < cap; i++) {
            uint32_t val;
            assert(ring_buf_dequeue(&rb, &val) == 0);
            assert(val == (uint32_t)(round * 1000 + i));
        }
    }
    printf("  PASS: test_wrap_around\n");
}

static void test_tlp_entry_size(void) {
    uint8_t buf[sizeof(tlp_entry_t) * 4 + 64];
    ring_buf_t rb;
    ring_buf_init(&rb, buf, sizeof(buf), sizeof(tlp_entry_t));

    tlp_entry_t entry_in;
    memset(&entry_in, 0, sizeof(entry_in));
    entry_in.type = TLP_MWR;
    entry_in.tag = 0x0A;
    entry_in.addr = 0xFE000010;
    entry_in.len = 4;
    entry_in.data[0] = 0x42;

    assert(ring_buf_enqueue(&rb, &entry_in) == 0);

    tlp_entry_t entry_out;
    assert(ring_buf_dequeue(&rb, &entry_out) == 0);
    assert(entry_out.type == TLP_MWR);
    assert(entry_out.tag == 0x0A);
    assert(entry_out.addr == 0xFE000010);
    assert(entry_out.data[0] == 0x42);

    printf("  PASS: test_tlp_entry_size\n");
}

int main(void) {
    printf("=== ring_buffer tests ===\n");
    test_init();
    test_enqueue_dequeue_single();
    test_fill_and_drain();
    test_wrap_around();
    test_tlp_entry_size();
    printf("=== ALL PASSED ===\n");
    return 0;
}
