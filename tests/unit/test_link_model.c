#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "link_model.h"

static void test_no_drop_when_ppm_zero(void)
{
    link_model_t m = {0};
    m.drop_rate_ppm = 0;
    link_model_reset(&m, 42);
    for (int i = 0; i < 1000; i++) {
        assert(link_model_should_drop(&m) == 0);
    }
    printf("  PASS: test_no_drop_when_ppm_zero\n");
}

static void test_drop_rate_within_bounds(void)
{
    link_model_t m = {0};
    m.drop_rate_ppm = 100000;    /* 10% */
    m.burst_drop_len = 1;        /* no burst — isolate drop rate */
    link_model_reset(&m, 1);

    int dropped = 0;
    const int n = 10000;
    for (int i = 0; i < n; i++) {
        if (link_model_should_drop(&m)) dropped++;
    }
    /* Expect ~1000; allow 800..1200 for RNG variance. */
    assert(dropped >= 800 && dropped <= 1200);
    printf("  PASS: test_drop_rate_within_bounds (dropped=%d/%d)\n", dropped, n);
}

static void test_burst_drop_length(void)
{
    link_model_t m = {0};
    m.drop_rate_ppm = 1000000;   /* always trigger */
    m.burst_drop_len = 5;
    link_model_reset(&m, 7);

    int drops_in_a_row = 0;
    for (int i = 0; i < 10; i++) {
        if (link_model_should_drop(&m)) drops_in_a_row++;
        else break;
    }
    /* First 5 frames must be drops (ppm=1M so always trigger, burst=5). */
    assert(drops_in_a_row >= 5);
    printf("  PASS: test_burst_drop_length (drops_in_a_row=%d)\n", drops_in_a_row);
}

static void test_burst_continues_after_trigger(void)
{
    link_model_t m = {0};
    m.drop_rate_ppm = 0;         /* no random trigger */
    m.burst_drop_len = 3;
    link_model_reset(&m, 1);

    /* Manually simulate a triggered burst by peeking at state. */
    m.burst_remaining = 3;
    assert(link_model_should_drop(&m) == 1);
    assert(link_model_should_drop(&m) == 1);
    assert(link_model_should_drop(&m) == 1);
    assert(link_model_should_drop(&m) == 0);  /* burst done, ppm=0 so no drop */
    printf("  PASS: test_burst_continues_after_trigger\n");
}

static void test_rate_limit_deadline(void)
{
    link_model_t m = {0};
    m.rate_mbps = 1000;      /* 1 Gbps */
    m.latency_ns = 0;
    link_model_reset(&m, 1);

    /* 1500-byte frame at 1 Gbps → 1500*8/1000 = 12000 ns = 12 us */
    uint64_t d = link_model_deadline(&m, 1500, 0);
    assert(d == 12000);

    /* Next frame arriving at t=5000 ns is still behind the token bucket (=12000) */
    uint64_t d2 = link_model_deadline(&m, 1500, 5000);
    assert(d2 == 24000);      /* 12000 + 12000 */
    printf("  PASS: test_rate_limit_deadline (d=%lu d2=%lu)\n",
           (unsigned long)d, (unsigned long)d2);
}

static void test_latency_is_added(void)
{
    link_model_t m = {0};
    m.rate_mbps = 0;          /* unlimited rate */
    m.latency_ns = 5000;      /* 5 us */
    link_model_reset(&m, 1);

    uint64_t d = link_model_deadline(&m, 1500, 1000);
    assert(d == 6000);        /* 1000 + 0 serialize + 5000 latency */
    printf("  PASS: test_latency_is_added\n");
}

static void test_fc_window(void)
{
    link_model_t m = {0};
    m.fc_window = 4;
    link_model_reset(&m, 1);

    for (int i = 0; i < 4; i++) {
        assert(link_model_fc_can_send(&m) == 1);
        link_model_inc_outstanding(&m);
    }
    assert(link_model_fc_can_send(&m) == 0);   /* window full */
    link_model_dec_outstanding(&m);
    assert(link_model_fc_can_send(&m) == 1);
    printf("  PASS: test_fc_window\n");
}

static void test_fc_unlimited_when_zero(void)
{
    link_model_t m = {0};
    m.fc_window = 0;
    link_model_reset(&m, 1);
    for (int i = 0; i < 1000; i++) {
        assert(link_model_fc_can_send(&m) == 1);
        link_model_inc_outstanding(&m);
    }
    printf("  PASS: test_fc_unlimited_when_zero\n");
}

static void test_deterministic_across_resets(void)
{
    link_model_t a = {0}, b = {0};
    a.drop_rate_ppm = 200000; a.burst_drop_len = 1;
    b.drop_rate_ppm = 200000; b.burst_drop_len = 1;
    link_model_reset(&a, 42);
    link_model_reset(&b, 42);
    for (int i = 0; i < 1000; i++) {
        assert(link_model_should_drop(&a) == link_model_should_drop(&b));
    }
    printf("  PASS: test_deterministic_across_resets\n");
}

int main(void)
{
    printf("=== link_model tests ===\n");
    test_no_drop_when_ppm_zero();
    test_drop_rate_within_bounds();
    test_burst_drop_length();
    test_burst_continues_after_trigger();
    test_rate_limit_deadline();
    test_latency_is_added();
    test_fc_window();
    test_fc_unlimited_when_zero();
    test_deterministic_across_resets();
    printf("=== ALL PASSED ===\n");
    return 0;
}
