#include "cosim_table_route.h"
#include "table_ctrl_core.h"
#include "table_target.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, \
                    #condition);                                               \
            return -1;                                                         \
        }                                                                      \
    } while (0)

static cosim_table_target_snapshot_t make_snapshot(void)
{
    cosim_table_target_snapshot_t snapshot;

    memset(&snapshot, 0, sizeof(snapshot));
    snapshot.rc_id = 7;
    snapshot.device_instance = 0;
    snapshot.pci_domain = 2;
    snapshot.target_bdf = UINT16_C(0x183);
    snapshot.generation = 11;
    snapshot.bar_sizes[0] = UINT64_C(0x1000);
    snapshot.bar_sizes[2] = UINT64_C(0x2000);
    snapshot.bar_sizes[4] = UINT64_C(0x3000);
    return snapshot;
}

static void fill_live_identity(cosim_table_target_t *target,
                               const cosim_table_target_snapshot_t *snapshot)
{
    target->pci_domain = cosim_table_cpu_to_le16(snapshot->pci_domain);
    target->target_bdf = cosim_table_cpu_to_le16(snapshot->target_bdf);
    target->generation = cosim_table_cpu_to_le32(snapshot->generation);
}

static int test_sparse_owner_mapping(void)
{
    const cosim_table_target_snapshot_t snapshot = make_snapshot();
    uint64_t aperture;
    uint8_t physical;

    CHECK(cosim_table_map_logical_bar(snapshot.bar_sizes, 0, &physical,
                                      &aperture) == 0);
    CHECK(physical == 0 && aperture == UINT64_C(0x1000));
    CHECK(cosim_table_map_logical_bar(snapshot.bar_sizes, 1, &physical,
                                      &aperture) == 0);
    CHECK(physical == 2 && aperture == UINT64_C(0x2000));
    CHECK(cosim_table_map_logical_bar(snapshot.bar_sizes, 2, &physical,
                                      &aperture) != 0);
    return 0;
}

static int test_eligible_sizes_alignment_and_extraction(void)
{
    const cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target;
    uint64_t aligned;
    uint8_t byte_offset;

    CHECK(cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 0,
                                  UINT64_C(0x101), 1, &target, &aligned,
                                  &byte_offset));
    CHECK(target.bar_index == 0);
    CHECK(aligned == UINT64_C(0x100) && byte_offset == 1);
    CHECK(cosim_table_extract_read(UINT32_C(0x44332211), byte_offset, 1) ==
          UINT64_C(0x22));

    CHECK(cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 2, 0,
                                  UINT64_C(0x102), 2, &target, &aligned,
                                  &byte_offset));
    CHECK(target.bar_index == 1);
    CHECK(aligned == UINT64_C(0x100) && byte_offset == 2);
    CHECK(cosim_table_extract_read(UINT32_C(0x44332211), byte_offset, 2) ==
          UINT64_C(0x4433));

    CHECK(cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 2, 0,
                                  UINT64_C(0x104), 4, &target, &aligned,
                                  &byte_offset));
    CHECK(aligned == UINT64_C(0x104) && byte_offset == 0);
    CHECK(cosim_table_extract_read(UINT32_C(0x44332211), byte_offset, 4) ==
          UINT64_C(0x44332211));
    return 0;
}

static int test_ineligible_accesses(void)
{
    const cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target;
    uint64_t aligned;
    uint8_t byte_offset;

    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 0,
                                   0, 8, &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 0,
                                   3, 2, &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 1, 0, 0,
                                   0, 4, &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 1,
                                   0, 4, &target, &aligned, &byte_offset));
    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 4, 0,
                                   0, 4, &target, &aligned, &byte_offset));

    CHECK(cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 0,
                                  UINT64_C(0xffc), 4, &target, &aligned,
                                  &byte_offset));
    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 0,
                                   UINT64_C(0xffd), 4, &target, &aligned,
                                   &byte_offset));
    CHECK(!cosim_table_decode_read(snapshot.bar_sizes, 7, 0, 0, 0, 0,
                                   UINT64_C(0x1000), 1, &target, &aligned,
                                   &byte_offset));
    return 0;
}

static cosim_table_route_entry_t make_route(uint32_t operations)
{
    cosim_table_route_entry_t route;

    memset(&route, 0, sizeof(route));
    cosim_table_target_set_identity(&route.target, 7, 0, 0, 0, 0);
    route.target.target_type = COSIM_TABLE_TARGET_PF;
    route.target.bar_index = 0;
    route.operation_mask = cosim_table_cpu_to_le32(operations);
    route.start_offset = cosim_table_cpu_to_le64(UINT64_C(0x100));
    route.end_offset = cosim_table_cpu_to_le64(UINT64_C(0x140));
    route.entry_bytes = cosim_table_cpu_to_le32(4);
    route.stride_bytes = cosim_table_cpu_to_le32(8);
    return route;
}

static int test_route_capability_stride_and_boundary(void)
{
    cosim_table_route_entry_t route = make_route(COSIM_TABLE_OP_WRITE);
    cosim_table_route_map_t map = { &route, 1, 0 };
    cosim_table_target_t target = route.target;

    fill_live_identity(&target, &(cosim_table_target_snapshot_t){
        .pci_domain = 2, .target_bdf = UINT16_C(0x183), .generation = 11,
    });
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x100),
                                  COSIM_TABLE_OP_WRITE) == &route);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x100),
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);

    route.operation_mask = cosim_table_cpu_to_le32(
        COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x100),
                                  COSIM_TABLE_OP_READ_DWORD) == &route);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x104),
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x138),
                                  COSIM_TABLE_OP_READ_DWORD) == &route);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x13c),
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x140),
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);
    return 0;
}

static int test_inactive_controller_and_stale_generation(void)
{
    const cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_ctrl_core_t core;
    cosim_table_target_t target;
    uint64_t aligned;
    uint8_t byte_offset;

    memset(&core, 0, sizeof(core));
    atomic_init(&core.ready, 0);
    CHECK(!atomic_load_explicit(&core.ready, memory_order_acquire));

    CHECK(cosim_table_decode_read(snapshot.bar_sizes, snapshot.rc_id,
                                  snapshot.device_instance, 0, 0, 0, 0, 4,
                                  &target, &aligned, &byte_offset));
    fill_live_identity(&target, &snapshot);
    CHECK(cosim_table_target_matches(&snapshot, &target));
    target.generation = cosim_table_cpu_to_le32(snapshot.generation + 1);
    CHECK(!cosim_table_target_matches(&snapshot, &target));
    return 0;
}

int main(void)
{
    CHECK(test_sparse_owner_mapping() == 0);
    CHECK(test_eligible_sizes_alignment_and_extraction() == 0);
    CHECK(test_ineligible_accesses() == 0);
    CHECK(test_route_capability_stride_and_boundary() == 0);
    CHECK(test_inactive_controller_and_stale_generation() == 0);
    puts("PASS: table PF0 read decode policy");
    return 0;
}
