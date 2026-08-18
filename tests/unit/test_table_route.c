#define _POSIX_C_SOURCE 200809L

#include "cosim_table_route.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef TABLE_ROUTE_FIXTURE_DIR
#error "TABLE_ROUTE_FIXTURE_DIR must name the route fixture directory"
#endif

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, \
                    #condition);                                               \
            return -1;                                                         \
        }                                                                      \
    } while (0)

static const char *fixture_path(const char *name)
{
    static char path[1024];

    if (snprintf(path, sizeof(path), "%s/%s", TABLE_ROUTE_FIXTURE_DIR, name) >=
        (int)sizeof(path)) {
        return NULL;
    }
    return path;
}

static uint64_t fnv1a64(const void *data, size_t bytes)
{
    const uint8_t *octets = data;
    uint64_t hash = UINT64_C(14695981039346656037);
    size_t i;

    for (i = 0; i < bytes; ++i) {
        hash ^= octets[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static cosim_table_target_t make_target(uint16_t rc, uint16_t device,
                                        uint8_t bar)
{
    cosim_table_target_t target;

    memset(&target, 0, sizeof(target));
    target.rc_id = cosim_table_cpu_to_le16(rc);
    target.device_instance = cosim_table_cpu_to_le16(device);
    target.pci_domain = cosim_table_cpu_to_le16(7);
    target.target_bdf = cosim_table_cpu_to_le16(0x88);
    target.target_type = COSIM_TABLE_TARGET_PF;
    target.pf_index = 0;
    target.bar_index = bar;
    target.generation = cosim_table_cpu_to_le32(99);
    return target;
}

static cosim_table_route_entry_t make_read_route(uint64_t start, uint64_t end,
                                                 uint32_t entry_bytes,
                                                 uint32_t stride_bytes)
{
    cosim_table_route_entry_t route;

    memset(&route, 0, sizeof(route));
    route.target = make_target(0, 0, 0);
    route.operation_mask = cosim_table_cpu_to_le32(
        COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD);
    route.start_offset = cosim_table_cpu_to_le64(start);
    route.end_offset = cosim_table_cpu_to_le64(end);
    route.entry_bytes = cosim_table_cpu_to_le32(entry_bytes);
    route.stride_bytes = cosim_table_cpu_to_le32(stride_bytes);
    return route;
}

static size_t temp_write_limit = SIZE_MAX;
static int temp_write_error;
static int temp_close_error;
static unsigned int temp_close_calls;

static ssize_t temp_write(int fd, const void *buffer, size_t bytes)
{
    if (temp_write_error) {
        errno = EIO;
        return -1;
    }
    if (bytes > temp_write_limit) {
        bytes = temp_write_limit;
    }
    return write(fd, buffer, bytes);
}

static int temp_close(int fd)
{
    int result;

    ++temp_close_calls;
    result = close(fd);
    if (temp_close_error) {
        temp_close_error = 0;
        errno = EIO;
        return -1;
    }
    return result;
}

static void reset_temp_io(void)
{
    temp_write_limit = SIZE_MAX;
    temp_write_error = 0;
    temp_close_error = 0;
    temp_close_calls = 0;
}

static int write_all_temp(int fd, const char *contents, size_t bytes)
{
    size_t offset = 0;

    while (offset < bytes) {
        ssize_t written = temp_write(fd, contents + offset, bytes - offset);

        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (written == 0) {
            return -1;
        }
        offset += (size_t)written;
    }
    return 0;
}

static int write_temp_file(const char *contents, char *path, size_t path_bytes)
{
    char pattern[] = "/tmp/cosim-table-route-XXXXXX";
    size_t bytes;
    int fd = -1;
    int result = -1;

    if (contents == NULL || path == NULL ||
        strlen(pattern) + 1 > path_bytes) {
        return -1;
    }
    bytes = strlen(contents);
    fd = mkstemp(pattern);
    if (fd < 0) {
        return -1;
    }
    if (write_all_temp(fd, contents, bytes) != 0) {
        goto done;
    }
    result = temp_close(fd);
    fd = -1;
    if (result != 0) {
        goto done;
    }
    memcpy(path, pattern, strlen(pattern) + 1);
    return 0;

done:
    if (fd >= 0) {
        (void)temp_close(fd);
    }
    unlink(pattern);
    return -1;
}

static int test_temp_file_cleanup_paths(void)
{
    char path[128];
    char short_path[1] = {'x'};
    int failures = 0;
    int result;

    reset_temp_io();
    temp_write_limit = 1;
    result = write_temp_file("partial", path, sizeof(path));
    if (result != 0 || temp_close_calls != 1) {
        fprintf(stderr, "partial write was not completed and closed once\n");
        ++failures;
    } else {
        unlink(path);
    }

    reset_temp_io();
    temp_write_error = 1;
    result = write_temp_file("error", path, sizeof(path));
    if (result == 0 || temp_close_calls != 1) {
        fprintf(stderr, "write failure did not close exactly once\n");
        ++failures;
        if (result == 0) {
            unlink(path);
        }
    }

    reset_temp_io();
    temp_close_error = 1;
    result = write_temp_file("close", path, sizeof(path));
    if (result == 0 || temp_close_calls != 1) {
        fprintf(stderr, "close failure retried or was accepted\n");
        ++failures;
        if (result == 0) {
            unlink(path);
        }
    }

    reset_temp_io();
    result = write_temp_file("path", short_path, sizeof(short_path));
    if (result == 0 || temp_close_calls != 0) {
        fprintf(stderr, "short output path created or closed a file\n");
        ++failures;
    }

    CHECK(failures == 0);
    return 0;
}

static int expect_invalid_text(const char *contents)
{
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    char error[256] = {0};
    char path[128];
    int rc;

    CHECK(write_temp_file(contents, path, sizeof(path)) == 0);
    rc = cosim_table_route_load(path, &map, error, sizeof(error));
    unlink(path);
    CHECK(rc != 0);
    CHECK(map.entries == NULL);
    CHECK(map.count == 0);
    CHECK(map.generation_hash == 0);
    CHECK(error[0] != '\0');
    return 0;
}

static int test_valid_operations_and_fixed_width_entries(void)
{
    const cosim_table_route_entry_t *entry;
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    char error[256] = {0};

    CHECK(cosim_table_route_load(fixture_path("table_routes_valid.ini"), &map,
                                 error, sizeof(error)) == 0);
    CHECK(map.count == 3);
    CHECK(map.entries != NULL);
    CHECK(map.generation_hash ==
          fnv1a64(map.entries, map.count * sizeof(map.entries[0])));

    entry = &map.entries[0];
    CHECK(cosim_table_le32_to_cpu(entry->route_id) == 0);
    CHECK(cosim_table_le16_to_cpu(entry->target.rc_id) == 0);
    CHECK(cosim_table_le16_to_cpu(entry->target.device_instance) == 0);
    CHECK(entry->target.target_type == COSIM_TABLE_TARGET_PF);
    CHECK(entry->target.pf_index == 0);
    CHECK(entry->target.bar_index == 0);
    CHECK(cosim_table_le32_to_cpu(entry->operation_mask) ==
          COSIM_TABLE_OP_WRITE);
    CHECK(cosim_table_le64_to_cpu(entry->start_offset) == UINT64_C(0x1000));
    CHECK(cosim_table_le64_to_cpu(entry->end_offset) == UINT64_C(0x2000));
    CHECK(cosim_table_le32_to_cpu(entry->entry_bytes) == 16);
    CHECK(cosim_table_le32_to_cpu(entry->stride_bytes) == 16);
    CHECK(cosim_table_le32_to_cpu(entry->index_base) == 0);
    CHECK(strcmp((const char *)entry->handler_name, "default_write") == 0);

    entry = &map.entries[1];
    CHECK(cosim_table_le32_to_cpu(entry->route_id) == 1);
    CHECK(entry->target.bar_index == 1);
    CHECK(cosim_table_le32_to_cpu(entry->operation_mask) ==
          COSIM_TABLE_OP_WRITE);
    CHECK(cosim_table_le32_to_cpu(entry->entry_bytes) == 32);
    CHECK(cosim_table_le32_to_cpu(entry->stride_bytes) == 64);
    CHECK(cosim_table_le32_to_cpu(entry->index_base) == 8);
    CHECK(strcmp((const char *)entry->handler_name, "explicit_write") == 0);

    entry = &map.entries[2];
    CHECK(cosim_table_le32_to_cpu(entry->route_id) == 2);
    CHECK(cosim_table_le32_to_cpu(entry->operation_mask) ==
          (COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD));
    CHECK(cosim_table_le32_to_cpu(entry->entry_bytes) == 128);
    CHECK(strcmp((const char *)entry->handler_name, "readable") == 0);

    cosim_table_route_free(&map);
    CHECK(map.entries == NULL);
    CHECK(map.count == 0);
    CHECK(map.generation_hash == 0);
    return 0;
}

static int test_map_initialization_reload_and_free_contract(void)
{
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    char error[256] = {0};

    CHECK(map.entries == NULL);
    CHECK(map.count == 0);
    CHECK(map.generation_hash == 0);
    CHECK(cosim_table_route_load(fixture_path("table_routes_valid.ini"), &map,
                                 error, sizeof(error)) == 0);
    CHECK(map.entries != NULL);
    CHECK(map.count == 3);
    CHECK(cosim_table_route_load(fixture_path("table_routes_valid.ini"), &map,
                                 error, sizeof(error)) == 0);
    CHECK(map.entries != NULL);
    CHECK(map.count == 3);
    CHECK(map.generation_hash ==
          fnv1a64(map.entries, map.count * sizeof(map.entries[0])));

    cosim_table_route_free(&map);
    CHECK(map.entries == NULL);
    CHECK(map.count == 0);
    CHECK(map.generation_hash == 0);
    cosim_table_route_free(&map);
    CHECK(map.entries == NULL);
    CHECK(map.count == 0);
    CHECK(map.generation_hash == 0);
    return 0;
}

static int test_matching_and_slicing(void)
{
    const cosim_table_route_entry_t *route;
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    cosim_table_target_t target;
    uint64_t first_index;
    uint32_t entry_count;
    char error[256] = {0};

    CHECK(cosim_table_route_load(fixture_path("table_routes_valid.ini"), &map,
                                 error, sizeof(error)) == 0);

    target = make_target(0, 0, 0);
    route = cosim_table_route_match(&map, &target, UINT64_C(0x1000),
                                    COSIM_TABLE_OP_WRITE);
    CHECK(route == &map.entries[0]);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x1000), 16, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 0 && entry_count == 1);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x2000),
                                  COSIM_TABLE_OP_WRITE) == NULL);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x1000),
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);

    target.bar_index = 1;
    route = cosim_table_route_match(&map, &target, UINT64_C(0x4080),
                                    COSIM_TABLE_OP_WRITE);
    CHECK(route == &map.entries[1]);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x4080), 32, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 10 && entry_count == 1);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x4080), 96, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 10 && entry_count == 3);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x401f),
                                  COSIM_TABLE_OP_WRITE) == &map.entries[1]);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x4020),
                                  COSIM_TABLE_OP_WRITE) == NULL);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x4020), 32, &first_index,
                                  &entry_count) != 0);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x4fc0), 32, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 71 && entry_count == 1);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x4fc0), 64, &first_index,
                                  &entry_count) != 0);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x5000), 32, &first_index,
                                  &entry_count) != 0);

    route = cosim_table_route_match(&map, &target, UINT64_C(0x6100),
                                    COSIM_TABLE_OP_READ_DWORD);
    CHECK(route == &map.entries[2]);
    CHECK(cosim_table_route_slice(route, UINT64_C(0x6100), 128, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 34 && entry_count == 1);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x6ffc),
                                  COSIM_TABLE_OP_READ_DWORD) ==
          &map.entries[2]);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x7000),
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);

    target = make_target(1, 0, 0);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x1000),
                                  COSIM_TABLE_OP_WRITE) == NULL);
    target = make_target(0, 1, 0);
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x1000),
                                  COSIM_TABLE_OP_WRITE) == NULL);
    target = make_target(0, 0, 0);
    target.pf_index = 1;
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x1000),
                                  COSIM_TABLE_OP_WRITE) == NULL);
    target.pf_index = 0;
    target.target_type = COSIM_TABLE_TARGET_VF;
    CHECK(cosim_table_route_match(&map, &target, UINT64_C(0x1000),
                                  COSIM_TABLE_OP_WRITE) == NULL);

    cosim_table_route_free(&map);
    return 0;
}

static int test_read_dword_stays_inside_one_entry(void)
{
    cosim_table_route_entry_t route;
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    cosim_table_target_t target = make_target(0, 0, 0);

    map.entries = &route;
    map.count = 1;

    route = make_read_route(0, 128, 128, 128);
    CHECK(cosim_table_route_match(&map, &target, 1,
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);
    CHECK(cosim_table_route_match(&map, &target, 124,
                                  COSIM_TABLE_OP_READ_DWORD) == &route);

    route = make_read_route(0, 2, 2, 2);
    CHECK(cosim_table_route_match(&map, &target, 0,
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);

    route = make_read_route(0, 8, 6, 8);
    CHECK(cosim_table_route_match(&map, &target, 4,
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);

    route = make_read_route(0, 10, 4, 8);
    CHECK(cosim_table_route_match(&map, &target, 8,
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);
    return 0;
}

static int test_invalid_operations_fixture(void)
{
    const char *path = fixture_path("table_routes_invalid_operations.ini");
    char *line = NULL;
    size_t capacity = 0;
    unsigned int cases = 0;
    FILE *file;

    CHECK(path != NULL);
    file = fopen(path, "r");
    CHECK(file != NULL);
    while (getline(&line, &capacity, file) >= 0) {
        char config[1024];
        char *equals;
        char *newline;
        int length;

        newline = strpbrk(line, "\r\n");
        if (newline != NULL) {
            *newline = '\0';
        }
        if (line[0] == '\0' || line[0] == '#') {
            continue;
        }
        equals = strchr(line, '=');
        CHECK(equals != NULL);
        ++equals;
        length = snprintf(config, sizeof(config),
                          "[route.invalid]\n"
                          "rc=0\n"
                          "device=0\n"
                          "target=pf0\n"
                          "bar=0\n"
                          "start=0\n"
                          "end=16\n"
                          "entry_bytes=16\n"
                          "stride_bytes=16\n"
                          "index_base=0\n"
                          "handler=invalid\n"
                          "operations=%s\n",
                          equals);
        CHECK(length > 0 && length < (int)sizeof(config));
        CHECK(expect_invalid_text(config) == 0);
        ++cases;
    }
    free(line);
    CHECK(fclose(file) == 0);
    CHECK(cases == 5);
    return 0;
}

static int test_atomic_overlap_rejection(void)
{
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    cosim_table_route_entry_t *saved_entries;
    uint64_t saved_hash;
    size_t saved_count;
    char error[256] = {0};

    CHECK(cosim_table_route_load(fixture_path("table_routes_valid.ini"), &map,
                                 error, sizeof(error)) == 0);
    saved_entries = map.entries;
    saved_count = map.count;
    saved_hash = map.generation_hash;
    CHECK(cosim_table_route_load(fixture_path("table_routes_overlap.ini"),
                                 &map, error, sizeof(error)) != 0);
    CHECK(error[0] != '\0');
    CHECK(map.entries == saved_entries);
    CHECK(map.count == saved_count);
    CHECK(map.generation_hash == saved_hash);
    cosim_table_route_free(&map);
    return 0;
}

static int test_maximum_index_and_overflow(void)
{
    static const char valid[] =
        "[route.maximum]\n"
        "rc=0\n"
        "device=0\n"
        "target=pf0\n"
        "bar=0\n"
        "start=0\n"
        "end=32\n"
        "entry_bytes=16\n"
        "stride_bytes=16\n"
        "index_base=4294967294\n"
        "handler=maximum\n";
    static const char invalid[] =
        "[route.overflow]\n"
        "rc=0\n"
        "device=0\n"
        "target=pf0\n"
        "bar=0\n"
        "start=0\n"
        "end=48\n"
        "entry_bytes=16\n"
        "stride_bytes=16\n"
        "index_base=4294967294\n"
        "handler=overflow\n";
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    uint64_t first_index;
    uint32_t entry_count;
    char error[256] = {0};
    char path[128];

    CHECK(write_temp_file(valid, path, sizeof(path)) == 0);
    CHECK(cosim_table_route_load(path, &map, error, sizeof(error)) == 0);
    unlink(path);
    CHECK(cosim_table_route_slice(&map.entries[0], 0, 32, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == UINT32_MAX - UINT64_C(1));
    CHECK(entry_count == 2);
    CHECK(cosim_table_route_slice(&map.entries[0], 16, 16, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == UINT32_MAX);
    cosim_table_route_free(&map);
    CHECK(expect_invalid_text(invalid) == 0);
    return 0;
}

static int test_structural_validation(void)
{
    static const char *const invalid[] = {
        "[route.duplicate]\nrc=0\nrc=1\ndevice=0\ntarget=pf0\nbar=0\n"
        "start=0\nend=16\nentry_bytes=16\nstride_bytes=16\nindex_base=0\n"
        "handler=duplicate\n",
        "[route.unknown]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=0\n"
        "end=16\nentry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=unknown\n"
        "mystery=1\n",
        "[route.suffix]\nrc=0x0junk\ndevice=0\ntarget=pf0\nbar=0\nstart=0\n"
        "end=16\nentry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=suffix\n",
        "[route.pf1]\nrc=0\ndevice=0\ntarget=pf1\nbar=0\nstart=0\nend=16\n"
        "entry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=pf1\n",
        "[route.vf]\nrc=0\ndevice=0\ntarget=vf0\nbar=0\nstart=0\nend=16\n"
        "entry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=vf\n",
        "[route.bar]\nrc=0\ndevice=0\ntarget=pf0\nbar=2\nstart=0\nend=16\n"
        "entry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=bar\n",
        "[route.entry]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=0\nend=16\n"
        "entry_bytes=0\nstride_bytes=16\nindex_base=0\nhandler=entry\n",
        "[route.stride0]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=0\nend=16\n"
        "entry_bytes=16\nstride_bytes=0\nindex_base=0\nhandler=stride0\n",
        "[route.stride]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=0\nend=16\n"
        "entry_bytes=16\nstride_bytes=8\nindex_base=0\nhandler=stride\n",
        "[route.range]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=16\nend=16\n"
        "entry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=range\n",
        "[route.short]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=0\nend=8\n"
        "entry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=short\n",
        "[route.handler]\nrc=0\ndevice=0\ntarget=pf0\nbar=0\nstart=0\nend=16\n"
        "entry_bytes=16\nstride_bytes=16\nindex_base=0\nhandler=\n",
        "not-a-section\n",
    };
    size_t i;

    for (i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        CHECK(expect_invalid_text(invalid[i]) == 0);
    }
    return 0;
}

int main(void)
{
    CHECK(test_temp_file_cleanup_paths() == 0);
    CHECK(test_valid_operations_and_fixed_width_entries() == 0);
    CHECK(test_map_initialization_reload_and_free_contract() == 0);
    CHECK(test_matching_and_slicing() == 0);
    CHECK(test_read_dword_stays_inside_one_entry() == 0);
    CHECK(test_invalid_operations_fixture() == 0);
    CHECK(test_atomic_overlap_rejection() == 0);
    CHECK(test_maximum_index_and_overflow() == 0);
    CHECK(test_structural_validation() == 0);
    return 0;
}
