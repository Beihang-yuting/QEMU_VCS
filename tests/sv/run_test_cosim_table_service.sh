#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

if ! command -v vcs >/dev/null 2>&1; then
    echo "FAIL: VCS is required for cosim table service tests" >&2
    exit 1
fi

dpi_source="$out_dir/cosim_table_service_dpi.c"
sed -n '/^COSIM_TABLE_DPI_C_BEGIN$/,/^COSIM_TABLE_DPI_C_END$/p' "$0" |
    sed '1d;$d' >"$dpi_source"
compile_log="$out_dir/compile.log"
simulation_log="$out_dir/simulation.log"

(
    cd "$out_dir"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        "+incdir+$project_dir/vcs-tb" \
        -top test_cosim_table_service -o simv \
        "$project_dir/vcs-tb/cosim_table_pkg.sv" \
        "$project_dir/tests/sv/test_cosim_table_service.sv" \
        "$dpi_source" 2>&1 | tee "$compile_log"
    ./simv +COSIM_TABLE_LOG=high +COSIM_TABLE_DUMP_LIMIT=8 \
        +COSIM_TABLE_PROTECT_table0=parity_even \
        2>&1 | tee "$simulation_log"
)

grep -q '^COSIM_TABLE_SERVICE: ALL PASS$' "$simulation_log"
grep -q 'COSIM_TABLE_HIGH.*rc=0' "$simulation_log"
grep -q 'route=77' "$simulation_log"
grep -q 'transaction=0x0000000000000111' "$simulation_log"
grep -q 'raw_bytes=00 01 02 03 04 05 06 07' "$simulation_log"
grep -q 'protection=parity_even' "$simulation_log"
grep -q 'handler_result=' "$simulation_log"
grep -q 'committed=1' "$simulation_log"
grep -q 'failed_index=0x0000000000000003' "$simulation_log"
grep -q 'accepted=3 entries=5 bytes=80 success=2 reads=1 errors=1' \
    "$simulation_log"
grep -q 'route=81.*handler=table0.*completion_status=9.*accepted=1 entries=0 bytes=0 success=0 reads=0 errors=1' \
    "$simulation_log"
grep -q 'route=82.*handler=missing.*completion_status=5.*accepted=1 entries=0 bytes=0 success=0 reads=0 errors=1' \
    "$simulation_log"
grep -q 'route=83.*handler=codec_table.*completion_status=5.*accepted=1 entries=0 bytes=0 success=0 reads=0 errors=1' \
    "$simulation_log"
grep -q 'route=84.*completion_status=0 completion_rc=-1.*accepted=1 entries=1 bytes=16 success=0 reads=0 errors=1' \
    "$simulation_log"
if grep -q 'raw_bytes=00 01 02 03 04 05 06 07 08' "$simulation_log"; then
    echo "FAIL: HIGH raw-byte dump exceeded +COSIM_TABLE_DUMP_LIMIT=8" >&2
    exit 1
fi

echo "COSIM_TABLE_SERVICE_RUNNER: ALL PASS"
exit 0

: <<'COSIM_TABLE_DPI_C_DOUBLE'
COSIM_TABLE_DPI_C_BEGIN
#include <stdint.h>
#include <string.h>

#define MAX_RC 4
#define MAX_COMPLETIONS 8
#define FAILED_NONE UINT64_C(0x00000000ffffffff)

typedef struct {
    int requires_read;
    int phase;
    int registered_supports_read;
    int request_slot;
    int outstanding;
    int interrupted;
    int completion_count;
    int completion_status[MAX_COMPLETIONS];
    uint64_t completion_failed[MAX_COMPLETIONS];
    unsigned completion_committed[MAX_COMPLETIONS];
    int completion_handler_error[MAX_COMPLETIONS];
    unsigned completion_read_data[MAX_COMPLETIONS];
    int cleanup_count;
    int order_errors;
    int scenario;
    int request_count;
    int poll_count;
    int interrupt_count;
} test_rc_state_t;

static test_rc_state_t states[MAX_RC];

void table_test_reset(int rc, int requires_read)
{
    if (rc < 0 || rc >= MAX_RC)
        return;
    memset(&states[rc], 0, sizeof(states[rc]));
    states[rc].requires_read = requires_read;
    states[rc].request_count = rc == 0 ? 3 : 0;
}

void table_test_set_scenario(int rc, int scenario)
{
    test_rc_state_t *s;
    if (rc < 0 || rc >= MAX_RC)
        return;
    s = &states[rc];
    s->scenario = scenario;
    if (scenario >= 1 && scenario <= 3)
        s->request_count = 1;
    else if (scenario == 4)
        s->request_count = 2;
    else if (scenario == 5)
        s->request_count = 0;
}

int table_vcs_load_routes_rc(int rc, const char *path)
{
    test_rc_state_t *s = &states[rc];
    if (s->phase != 0 || path == 0 || path[0] != '/')
        s->order_errors++;
    s->phase = 1;
    return 0;
}

int table_vcs_register_handler_rc(int rc, const char *name,
                                  int supports_read)
{
    test_rc_state_t *s = &states[rc];
    if (s->phase != 1 || name == 0 || name[0] == '\0')
        s->order_errors++;
    s->registered_supports_read = supports_read;
    s->phase = 2;
    return 0;
}

int table_vcs_init_rc(int rc, const char *host, int port_base,
                      int instance_id, int connect_timeout_ms)
{
    test_rc_state_t *s = &states[rc];
    if (s->phase != 2 || host == 0 || port_base != 10100 ||
        instance_id != rc || connect_timeout_ms <= 0)
        s->order_errors++;
    s->phase = 3;
    return 0;
}

int table_vcs_activate_routes_rc(int rc)
{
    test_rc_state_t *s = &states[rc];
    if (s->phase != 3)
        s->order_errors++;
    if (s->requires_read && !s->registered_supports_read)
        return -1;
    s->phase = 4;
    return 0;
}

int table_vcs_poll_request_rc(int rc)
{
    test_rc_state_t *s = &states[rc];
    if (s->phase != 4 || s->outstanding) {
        s->order_errors++;
        return -1;
    }
    s->poll_count++;
    if (s->scenario == 5) {
        /* WRITE_BEGIN is accepted; DATA remains pending until interrupt. */
        if (s->interrupted || s->poll_count > 1000)
            return -1;
        return 0;
    }
    if (s->interrupted || s->request_slot >= s->request_count)
        return -1;
    s->outstanding = 1;
    return 1;
}

int table_vcs_get_request_kind_rc(int rc)
{
    if (states[rc].scenario != 0)
        return 1;
    return states[rc].request_slot < 2 ? 1 : 2;
}

const char *table_vcs_get_request_handler_rc(int rc)
{
    if (states[rc].scenario == 2)
        return "missing";
    if (states[rc].scenario == 3)
        return "codec_table";
    return "table0";
}

int table_vcs_get_request_rc_id_rc(int rc) { return rc; }
int table_vcs_get_request_device_instance_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_pci_domain_rc(int rc) { (void)rc; return 2; }
int table_vcs_get_request_target_bdf_rc(int rc) { (void)rc; return 0x18; }
int table_vcs_get_request_target_type_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_pf_index_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_vf_index_rc(int rc) { (void)rc; return 0; }
int table_vcs_get_request_bar_index_rc(int rc) { (void)rc; return 1; }
unsigned table_vcs_get_request_generation_rc(int rc) { (void)rc; return 9; }
unsigned table_vcs_get_request_route_id_rc(int rc)
{
    return states[rc].scenario == 0 ? 77U : 80U + states[rc].scenario;
}
uint64_t table_vcs_get_request_first_index_rc(int rc)
{
    if (states[rc].scenario != 0)
        return 2;
    return states[rc].request_slot < 2 ? 2 : 4;
}
uint64_t table_vcs_get_request_bar_offset_rc(int rc)
{
    if (states[rc].scenario != 0)
        return UINT64_C(0x200);
    return states[rc].request_slot < 2 ? UINT64_C(0x200) : UINT64_C(0x408);
}
unsigned table_vcs_get_request_entry_count_rc(int rc)
{
    if (states[rc].scenario == 1)
        return 3U;
    if (states[rc].scenario != 0)
        return 1U;
    return states[rc].request_slot < 2 ? 3U : 1U;
}
unsigned table_vcs_get_request_entry_bytes_rc(int rc) { (void)rc; return 16; }
unsigned table_vcs_get_request_payload_bytes_rc(int rc)
{
    if (states[rc].scenario == 1)
        return 47U;
    if (states[rc].scenario != 0)
        return 16U;
    return states[rc].request_slot < 2 ? 48U : 0U;
}
unsigned table_vcs_get_request_byte_offset_rc(int rc)
{
    return states[rc].request_slot < 2 ? 0U : 8U;
}
unsigned table_vcs_get_request_flags_rc(int rc) { (void)rc; return 0; }
uint64_t table_vcs_get_request_transaction_id_rc(int rc)
{
    static const uint64_t transactions[] = {UINT64_C(0x111),
                                             UINT64_C(0x222),
                                             UINT64_C(0x333)};
    if (states[rc].scenario != 0)
        return UINT64_C(0x400) + (unsigned)states[rc].scenario;
    return transactions[states[rc].request_slot];
}
uint64_t table_vcs_get_request_payload_u64_rc(int rc, unsigned word)
{
    uint64_t value = 0;
    unsigned base = states[rc].scenario != 0 ? 0x40U :
                    (states[rc].request_slot == 0 ? 0U : 0x80U);
    unsigned byte_index;
    if ((states[rc].scenario == 0 && states[rc].request_slot >= 2) ||
        word >= 6)
        return 0;
    for (byte_index = 0; byte_index < 8; byte_index++)
        value |= (uint64_t)((base + word * 8 + byte_index) & 0xffU)
                 << (byte_index * 8);
    return value;
}

int table_vcs_complete_rc(int rc, int status, uint64_t failed_index,
                          unsigned committed, int handler_error,
                          unsigned read_data)
{
    test_rc_state_t *s = &states[rc];
    int slot = s->completion_count;
    if (!s->outstanding || slot >= MAX_COMPLETIONS) {
        s->order_errors++;
        return -1;
    }
    s->completion_status[slot] = status;
    s->completion_failed[slot] = failed_index;
    s->completion_committed[slot] = committed;
    s->completion_handler_error[slot] = handler_error;
    s->completion_read_data[slot] = read_data;
    s->completion_count++;
    s->request_slot++;
    s->outstanding = 0;
    return s->scenario == 4 ? -1 : 0;
}

void table_vcs_interrupt_rc(int rc)
{
    states[rc].interrupt_count++;
    states[rc].interrupted = 1;
}

void table_vcs_cleanup_rc(int rc)
{
    test_rc_state_t *s = &states[rc];
    if (s->outstanding)
        s->order_errors++;
    s->cleanup_count++;
    s->phase = 0;
}

int table_test_get_completion_count(int rc) { return states[rc].completion_count; }
int table_test_get_completion_status(int rc, int slot)
{ return states[rc].completion_status[slot]; }
uint64_t table_test_get_completion_failed_index(int rc, int slot)
{ return states[rc].completion_failed[slot]; }
unsigned table_test_get_completion_committed(int rc, int slot)
{ return states[rc].completion_committed[slot]; }
int table_test_get_completion_handler_error(int rc, int slot)
{ return states[rc].completion_handler_error[slot]; }
unsigned table_test_get_completion_read_data(int rc, int slot)
{ return states[rc].completion_read_data[slot]; }
int table_test_get_cleanup_count(int rc) { return states[rc].cleanup_count; }
int table_test_get_order_errors(int rc) { return states[rc].order_errors; }
int table_test_get_poll_count(int rc) { return states[rc].poll_count; }
int table_test_get_interrupt_count(int rc) { return states[rc].interrupt_count; }
COSIM_TABLE_DPI_C_END
COSIM_TABLE_DPI_C_DOUBLE
