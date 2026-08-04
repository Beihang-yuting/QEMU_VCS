#!/usr/bin/env bash
# Ensure module injection writes a real directory hierarchy, not debugfs
# directory entries whose names contain literal slash characters.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo/scripts/inject-modules.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "[inject-modules-debugfs] FAIL: $*" >&2
    exit 1
}

base_dir="$tmp/base-dir"
module_dir="$tmp/module-dir"
base_image="$tmp/base.ext4"
output_image="$tmp/output.ext4"
modules_tar="$tmp/modules.tar.gz"
mkdir -p "$base_dir/etc" \
         "$module_dir/lib/modules/6.8.0-test/kernel/drivers/net/ethernet/intel/e1000e"
printf 'base rootfs\n' > "$base_dir/etc/issue"
printf 'test module\n' > "$module_dir/lib/modules/6.8.0-test/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst"
truncate -s 32M "$base_image"
mkfs.ext4 -q -F -d "$base_dir" "$base_image"
tar -C "$module_dir" -czf "$modules_tar" lib

MODULES_TAR="$modules_tar" SRC_ROOTFS="$base_image" DST_ROOTFS="$output_image" \
    bash "$script" unit-test >/dev/null

debugfs -R 'stat /lib/modules/6.8.0-test/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst' \
    "$output_image" 2>&1 | grep -q 'Inode:' || fail 'module is not reachable through its expected path'

if debugfs -R 'ls -p /' "$output_image" 2>/dev/null | \
        grep -Fq 'lib.modules.6.8.0-test.kernel.drivers.net.ethernet.intel.e1000e.e1000e.ko.zst'; then
    fail 'module was written as a literal slash-containing root entry'
fi

fsck_output="$(e2fsck -fn "$output_image" 2>&1 || true)"
if ! grep -q 'Pass 5: Checking group summary information' <<<"$fsck_output"; then
    fail 'filesystem cannot be checked after injection'
fi
if grep -q 'WARNING: Filesystem still has errors' <<<"$fsck_output"; then
    fail 'filesystem still has errors after injection'
fi

echo '[inject-modules-debugfs] PASS'
