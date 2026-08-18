#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

if ! command -v vcs >/dev/null 2>&1; then
    echo "FAIL: VCS is required for cosim table runtime tests" >&2
    exit 1
fi

dpi_source="$out_dir/cosim_table_runtime_dpi.c"
sed -n '/^COSIM_TABLE_RUNTIME_DPI_C_BEGIN$/,/^COSIM_TABLE_RUNTIME_DPI_C_END$/p' "$0" |
    sed '1d;$d' >"$dpi_source"
compile_log="$out_dir/compile.log"
disabled_log="$out_dir/disabled.log"
active_log="$out_dir/active.log"
map_file="$out_dir/routes.ini"
printf '[route.runtime]\nhandler=shared\n' >"$map_file"

(
    cd "$out_dir"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        "+incdir+$project_dir/vcs-tb" \
        -top test_cosim_table_runtime -o simv_runtime \
        "$project_dir/vcs-tb/cosim_table_pkg.sv" \
        "$project_dir/tests/sv/test_cosim_table_runtime.sv" \
        "$dpi_source" 2>&1 | tee "$compile_log"
    ./simv_runtime 2>&1 | tee "$disabled_log"
    ./simv_runtime +COSIM +COSIM_TABLE_ENABLE=1 \
        "+COSIM_TABLE_MAP=$map_file" +TABLE_PORT_BASE=10100 \
        +REMOTE_HOST=127.0.0.1 2>&1 | tee "$active_log"
)

grep -q '^COSIM_TABLE_RUNTIME: ALL PASS$' "$disabled_log"
grep -q '^TABLE_DPI_CALLS=0$' "$disabled_log"
grep -q '^COSIM_TABLE_RUNTIME: ALL PASS$' "$active_log"

# Compile the retained target-native integration filelist. It supplies the
# user's prerequisite VIP packages, while the cosim kit itself remains the two
# documented inputs: bridge_vcs.sv and cosim_xrc_pkg.sv.
bridge_archive="$out_dir/libcosim_bridge_runtime_test.a"
bridge_obj_dir="$out_dir/bridge-objects"
mkdir -p "$bridge_obj_dir"
bridge_sources=(
    bridge/vcs/bridge_vcs.c
    bridge/vcs/sock_sync_vcs.c
    bridge/common/shm_layout.c
    bridge/common/ring_buffer.c
    bridge/common/dma_manager.c
    bridge/common/trace_log.c
    bridge/common/transport_shm.c
    bridge/common/transport_tcp.c
    bridge/common/eth_shm.c
)
for source in "${bridge_sources[@]}"; do
    object="$bridge_obj_dir/$(basename "${source%.c}").o"
    gcc -std=c11 -D_DEFAULT_SOURCE -O0 -fPIC \
        -I"$project_dir/bridge/common" -I"$project_dir/bridge/vcs" \
        -I"$project_dir/bridge/qemu" -I"$project_dir/bridge/table" \
        -c "$project_dir/$source" -o "$object"
done
ar rcs "$bridge_archive" "$bridge_obj_dir"/*.o

gate_compile_log="$out_dir/gate-compile.log"
(
    cd "$project_dir"
    vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
        -Mdir="$out_dir/gate-csrc" -top pcie_tl_tb_top \
        -o "$out_dir/simv_gate" -f pcie_tl_vip/sim/filelist_cosim.f \
        "$dpi_source" \
        -LDFLAGS "-Wl,--whole-archive $bridge_archive -Wl,--no-whole-archive -lrt -lpthread" \
        2>&1 | tee "$gate_compile_log"
)

gate_log="$out_dir/gate.log"
set +e
"$out_dir/simv_gate" -exitstatus +UVM_TESTNAME=pcie_tl_cosim_test \
    +COSIM_TABLE_ENABLE=1 >"$gate_log" 2>&1
gate_status=$?
set -e
if (( gate_status == 0 )); then
    echo "FAIL: +COSIM_TABLE_ENABLE=1 without exact +COSIM did not fatal" >&2
    cat "$gate_log" >&2
    exit 1
fi
grep -q 'COSIM_TABLE_ENABLE=1 requires an exact +COSIM argument' "$gate_log"
grep -q '^TABLE_DPI_CALLS=0$' "$gate_log"

echo "COSIM_TABLE_RUNTIME_RUNNER: ALL PASS"
exit 0

: <<'COSIM_TABLE_RUNTIME_DPI_C_DOUBLE'
COSIM_TABLE_RUNTIME_DPI_C_BEGIN
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_RC 4

typedef struct {
    int phase;
    int fail_activate;
    int request_sent;
    int outstanding;
    int interrupted;
    int load_calls;
    int register_calls;
    int init_calls;
    int activate_calls;
    int interrupt_calls;
    int cleanup_calls;
    int order_errors;
} runtime_rc_state_t;

static runtime_rc_state_t states[MAX_RC];
static int total_calls;

static runtime_rc_state_t *state_for(int rc)
{
    if (rc < 0 || rc >= MAX_RC)
        return NULL;
    return &states[rc];
}

static void report_calls(void)
{
    printf("TABLE_DPI_CALLS=%d\n", total_calls);
    fflush(stdout);
}

__attribute__((constructor)) static void install_reporter(void)
{
    atexit(report_calls);
}

void table_runtime_test_reset(void)
{
    memset(states, 0, sizeof(states));
    total_calls = 0;
}

void table_runtime_test_fail_activate(int rc)
{
    runtime_rc_state_t *s = state_for(rc);
    if (s != NULL)
        s->fail_activate = 1;
}

int table_runtime_test_total_calls(void) { return total_calls; }
int table_runtime_test_load_calls(int rc) { return states[rc].load_calls; }
int table_runtime_test_register_calls(int rc) { return states[rc].register_calls; }
int table_runtime_test_init_calls(int rc) { return states[rc].init_calls; }
int table_runtime_test_activate_calls(int rc) { return states[rc].activate_calls; }
int table_runtime_test_interrupt_calls(int rc) { return states[rc].interrupt_calls; }
int table_runtime_test_cleanup_calls(int rc) { return states[rc].cleanup_calls; }
int table_runtime_test_order_errors(int rc) { return states[rc].order_errors; }

int table_vcs_load_routes_rc(int rc, const char *path)
{
    runtime_rc_state_t *s = state_for(rc);
    total_calls++;
    if (s == NULL)
        return -1;
    s->load_calls++;
    if (s->phase != 0 || path == NULL || path[0] != '/')
        s->order_errors++;
    s->phase = 1;
    return 0;
}

int table_vcs_register_handler_rc(int rc, const char *name, int supports_read)
{
    runtime_rc_state_t *s = state_for(rc);
    (void)supports_read;
    total_calls++;
    if (s == NULL)
        return -1;
    s->register_calls++;
    if (s->phase != 1 || name == NULL || name[0] == '\0')
        s->order_errors++;
    s->phase = 2;
    return 0;
}

int table_vcs_init_rc(int rc, const char *host, int port_base,
                      int instance_id, int timeout_ms)
{
    runtime_rc_state_t *s = state_for(rc);
    total_calls++;
    if (s == NULL)
        return -1;
    s->init_calls++;
    if (s->phase != 2 || host == NULL || strcmp(host, "127.0.0.1") != 0 ||
        port_base != 10100 || instance_id != rc || timeout_ms <= 0)
        s->order_errors++;
    s->phase = 3;
    return 0;
}

int table_vcs_activate_routes_rc(int rc)
{
    runtime_rc_state_t *s = state_for(rc);
    total_calls++;
    if (s == NULL)
        return -1;
    s->activate_calls++;
    if (s->phase != 3)
        s->order_errors++;
    if (s->fail_activate)
        return -1;
    s->phase = 4;
    return 0;
}

int table_vcs_poll_request_rc(int rc)
{
    runtime_rc_state_t *s = state_for(rc);
    total_calls++;
    if (s == NULL)
        return -1;
    if (s->phase != 4 || s->outstanding) {
        s->order_errors++;
        return -1;
    }
    if (s->interrupted)
        return -1;
    if (!s->request_sent) {
        s->request_sent = 1;
        s->outstanding = 1;
        return 1;
    }
    return 0;
}

int table_vcs_get_request_kind_rc(int rc) { total_calls++; (void)rc; return 1; }
const char *table_vcs_get_request_handler_rc(int rc) { total_calls++; (void)rc; return "shared"; }
int table_vcs_get_request_rc_id_rc(int rc) { total_calls++; return rc; }
int table_vcs_get_request_device_instance_rc(int rc) { total_calls++; (void)rc; return 0; }
int table_vcs_get_request_pci_domain_rc(int rc) { total_calls++; (void)rc; return 0; }
int table_vcs_get_request_target_bdf_rc(int rc) { total_calls++; (void)rc; return 0x18; }
int table_vcs_get_request_target_type_rc(int rc) { total_calls++; (void)rc; return 0; }
int table_vcs_get_request_pf_index_rc(int rc) { total_calls++; (void)rc; return 0; }
int table_vcs_get_request_vf_index_rc(int rc) { total_calls++; (void)rc; return 0; }
int table_vcs_get_request_bar_index_rc(int rc) { total_calls++; (void)rc; return 0; }
unsigned table_vcs_get_request_generation_rc(int rc) { total_calls++; (void)rc; return 1; }
unsigned table_vcs_get_request_route_id_rc(int rc) { total_calls++; return (unsigned)(100 + rc); }
uint64_t table_vcs_get_request_first_index_rc(int rc) { total_calls++; (void)rc; return 7; }
uint64_t table_vcs_get_request_bar_offset_rc(int rc) { total_calls++; (void)rc; return 0x70; }
unsigned table_vcs_get_request_entry_count_rc(int rc) { total_calls++; (void)rc; return 1; }
unsigned table_vcs_get_request_entry_bytes_rc(int rc) { total_calls++; (void)rc; return 16; }
unsigned table_vcs_get_request_payload_bytes_rc(int rc) { total_calls++; (void)rc; return 16; }
unsigned table_vcs_get_request_byte_offset_rc(int rc) { total_calls++; (void)rc; return 0; }
unsigned table_vcs_get_request_flags_rc(int rc) { total_calls++; (void)rc; return 0; }
uint64_t table_vcs_get_request_transaction_id_rc(int rc) { total_calls++; return (uint64_t)(0x100 + rc); }
uint64_t table_vcs_get_request_payload_u64_rc(int rc, unsigned word)
{
    total_calls++;
    return UINT64_C(0x0706050403020100) + ((uint64_t)word << 56) + (uint64_t)rc;
}

int table_vcs_complete_rc(int rc, int status, uint64_t failed_index,
                          unsigned committed, int handler_error,
                          unsigned read_data)
{
    runtime_rc_state_t *s = state_for(rc);
    (void)failed_index;
    (void)handler_error;
    (void)read_data;
    total_calls++;
    if (s == NULL)
        return -1;
    if (!s->outstanding || status != 0 || committed != 1)
        s->order_errors++;
    s->outstanding = 0;
    return 0;
}

void table_vcs_interrupt_rc(int rc)
{
    runtime_rc_state_t *s = state_for(rc);
    total_calls++;
    if (s == NULL)
        return;
    s->interrupt_calls++;
    s->interrupted = 1;
}

void table_vcs_cleanup_rc(int rc)
{
    runtime_rc_state_t *s = state_for(rc);
    total_calls++;
    if (s == NULL)
        return;
    s->cleanup_calls++;
    if (s->phase == 0)
        s->order_errors++;
    s->phase = 0;
}

/* bridge_vcs.sv retains optional ETH/virtqueue imports. They are deliberately
 * inert in this lifecycle-only executable. */
int vcs_eth_mac_init_dpi(void) { return 0; }
int vcs_eth_mac_send_frame_dpi(void) { return 0; }
int vcs_eth_mac_poll_frame_dpi(void) { return 0; }
void vcs_eth_mac_close_dpi(void) {}
int vcs_eth_mac_peer_ready_dpi(void) { return 0; }
void vcs_vq_configure(void) {}
int vcs_vq_process_tx(void) { return 0; }
int vcs_vq_process_rx(void) { return 0; }
int vcs_vq_get_tx_count(void) { return 0; }
int vcs_vq_get_rx_count(void) { return 0; }
COSIM_TABLE_RUNTIME_DPI_C_END
COSIM_TABLE_RUNTIME_DPI_C_DOUBLE
