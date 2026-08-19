#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
handler_file="$project_dir/vcs-tb/examples/vio_notify_mock_handler.sv"
map_file="$project_dir/vcs-tb/examples/table_routes.ini"
missing=()

[[ -r "$handler_file" ]] || missing+=("vcs-tb/examples/vio_notify_mock_handler.sv")
[[ -r "$map_file" ]] || missing+=("vcs-tb/examples/table_routes.ini")
if (( ${#missing[@]} != 0 )); then
    echo "FAIL: Task 15 reference handler/routes absent: ${missing[*]}" >&2
    exit 1
fi

if ! command -v vcs >/dev/null 2>&1; then
    echo "FAIL: VCS is required for cosim table multi-RAM tests" >&2
    exit 1
fi

out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

route_check_source="$out_dir/cosim_table_multiram_route_check.c"
sed -n '/^COSIM_TABLE_MULTIRAM_ROUTE_CHECK_BEGIN$/,/^COSIM_TABLE_MULTIRAM_ROUTE_CHECK_END$/p' "$0" |
    sed '1d;$d' >"$route_check_source"
gcc -std=c11 -Wall -Wextra -Werror \
    -I"$project_dir/bridge/table" \
    "$route_check_source" "$project_dir/bridge/table/cosim_table_route.c" \
    -o "$out_dir/route_check"
"$out_dir/route_check" "$map_file"

dpi_source="$out_dir/cosim_table_multiram_dpi.c"
sed -n '/^COSIM_TABLE_MULTIRAM_DPI_C_BEGIN$/,/^COSIM_TABLE_MULTIRAM_DPI_C_END$/p' "$0" |
    sed '1d;$d' >"$dpi_source"
compile_log="$out_dir/compile.log"

(
    cd "$out_dir"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        "+incdir+$project_dir/vcs-tb" \
        -top test_cosim_table_multiram -o simv \
        "$project_dir/vcs-tb/cosim_table_pkg.sv" \
        "$handler_file" \
        "$project_dir/tests/sv/test_cosim_table_multiram.sv" \
        "$dpi_source" 2>&1 | tee "$compile_log"
)

for protection in none parity_even secded; do
    simulation_log="$out_dir/simulation-$protection.log"
    (
        cd "$out_dir"
        ./simv +COSIM_TABLE_LOG=high \
            "+MULTIRAM_MAP=$map_file" \
            "+COSIM_TABLE_PROTECT_vio_notify=$protection" \
            2>&1 | tee "$simulation_log"
    )

    grep -q '^COSIM_TABLE_MULTIRAM: ALL PASS$' "$simulation_log"
    grep -q "handler=vio_notify index=0 raw_bytes=00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f protection=$protection" \
        "$simulation_log"
    grep -q "handler=vio_notify index=15 raw_bytes=20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f protection=$protection" \
        "$simulation_log"
    grep -q "handler=vio_notify index=255 raw_bytes=40 41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f protection=$protection" \
        "$simulation_log"
    grep -q "COSIM_TABLE_MOCK_HIGH handler=vio_notify logical_index=255 protection=$protection final_protected_value=0x" \
        "$simulation_log"
    grep -q 'handler=vio_notify logical_index=0 destination=l3 bank=0 ram_index=0' \
        "$simulation_log"
    grep -q 'handler=vio_notify logical_index=15 destination=l3 bank=3 ram_index=3' \
        "$simulation_log"
    grep -q 'handler=vio_notify logical_index=15 destination=l2 bank=0 ram_index=0' \
        "$simulation_log"
    grep -q 'handler=vio_notify logical_index=255 destination=l3 bank=3 ram_index=63' \
        "$simulation_log"
    grep -q 'handler=vio_notify logical_index=255 destination=l2 bank=3 ram_index=3' \
        "$simulation_log"
    grep -q 'handler=vio_notify logical_index=255 destination=l1 bank=0 ram_index=0' \
        "$simulation_log"
    grep -q 'handler=flat_table logical_index=7 read_byte_offset=4 read_data=0x87868584' \
        "$simulation_log"
    if grep -Eq 'UVM_(ERROR|FATAL)[[:space:]]*:[[:space:]]*[1-9]' \
        "$simulation_log"; then
        echo "FAIL: UVM error/fatal found in $protection run" >&2
        exit 1
    fi
done

echo "COSIM_TABLE_MULTIRAM_RUNNER: ALL PASS"
exit 0

: <<'COSIM_TABLE_MULTIRAM_ROUTE_CHECK'
COSIM_TABLE_MULTIRAM_ROUTE_CHECK_BEGIN
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cosim_table_route.h"

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "route check failed at line %d: %s\n",           \
                    __LINE__, #condition);                                     \
            cosim_table_route_free(&map);                                      \
            return 1;                                                          \
        }                                                                      \
    } while (0)

int main(int argc, char **argv)
{
    cosim_table_route_map_t map = COSIM_TABLE_ROUTE_MAP_INIT;
    cosim_table_target_t target = {0};
    const cosim_table_route_entry_t *route;
    uint64_t first_index;
    uint32_t entry_count;
    char error[256] = {0};

    if (argc != 2) {
        fprintf(stderr, "usage: %s routes.ini\n", argv[0]);
        return 2;
    }
    if (cosim_table_route_load(argv[1], &map, error, sizeof(error)) != 0) {
        fprintf(stderr, "route load failed: %s\n", error);
        return 1;
    }

    CHECK(map.count == 3);
    CHECK(strcmp((const char *)map.entries[0].handler_name,
                 "vio_notify") == 0);
    CHECK(strlen((const char *)map.entries[0].handler_name) <
          COSIM_TABLE_HANDLER_NAME_BYTES);
    CHECK(cosim_table_le32_to_cpu(map.entries[0].operation_mask) ==
          COSIM_TABLE_OP_WRITE);
    CHECK(map.entries[0].target.target_type == COSIM_TABLE_TARGET_PF);
    CHECK(map.entries[0].target.pf_index == 0);
    CHECK(map.entries[0].target.bar_index == 0);
    CHECK(cosim_table_le64_to_cpu(map.entries[0].start_offset) == 0x1000);
    CHECK(cosim_table_le64_to_cpu(map.entries[0].end_offset) == 0x1100);

    CHECK(strcmp((const char *)map.entries[1].handler_name,
                 "vio_notify") == 0);
    CHECK(cosim_table_le32_to_cpu(map.entries[1].operation_mask) ==
          COSIM_TABLE_OP_WRITE);
    CHECK(map.entries[1].target.bar_index == 0);
    CHECK(cosim_table_le64_to_cpu(map.entries[1].start_offset) == 0x2000);
    CHECK(cosim_table_le64_to_cpu(map.entries[1].end_offset) == 0x2010);
    CHECK(cosim_table_le32_to_cpu(map.entries[1].index_base) == 255);

    CHECK(strcmp((const char *)map.entries[2].handler_name,
                 "flat_table") == 0);
    CHECK(strlen((const char *)map.entries[2].handler_name) <
          COSIM_TABLE_HANDLER_NAME_BYTES);
    CHECK(cosim_table_le32_to_cpu(map.entries[2].operation_mask) ==
          (COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD));
    CHECK(map.entries[2].target.target_type == COSIM_TABLE_TARGET_PF);
    CHECK(map.entries[2].target.pf_index == 0);
    CHECK(map.entries[2].target.bar_index == 1);

    target.rc_id = cosim_table_cpu_to_le16(0);
    target.device_instance = cosim_table_cpu_to_le16(0);
    target.target_type = COSIM_TABLE_TARGET_PF;
    target.pf_index = 0;
    target.bar_index = 0;
    route = cosim_table_route_match(&map, &target, 0x1000,
                                    COSIM_TABLE_OP_WRITE);
    CHECK(route == &map.entries[0]);
    CHECK(cosim_table_route_match(&map, &target, 0x1000,
                                  COSIM_TABLE_OP_READ_DWORD) == NULL);
    CHECK(cosim_table_route_slice(route, 0x10f0, 16, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 15 && entry_count == 1);

    route = cosim_table_route_match(&map, &target, 0x2000,
                                    COSIM_TABLE_OP_WRITE);
    CHECK(route == &map.entries[1]);
    CHECK(cosim_table_route_slice(route, 0x2000, 16, &first_index,
                                  &entry_count) == 0);
    CHECK(first_index == 255 && entry_count == 1);

    target.bar_index = 1;
    route = cosim_table_route_match(&map, &target, 0x3074,
                                    COSIM_TABLE_OP_READ_DWORD);
    CHECK(route == &map.entries[2]);

    cosim_table_route_free(&map);
    puts("COSIM_TABLE_MULTIRAM_ROUTES: ALL PASS");
    return 0;
}
COSIM_TABLE_MULTIRAM_ROUTE_CHECK_END
COSIM_TABLE_MULTIRAM_ROUTE_CHECK

: <<'COSIM_TABLE_MULTIRAM_DPI_C_DOUBLE'
COSIM_TABLE_MULTIRAM_DPI_C_BEGIN
#include <stdint.h>
#include <string.h>

#define REQUEST_COUNT 5
#define FAILED_NONE UINT64_C(0x00000000ffffffff)

typedef struct {
    int phase;
    int register_calls;
    int request_slot;
    int outstanding;
    int completion_count;
    int completion_failures;
    uint32_t read_data;
    int order_errors;
} multiram_state_t;

static multiram_state_t state;

void multiram_test_reset(void)
{
    memset(&state, 0, sizeof(state));
}

int multiram_test_completion_count(void) { return state.completion_count; }
int multiram_test_completion_failures(void)
{
    return state.completion_failures;
}
uint32_t multiram_test_read_data(void) { return state.read_data; }
int multiram_test_order_errors(void) { return state.order_errors; }

int table_vcs_load_routes_rc(int rc, const char *path)
{
    size_t length;

    if (state.phase != 0 || rc != 0 || path == NULL || path[0] != '/')
        state.order_errors++;
    length = path == NULL ? 0 : strlen(path);
    if (length < strlen("/vcs-tb/examples/table_routes.ini") ||
        strcmp(path + length - strlen("/vcs-tb/examples/table_routes.ini"),
               "/vcs-tb/examples/table_routes.ini") != 0)
        state.order_errors++;
    state.phase = 1;
    return 0;
}

int table_vcs_register_handler_rc(int rc, const char *name, int supports_read)
{
    const char *expected_name = state.register_calls == 0
        ? "vio_notify" : "flat_table";
    int expected_read = state.register_calls == 0 ? 0 : 1;

    if (state.phase != 1 || rc != 0 || state.register_calls >= 2 ||
        name == NULL || strcmp(name, expected_name) != 0 ||
        supports_read != expected_read)
        state.order_errors++;
    state.register_calls++;
    return 0;
}

int table_vcs_init_rc(int rc, const char *host, int port_base,
                      int instance_id, int connect_timeout_ms)
{
    if (state.phase != 1 || state.register_calls != 2 || rc != 0 ||
        host == NULL || strcmp(host, "127.0.0.1") != 0 ||
        port_base != 10100 || instance_id != 0 || connect_timeout_ms <= 0)
        state.order_errors++;
    state.phase = 2;
    return 0;
}

int table_vcs_activate_routes_rc(int rc)
{
    if (state.phase != 2 || rc != 0)
        state.order_errors++;
    state.phase = 3;
    return 0;
}

int table_vcs_poll_request_rc(int rc)
{
    if (state.phase != 3 || rc != 0 || state.outstanding)
        state.order_errors++;
    if (state.request_slot >= REQUEST_COUNT)
        return -1;
    state.outstanding = 1;
    return 1;
}

int table_vcs_get_request_kind_rc(int rc)
{
    (void)rc;
    return state.request_slot == 4 ? 2 : 1;
}

const char *table_vcs_get_request_handler_rc(int rc)
{
    (void)rc;
    return state.request_slot < 3 ? "vio_notify" : "flat_table";
}

int table_vcs_get_request_rc_id_rc(int rc) { return rc; }
int table_vcs_get_request_device_instance_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_pci_domain_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_target_bdf_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_target_type_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_pf_index_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_vf_index_rc(int rc) { (void)rc; return 0xffff; }
int table_vcs_get_request_bar_index_rc(int rc)
{
    (void)rc;
    return state.request_slot < 3 ? 0 : 1;
}
uint32_t table_vcs_get_request_generation_rc(int rc) { (void)rc; return 9; }
uint32_t table_vcs_get_request_route_id_rc(int rc)
{
    (void)rc;
    if (state.request_slot < 2)
        return 0;
    if (state.request_slot == 2)
        return 1;
    return 2;
}
uint64_t table_vcs_get_request_first_index_rc(int rc)
{
    static const uint64_t indices[REQUEST_COUNT] = {0, 15, 255, 7, 7};
    (void)rc;
    return indices[state.request_slot];
}
uint64_t table_vcs_get_request_bar_offset_rc(int rc)
{
    static const uint64_t offsets[REQUEST_COUNT] = {
        0x1000, 0x10f0, 0x2000, 0x3070, 0x3074
    };
    (void)rc;
    return offsets[state.request_slot];
}
uint32_t table_vcs_get_request_entry_count_rc(int rc)
{
    (void)rc;
    return 1;
}
uint32_t table_vcs_get_request_entry_bytes_rc(int rc)
{
    (void)rc;
    return 16;
}
uint32_t table_vcs_get_request_payload_bytes_rc(int rc)
{
    (void)rc;
    return state.request_slot == 4 ? 0 : 16;
}
uint32_t table_vcs_get_request_byte_offset_rc(int rc)
{
    (void)rc;
    return state.request_slot == 4 ? 4 : 0;
}
uint32_t table_vcs_get_request_flags_rc(int rc) { (void)rc; return 0; }
uint64_t table_vcs_get_request_transaction_id_rc(int rc)
{
    (void)rc;
    return UINT64_C(0x1000) + (uint64_t)state.request_slot;
}
uint64_t table_vcs_get_request_payload_u64_rc(int rc, uint32_t word)
{
    static const uint8_t bases[4] = {0x00, 0x20, 0x40, 0x80};
    uint64_t value = 0;
    unsigned int i;

    (void)rc;
    if (state.request_slot >= 4 || word >= 2)
        return 0;
    for (i = 0; i < 8; ++i)
        value |= (uint64_t)(uint8_t)(bases[state.request_slot] + word * 8 + i)
                 << (i * 8);
    return value;
}

int table_vcs_complete_rc(int rc, int status, uint64_t failed_index,
                          uint32_t committed, int handler_error,
                          uint32_t read_data)
{
    int is_read = state.request_slot == 4;

    if (rc != 0 || !state.outstanding)
        state.order_errors++;
    if (status != 0 || failed_index != FAILED_NONE || handler_error != 0 ||
        committed != (uint32_t)(is_read ? 0 : 1) ||
        read_data != (is_read ? UINT32_C(0x87868584) : 0))
        state.completion_failures++;
    if (is_read)
        state.read_data = read_data;
    state.completion_count++;
    state.request_slot++;
    state.outstanding = 0;
    return 0;
}

void table_vcs_interrupt_rc(int rc)
{
    if (rc != 0)
        state.order_errors++;
}

void table_vcs_cleanup_rc(int rc)
{
    if (rc != 0 || state.phase != 3 || state.request_slot != REQUEST_COUNT ||
        state.outstanding)
        state.order_errors++;
    state.phase = 4;
}
COSIM_TABLE_MULTIRAM_DPI_C_END
COSIM_TABLE_MULTIRAM_DPI_C_DOUBLE
