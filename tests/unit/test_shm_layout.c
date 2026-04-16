#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "shm_layout.h"
#include "cosim_types.h"

static void test_create_and_open(void) {
    const char *name = "/cosim_test_shm";
    cosim_shm_t shm_creator, shm_opener;

    int ret = cosim_shm_create(&shm_creator, name);
    assert(ret == 0);
    assert(shm_creator.base != NULL);
    assert(shm_creator.ctrl->magic == COSIM_SHM_MAGIC);
    assert(shm_creator.ctrl->version == COSIM_PROTOCOL_VER);

    ret = cosim_shm_open(&shm_opener, name);
    assert(ret == 0);
    assert(shm_opener.ctrl->magic == COSIM_SHM_MAGIC);

    cosim_shm_close(&shm_opener);
    cosim_shm_destroy(&shm_creator, name);
    printf("  PASS: test_create_and_open\n");
}

static void test_request_queue(void) {
    const char *name = "/cosim_test_shm_req";
    cosim_shm_t shm;
    cosim_shm_create(&shm, name);

    tlp_entry_t entry_in;
    memset(&entry_in, 0, sizeof(entry_in));
    entry_in.type = TLP_MWR;
    entry_in.tag = 1;
    entry_in.addr = 0x1000;
    entry_in.len = 4;
    entry_in.data[0] = 0xAB;

    int ret = ring_buf_enqueue(&shm.req_ring, &entry_in);
    assert(ret == 0);

    tlp_entry_t entry_out;
    ret = ring_buf_dequeue(&shm.req_ring, &entry_out);
    assert(ret == 0);
    assert(entry_out.type == TLP_MWR);
    assert(entry_out.addr == 0x1000);
    assert(entry_out.data[0] == 0xAB);

    cosim_shm_destroy(&shm, name);
    printf("  PASS: test_request_queue\n");
}

static void test_control_region(void) {
    const char *name = "/cosim_test_shm_ctrl";
    cosim_shm_t shm;
    cosim_shm_create(&shm, name);

    assert(shm.ctrl->mode == COSIM_MODE_FAST);
    atomic_store(&shm.ctrl->qemu_ready, 1);
    assert(atomic_load(&shm.ctrl->qemu_ready) == 1);

    cosim_shm_destroy(&shm, name);
    printf("  PASS: test_control_region\n");
}

int main(void) {
    printf("=== shm_layout tests ===\n");
    test_create_and_open();
    test_request_queue();
    test_control_region();
    printf("=== ALL PASSED ===\n");
    return 0;
}
