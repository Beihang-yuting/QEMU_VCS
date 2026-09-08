#include "test_check.h"

#include "cosim_table_frontdoor_throttle_core.h"

static void test_zero_interval_never_flushes(void)
{
    dpu_table_frontdoor_u64 sequence;

    for (sequence = 1; sequence <= 1000; ++sequence)
        CHECK(!dpu_table_frontdoor_should_flush(sequence, 0));
}

static void test_interval_one_flushes_every_write(void)
{
    dpu_table_frontdoor_u64 sequence;

    for (sequence = 1; sequence <= 1000; ++sequence)
        CHECK(dpu_table_frontdoor_should_flush(sequence, 1));
}

static void test_interval_one_hundred_boundaries(void)
{
    CHECK(!dpu_table_frontdoor_should_flush(0, 100));
    CHECK(!dpu_table_frontdoor_should_flush(99, 100));
    CHECK(dpu_table_frontdoor_should_flush(100, 100));
    CHECK(!dpu_table_frontdoor_should_flush(101, 100));
    CHECK(dpu_table_frontdoor_should_flush(200, 100));
}

static void test_independent_sequences_flush_independently(void)
{
    dpu_table_frontdoor_u64 first_sequence = 99;
    dpu_table_frontdoor_u64 second_sequence = 99;

    CHECK(!dpu_table_frontdoor_should_flush(first_sequence, 100));
    CHECK(!dpu_table_frontdoor_should_flush(second_sequence, 100));

    ++first_sequence;
    CHECK(dpu_table_frontdoor_should_flush(first_sequence, 100));
    CHECK(!dpu_table_frontdoor_should_flush(second_sequence, 100));

    ++second_sequence;
    CHECK(dpu_table_frontdoor_should_flush(second_sequence, 100));
}

int main(void)
{
    test_zero_interval_never_flushes();
    test_interval_one_flushes_every_write();
    test_interval_one_hundred_boundaries();
    test_independent_sequences_flush_independently();
    return 0;
}
