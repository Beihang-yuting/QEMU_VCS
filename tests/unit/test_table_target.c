#include "table_target.h"

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
    snapshot.rc_id = 3;
    snapshot.device_instance = 17;
    snapshot.pci_domain = 2;
    snapshot.target_bdf = 0x5a;
    snapshot.generation = 41;

    /* Preserve physical 64-bit BAR owner slots 0/2/4.  Matching exposes only
     * dense logical BAR0/BAR1; physical BAR4 remains snapshot metadata. */
    snapshot.bar_sizes[0] = UINT64_C(0x1000);
    snapshot.bar_sizes[2] = UINT64_C(0x2000);
    snapshot.bar_sizes[4] = UINT64_C(0x4000);
    return snapshot;
}

static cosim_table_target_t make_target(uint8_t bar_index)
{
    cosim_table_target_t target;

    memset(&target, 0, sizeof(target));
    target.rc_id = cosim_table_cpu_to_le16(3);
    target.device_instance = cosim_table_cpu_to_le16(17);
    target.pci_domain = cosim_table_cpu_to_le16(2);
    target.target_bdf = cosim_table_cpu_to_le16(0x5a);
    target.target_type = COSIM_TABLE_TARGET_PF;
    target.pf_index = 0;
    target.bar_index = bar_index;
    target.generation = cosim_table_cpu_to_le32(41);
    return target;
}

static int test_matches_live_pf0_logical_bars(void)
{
    cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t bar0 = make_target(0);
    cosim_table_target_t bar1 = make_target(1);

    CHECK(snapshot.bar_sizes[0] == UINT64_C(0x1000));
    CHECK(snapshot.bar_sizes[1] == 0);
    CHECK(snapshot.bar_sizes[2] == UINT64_C(0x2000));
    CHECK(snapshot.bar_sizes[4] == UINT64_C(0x4000));
    CHECK(cosim_table_target_snapshot_valid(&snapshot));
    CHECK(cosim_table_target_matches(&snapshot, &bar0));
    CHECK(cosim_table_target_matches(&snapshot, &bar1));
    return 0;
}

static int test_rejects_non_pf0_identity(void)
{
    cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target = make_target(0);

    target.pf_index = 1;
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    target = make_target(0);
    target.vf_index = cosim_table_cpu_to_le16(1);
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    target = make_target(0);
    target.target_type = COSIM_TABLE_TARGET_VF;
    target.vf_index = cosim_table_cpu_to_le16(1);
    CHECK(!cosim_table_target_matches(&snapshot, &target));
    return 0;
}

static int test_rejects_invalid_or_replaced_generation(void)
{
    cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target = make_target(0);

    snapshot.generation = 0;
    CHECK(!cosim_table_target_snapshot_valid(&snapshot));
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    snapshot = make_snapshot();
    snapshot.generation++;
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    snapshot = make_snapshot();
    target.generation = 0;
    CHECK(!cosim_table_target_matches(&snapshot, &target));
    return 0;
}

static int test_rejects_absent_bar(void)
{
    cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target = make_target(1);

    snapshot.bar_sizes[2] = 0;
    snapshot.bar_sizes[4] = 0;
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    snapshot = make_snapshot();
    target = make_target(2);
    CHECK(!cosim_table_target_matches(&snapshot, &target));
    return 0;
}

static int test_rejects_mismatched_live_identity(void)
{
    cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target = make_target(0);

    target.device_instance = cosim_table_cpu_to_le16(18);
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    target = make_target(0);
    target.rc_id = cosim_table_cpu_to_le16(4);
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    target = make_target(0);
    target.pci_domain = cosim_table_cpu_to_le16(3);
    CHECK(!cosim_table_target_matches(&snapshot, &target));

    target = make_target(0);
    target.target_bdf = cosim_table_cpu_to_le16(0x62);
    CHECK(!cosim_table_target_matches(&snapshot, &target));
    return 0;
}

static int test_rejects_null_values(void)
{
    cosim_table_target_snapshot_t snapshot = make_snapshot();
    cosim_table_target_t target = make_target(0);

    CHECK(!cosim_table_target_snapshot_valid(NULL));
    CHECK(!cosim_table_target_matches(NULL, &target));
    CHECK(!cosim_table_target_matches(&snapshot, NULL));
    return 0;
}

int main(void)
{
    CHECK(test_matches_live_pf0_logical_bars() == 0);
    CHECK(test_rejects_non_pf0_identity() == 0);
    CHECK(test_rejects_invalid_or_replaced_generation() == 0);
    CHECK(test_rejects_absent_bar() == 0);
    CHECK(test_rejects_mismatched_live_identity() == 0);
    CHECK(test_rejects_null_values() == 0);
    puts("PASS: table target snapshot policy");
    return 0;
}
