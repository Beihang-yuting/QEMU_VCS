#!/usr/bin/env bash
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mode=${1:-}
bridge_so=${2:-}
cc=${CC:-cc}
nm_tool=${NM:-nm}

fail() {
    echo "[qemu-table-target-closure] FAIL: $*" >&2
    return 1
}

extract_setup_injection() {
    awk '
        $0 == "    if [ \"$NEED_QEMU\" = true ] && [ -d \"$QEMU_DIR\" ]; then" {
            starts++
            active = 1
            next
        }
        active && $0 == "        MESON_FILE=\"${QEMU_DIR}/hw/net/meson.build\"" {
            ends++
            active = 0
            next
        }
        active { print }
        END {
            if (starts != 1 || ends != 1 || active)
                exit 1
        }
    ' "$repo/setup.sh"
}

populate_project_fixture() {
    local project=$1

    mkdir -p "$project/qemu-plugin" "$project/bridge/common" \
        "$project/bridge/qemu" "$project/bridge/table" || return
    cp "$repo/qemu-plugin/cosim_pcie_rc.c" \
        "$repo/qemu-plugin/cosim_pcie_rc.h" \
        "$repo/qemu-plugin/cosim_mmio_be.h" \
        "$repo/qemu-plugin/cosim_pcie_request.h" \
        "$project/qemu-plugin/" || return
    cp "$repo/bridge/common/cosim_topology.h" \
        "$project/bridge/common/" || return
    cp "$repo/bridge/qemu/table_target.h" \
        "$project/bridge/qemu/" || return
    cp "$repo/bridge/table/cosim_table_protocol.h" \
        "$project/bridge/table/" || return
}

compile_installed_header() {
    local qemu_tree=$1
    local work=$2

    cat >"$work/header_probe.c" <<'EOF'
#include "hw/net/table_target.h"

int main(void)
{
    cosim_table_target_snapshot_t snapshot = {0};
    return (int)snapshot.generation;
}
EOF
    if ! "$cc" -std=c11 -Wall -Wextra -Werror \
            -I"$qemu_tree/include" -c "$work/header_probe.c" \
            -o "$work/header_probe.o" >"$work/header_probe.log" 2>&1; then
        cat "$work/header_probe.log" >&2
        return 1
    fi
}

check_configured_extra_cflags() {
    local work=$1
    local configured
    local -a flags

    configured=$(sed -n \
        's/.*--extra-cflags="\([^"]*\)".*/\1/p' "$repo/setup.sh")
    [[ $(printf '%s\n' "$configured" | sed '/^$/d' | wc -l) -eq 1 ]] ||
        return 1
    configured=${configured//\$\{PROJECT_DIR\}/$repo}
    read -r -a flags <<<"$configured"
    cat >"$work/configured_flags_probe.c" <<'EOF'
#include "table_target.h"

cosim_table_target_snapshot_t configured_flags_snapshot;
EOF
    if ! "$cc" -std=c11 -Wall -Wextra -Werror "${flags[@]}" \
            -c "$work/configured_flags_probe.c" \
            -o "$work/configured_flags_probe.o" \
            >"$work/configured_flags_probe.log" 2>&1; then
        cat "$work/configured_flags_probe.log" >&2
        return 1
    fi
}

check_make_injection() {
    local root=$1
    local project="$root/project"
    local qemu_tree="$root/qemu"
    local makefile="$root/Makefile"
    local ninja_stub="$root/bin/ninja"
    local qemu_body

    populate_project_fixture "$project" || return
    mkdir -p "$qemu_tree/hw/net" "$qemu_tree/include/hw/net" \
        "$qemu_tree/build" "$root/bin" || return
    printf '# fixture\n' >"$qemu_tree/build/build.ninja"
    printf '#!/bin/sh\nexit 0\n' >"$ninja_stub"
    chmod +x "$ninja_stub"
    qemu_body=$(sed -n '/^qemu-device:/,/^# host_mem/p' "$repo/Makefile")
    {
        printf 'PROJECT_DIR := %s\n' "$project"
        printf 'QEMU_SRC_DIR := %s\n' "$qemu_tree"
        printf 'QEMU_BUILD := %s\n' "$qemu_tree/build"
        printf '.PHONY: bridge qemu-device\n'
        printf 'bridge:\n\t@:\n'
        printf '%s\n' "$qemu_body"
    } >"$makefile"
    PATH="$root/bin:$PATH" make --no-print-directory -f "$makefile" \
        qemu-device >"$root/make.log" 2>&1 || return
    compile_installed_header "$qemu_tree" "$root"
}

check_setup_injection() {
    local root=$1
    local project="$root/project"
    local qemu_tree="$root/qemu"
    local setup_body

    populate_project_fixture "$project" || return
    mkdir -p "$qemu_tree/hw/net" "$qemu_tree/include/hw/net" || return
    setup_body=$(extract_setup_injection) || return
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'info() { :; }\n'
        printf '%s\n' "$setup_body"
    } >"$root/inject.sh"
    PROJECT_DIR="$project" QEMU_DIR="$qemu_tree" \
        bash "$root/inject.sh" >"$root/setup.log" 2>&1 || return
    compile_installed_header "$qemu_tree" "$root"
}

check_headers() {
    local temp_root
    local failures=0

    temp_root=$(mktemp -d /tmp/qemu-table-target-headers.XXXXXX) || return
    mkdir -p "$temp_root/flags" "$temp_root/make" "$temp_root/setup"

    check_configured_extra_cflags "$temp_root/flags" || {
        fail "configured QEMU extra-cflags cannot compile table_target.h"
        failures=$((failures + 1))
    }
    check_make_injection "$temp_root/make" || {
        fail "make qemu-device does not install a compilable table target header closure"
        failures=$((failures + 1))
    }
    check_setup_injection "$temp_root/setup" || {
        fail "setup.sh does not install a compilable table target header closure"
        failures=$((failures + 1))
    }
    rm -rf -- "$temp_root"
    ((failures == 0))
}

check_link() {
    local temp_root
    local bridge_dir
    local symbol

    if [[ ! -f "$bridge_so" ]]; then
        fail "missing CMake bridge shared library: $bridge_so"
        return 1
    fi
    bridge_dir=$(dirname "$bridge_so")
    for symbol in cosim_table_target_snapshot_valid cosim_table_target_matches; do
        if ! "$nm_tool" -D --defined-only "$bridge_so" |
                awk -v expected="$symbol" '$3 == expected { found = 1 }
                    END { exit !found }'; then
            fail "$bridge_so does not export $symbol"
            return 1
        fi
    done

    temp_root=$(mktemp -d /tmp/qemu-table-target-link.XXXXXX) || return
    cat >"$temp_root/link_probe.c" <<'EOF'
#include "table_target.h"

int main(void)
{
    cosim_table_target_snapshot_t snapshot = { .generation = 1,
                                                .bar_sizes = { 1 } };
    cosim_table_target_t target = {0};

    if (!cosim_table_target_snapshot_valid(&snapshot))
        return 1;
    return cosim_table_target_matches(&snapshot, &target) != 0;
}
EOF
    if ! "$cc" -std=c11 -Wall -Wextra -Werror \
        -I"$repo/bridge/qemu" -I"$repo/bridge/table" \
        "$temp_root/link_probe.c" -L"$bridge_dir" \
        -Wl,-rpath,"$bridge_dir" -lcosim_bridge \
        -o "$temp_root/link_probe"; then
        rm -rf -- "$temp_root"
        return 1
    fi
    if ! "$temp_root/link_probe"; then
        rm -rf -- "$temp_root"
        return 1
    fi
    rm -rf -- "$temp_root"
}

case "$mode" in
    headers)
        check_headers || exit 1
        ;;
    link)
        check_link || exit 1
        ;;
    *)
        echo "usage: $0 headers | link LIBCOSIM_BRIDGE_SO" >&2
        exit 2
        ;;
esac

echo "[qemu-table-target-closure] PASS: $mode"
