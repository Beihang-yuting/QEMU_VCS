#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

fail() {
    echo "[qemu-table-setup] FAIL: $*" >&2
    exit 1
}

[[ -f "$repo/qemu-plugin/cosim_table_ctrl.c" ]] ||
    fail "missing qemu-plugin/cosim_table_ctrl.c"
[[ -f "$repo/qemu-plugin/cosim_table_ctrl.h" ]] ||
    fail "missing qemu-plugin/cosim_table_ctrl.h"
grep -Fq 's->rc_id != s->instance_id' \
    "$repo/qemu-plugin/cosim_table_ctrl.c" ||
    fail "endpoint must reject an RC identity different from instance_id"
grep -Fq 's->device_instance != 0' \
    "$repo/qemu-plugin/cosim_table_ctrl.c" ||
    fail "endpoint must reject unsupported nonzero device identity"

extract_setup_injection() {
    awk '
        $0 == "    if [ \"$NEED_QEMU\" = true ] && [ -d \"$QEMU_DIR\" ]; then" {
            starts++
            active = 1
            next
        }
        active && /# ---- 应用 QEMU patch/ {
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

populate_project() {
    local project=$1

    mkdir -p "$project/qemu-plugin" "$project/bridge/table" \
        "$project/bridge/qemu" "$project/bridge/common"
    cp "$repo/qemu-plugin/cosim_pcie_rc.c" \
       "$repo/qemu-plugin/cosim_pcie_rc.h" \
       "$repo/qemu-plugin/cosim_mmio_be.h" \
       "$repo/qemu-plugin/cosim_pcie_request.h" \
       "$repo/qemu-plugin/cosim_table_ctrl.c" \
       "$repo/qemu-plugin/cosim_table_ctrl.h" \
       "$project/qemu-plugin/"
    cp "$repo/bridge/common/cosim_topology.h" "$project/bridge/common/"
    cp "$repo/bridge/table/"*.h "$project/bridge/table/"
    cp "$repo/bridge/qemu/"table_*.h "$project/bridge/qemu/"
}

verify_injection() {
    local project=$1
    local qemu=$2
    local source target

    cmp -s "$project/qemu-plugin/cosim_table_ctrl.c" \
        "$qemu/hw/net/cosim_table_ctrl.c" ||
        fail "cosim_table_ctrl.c was not copied"
    cmp -s "$project/qemu-plugin/cosim_table_ctrl.h" \
        "$qemu/include/hw/net/cosim_table_ctrl.h" ||
        fail "cosim_table_ctrl.h was not copied"
    for source in "$project/bridge/table/"*.h \
                  "$project/bridge/qemu/"table_*.h; do
        target="$qemu/include/hw/net/$(basename "$source")"
        cmp -s "$source" "$target" ||
            fail "$(basename "$source") was not copied"
    done
    [[ $(grep -Fxc "system_ss.add(files('cosim_table_ctrl.c'))" \
        "$qemu/hw/net/meson.build") -eq 1 ]] ||
        fail "cosim_table_ctrl.c meson registration is not idempotent"
}

run_make_injection() {
    local root=$1
    local project="$root/project"
    local qemu="$root/qemu"
    local body

    populate_project "$project"
    mkdir -p "$qemu/hw/net" "$qemu/include/hw/net" "$qemu/build" \
        "$root/bin"
    printf "system_ss.add(files('cosim_pcie_rc.c'))\n" >"$qemu/hw/net/meson.build"
    printf '# fixture\n' >"$qemu/build/build.ninja"
    printf '#!/bin/sh\nexit 0\n' >"$root/bin/ninja"
    chmod +x "$root/bin/ninja"
    body=$(sed -n '/^qemu-device:/,/^# host_mem/p' "$repo/Makefile")
    {
        printf 'PROJECT_DIR := %s\n' "$project"
        printf 'QEMU_SRC_DIR := %s\n' "$qemu"
        printf 'QEMU_BUILD := %s\n' "$qemu/build"
        printf '.PHONY: bridge qemu-device\nbridge:\n\t@:\n'
        printf '%s\n' "$body"
    } >"$root/Makefile"
    PATH="$root/bin:$PATH" make --no-print-directory -f "$root/Makefile" \
        qemu-device >/dev/null
    PATH="$root/bin:$PATH" make --no-print-directory -f "$root/Makefile" \
        qemu-device >/dev/null
    verify_injection "$project" "$qemu"
}

run_setup_injection() {
    local root=$1
    local project="$root/project"
    local qemu="$root/qemu"
    local body

    populate_project "$project"
    mkdir -p "$qemu/hw/net" "$qemu/include/hw/net"
    printf "system_ss.add(files('cosim_pcie_rc.c'))\n" >"$qemu/hw/net/meson.build"
    body=$(extract_setup_injection) || fail "cannot extract setup injection"
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'info() { :; }\nok() { :; }\n'
        printf '%s\n' "$body"
    } >"$root/inject.sh"
    PROJECT_DIR="$project" QEMU_DIR="$qemu" bash "$root/inject.sh"
    PROJECT_DIR="$project" QEMU_DIR="$qemu" bash "$root/inject.sh"
    verify_injection "$project" "$qemu"
}

temp_root=$(mktemp -d /tmp/qemu-table-setup.XXXXXX)
trap 'rm -rf -- "$temp_root"' EXIT
mkdir -p "$temp_root/make" "$temp_root/setup"
run_make_injection "$temp_root/make"
run_setup_injection "$temp_root/setup"

echo "[qemu-table-setup] PASS"
