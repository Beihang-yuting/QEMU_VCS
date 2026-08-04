#!/usr/bin/env bash
# Inject a validated custom-driver bundle into one Guest image.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(dirname "$script_dir")

bundle=''
rootfs=''
initramfs=''

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bundle) bundle=${2:?--bundle requires a directory}; shift 2 ;;
        --rootfs) rootfs=${2:?--rootfs requires a path}; shift 2 ;;
        --initramfs) initramfs=${2:?--initramfs requires a path}; shift 2 ;;
        -h|--help)
            echo 'Usage: inject_driver_bundle.sh --bundle DIR (--rootfs IMAGE | --initramfs IMAGE)'
            exit 0
            ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ -d "$bundle" ] || fail "bundle directory not found: ${bundle:-<unset>}"
[ -f "$bundle/dpu_snd1.ko" ] || fail 'bundle is missing dpu_snd1.ko'
[ -f "$bundle/driver.conf" ] || fail 'bundle is missing driver.conf'
[ -n "$rootfs$initramfs" ] || fail 'specify --rootfs or --initramfs'
[ -z "$rootfs" ] || [ -z "$initramfs" ] || fail 'choose only one image type'

ko_dir=''
ko_deps=''
ko_name=''
kver=''
while IFS='=' read -r key value; do
    case "$key" in
        ko_dir) ko_dir=$value ;;
        ko_deps) ko_deps=$value ;;
        ko_name) ko_name=$value ;;
        kver) kver=$value ;;
        '') ;;
        *) fail "unknown bundle manifest key: $key" ;;
    esac
done < "$bundle/driver.conf"

case "$ko_dir" in ''|/*|*'..'*) fail "unsafe ko_dir: ${ko_dir:-<unset>}" ;; esac
case "$ko_name" in ''|*'/'*|*'..'*) fail "unsafe ko_name: ${ko_name:-<unset>}" ;; esac
[ "$ko_name" = 'dpu_snd1.ko' ] || fail "unexpected primary module: $ko_name"
[ -n "$kver" ] || fail 'bundle manifest has no kver'

# Keep custom-driver staging inside the imported project.  System /tmp can be
# unavailable to the non-root user that performs offline setup.
driver_tmp_root="${DPU_DRIVER_TMPDIR:-${project_dir}/build/tmp}"
mkdir -p "$driver_tmp_root" || fail "cannot create DPU temporary directory: $driver_tmp_root"
[ -w "$driver_tmp_root" ] || fail "DPU temporary directory is not writable: $driver_tmp_root"
stage=$(mktemp -d "${driver_tmp_root%/}/dpu-driver-inject.XXXXXX")
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
mkdir -p "$stage/lib/modules/$ko_dir" "$stage/etc/cosim" "$stage/etc/local.d" \
    "$stage/etc/systemd/system/multi-user.target.wants"
cp "$bundle/dpu_snd1.ko" "$stage/lib/modules/$ko_dir/$ko_name"
if [ -f "$bundle/bonding.ko" ]; then
    cp "$bundle/bonding.ko" "$stage/lib/modules/$ko_dir/bonding.ko"
fi
printf 'mode=custom\nko_dir=%s\nko_deps=%s\nko_name=%s\nkver=%s\n' \
    "$ko_dir" "$ko_deps" "$ko_name" "$kver" > "$stage/etc/cosim/driver.conf"
printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '. /etc/cosim/driver.conf' \
    '[ "${mode:-}" = custom ] || exit 0' \
    'module_dir="/lib/modules/${ko_dir}"' \
    '[ -d "$module_dir" ] || exit 1' \
    'for dependency in ${ko_deps:-}; do' \
    '    if [ -f "$module_dir/$dependency" ]; then' \
    '        /sbin/insmod "$module_dir/$dependency"' \
    '    else' \
    '        /sbin/modprobe "$dependency"' \
    '    fi' \
    'done' \
    'exec /sbin/insmod "$module_dir/$ko_name"' \
    > "$stage/etc/cosim/load-custom-driver.sh"
printf '%s\n' \
    '[Unit]' \
    'Description=Load the CoSim custom DPU driver' \
    'After=systemd-modules-load.service' \
    'Before=network-pre.target' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'ExecStart=/bin/sh /etc/cosim/load-custom-driver.sh' \
    'RemainAfterExit=yes' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    > "$stage/etc/systemd/system/cosim-driver.service"

if [ -n "$rootfs" ]; then
    [ -f "$rootfs" ] || fail "rootfs not found: $rootfs"
    command -v debugfs >/dev/null 2>&1 || fail 'debugfs is required for rootfs injection'
    commands=$(mktemp "${driver_tmp_root%/}/dpu-driver-debugfs.XXXXXX")
    trap 'rm -f "$commands"; cleanup' EXIT
    (
        cd "$stage"
        find . -type d | sort | while IFS= read -r dir; do
            [ "$dir" = '.' ] || printf 'mkdir %s\n' "${dir#./}"
        done
        find . -type f | sort | while IFS= read -r file; do
            relative=${file#./}
            destination_dir=$(dirname "$relative")
            destination_name=$(basename "$relative")
            printf 'cd /%s\n' "$destination_dir"
            printf 'write %s/%s %s\n' "$stage" "$relative" "$destination_name"
            printf 'cd /\n'
        done
        printf 'symlink /etc/systemd/system/multi-user.target.wants/cosim-driver.service '
        printf '../cosim-driver.service\n'
    ) > "$commands"
    debugfs -w -f "$commands" "$rootfs" >/dev/null 2>&1
    echo "injected custom bundle into rootfs: $rootfs"
else
    [ -f "$initramfs" ] || fail "initramfs not found: $initramfs"
    (
        cd "$stage"
        find . -print | cpio -o -H newc 2>/dev/null | gzip
    ) >> "$initramfs"
    echo "injected custom bundle into initramfs: $initramfs"
fi
