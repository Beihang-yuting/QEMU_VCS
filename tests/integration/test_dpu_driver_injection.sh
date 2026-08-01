#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
injector="${project_dir}/scripts/inject_driver_bundle.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-inject-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bundle="$work/bundle"
rootfs="$work/rootfs.ext4"
mkdir -p "$bundle"
printf 'test module\n' > "$bundle/dpu_snd1.ko"
printf 'ko_dir=cosim-drivers/dpu_snd1\nko_deps=bonding\nko_name=dpu_snd1.ko\nkver=6.8.0-107-generic\n' > "$bundle/driver.conf"
truncate -s 16M "$rootfs"
mke2fs -q -F -t ext4 "$rootfs"

# Imported projects are often operated by an unprivileged user.  The DPU
# injector must not depend on a writable system TMPDIR for either its staging
# tree or its debugfs command file.
TMPDIR="$work/missing-system-tmp" "$injector" --rootfs "$rootfs" --bundle "$bundle"
test -d "$project_dir/build/tmp"
debugfs -R 'stat /lib/modules/cosim-drivers/dpu_snd1/dpu_snd1.ko' "$rootfs" 2>/dev/null | grep -q 'Inode:'
debugfs -R "dump -p /etc/cosim/driver.conf $work/driver.conf" "$rootfs" >/dev/null 2>&1
grep -qx 'mode=custom' "$work/driver.conf"
grep -qx 'ko_deps=bonding' "$work/driver.conf"
grep -qx 'ko_name=dpu_snd1.ko' "$work/driver.conf"

debugfs -R "dump -p /etc/systemd/system/cosim-driver.service $work/cosim-driver.service" \
    "$rootfs" >/dev/null 2>&1
grep -qx 'ExecStart=/bin/sh /etc/cosim/load-custom-driver.sh' "$work/cosim-driver.service"
debugfs -R "dump -p /etc/cosim/load-custom-driver.sh $work/load-custom-driver.sh" \
    "$rootfs" >/dev/null 2>&1
grep -Fq 'modprobe "$dependency"' "$work/load-custom-driver.sh"
debugfs -R 'ls -l /etc/systemd/system/multi-user.target.wants' "$rootfs" 2>/dev/null | \
    grep -Eq '120777 .*cosim-driver\.service'

echo 'PASS: DPU driver bundle rootfs injection'
