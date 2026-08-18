#include "cosim_table_protocol.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__,         \
                    #condition);                                               \
            abort();                                                           \
        }                                                                      \
    } while (0)

static unsigned int allocation_calls;
static size_t allocation_bytes;

void *table_vcs_test_alloc(size_t bytes)
{
    allocation_calls++;
    allocation_bytes = bytes;
    return NULL;
}

void *table_vcs_test_allocate_route_subset(size_t count);

static void check_route_count(size_t count, unsigned int expected_calls,
                              size_t expected_bytes)
{
    allocation_calls = 0;
    allocation_bytes = 0;
    CHECK(table_vcs_test_allocate_route_subset(count) == NULL);
    CHECK(allocation_calls == expected_calls);
    CHECK(allocation_bytes == expected_bytes);
}

int main(void)
{
    check_route_count(0, 0, 0);
    check_route_count(1, 1, sizeof(cosim_table_route_entry_t));
    check_route_count(COSIM_TABLE_MAX_ROUTES, 1,
                      (size_t)COSIM_TABLE_MAX_ROUTES *
                          sizeof(cosim_table_route_entry_t));
    check_route_count((size_t)COSIM_TABLE_MAX_ROUTES + 1, 0, 0);
    puts("test_table_vcs_alloc: PASS");
    return 0;
}
