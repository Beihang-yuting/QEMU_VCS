#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/offline-custom-driver-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

test_project="$work/project"
mkdir -p "$test_project"
cp "$project_dir/setup.sh" "$test_project/setup.sh"
chmod +x "$test_project/setup.sh"

payload="$work/payload"
mkdir -p "$payload/custom-driver" "$payload/kheaders" \
    "$work/driver-source/host-driver-net" \
    "$work/header-pkg/usr/src/linux-headers-6.8.0-test" \
    "$work/header-pkg/DEBIAN" \
    "$work/header-pkg/usr/share/doc/linux-headers-6.8.0-test"
printf "obj-m += dpu_snd1.o\\n" > "$work/driver-source/host-driver-net/Makefile"
tar -C "$work/driver-source" -czf "$payload/custom-driver/host-driver-net-test.tar.gz" host-driver-net
printf "compatibility runtime fixture\\n" > "$payload/custom-driver/libc6_2.39-test_amd64.deb"
printf "all:\\n\\t@true\\n" > "$work/header-pkg/usr/src/linux-headers-6.8.0-test/Makefile"
printf "%s\\n" \
    "Package: linux-headers-6.8.0-test" \
    "Version: 1" \
    "Architecture: amd64" \
    "Maintainer: test <test@example.invalid>" \
    "Description: offline header fixture" \
    > "$work/header-pkg/DEBIAN/control"
dpkg-deb --build "$work/header-pkg" "$payload/kheaders/linux-headers-6.8.0-test_amd64.deb" >/dev/null

printf "%s\\n" \
    "OFFLINE_DATE=2026-07-30" \
    "OFFLINE_GUEST_TYPE=ubuntu" \
    "OFFLINE_KVER=6.8.0-test" \
    "OFFLINE_CUSTOM_DPU_ARCHIVE=host-driver-net-test.tar.gz" \
    "OFFLINE_CUSTOM_DPU_RUNTIME=libc6_2.39-test_amd64.deb" \
    > "$payload/offline-meta.env"
printf 'OFFLINE_DATE=$(touch "%s/metadata-was-executed")\n' "$work" >> "$payload/offline-meta.env"

archive="$work/offline-custom-driver.zip"
(cd "$payload" && zip -qr "$archive" .)

# Older offline packages recorded the packager's absolute ZIP path in their
# sidecar.  The package must still import after a transfer to another path.
md5sum "$archive" > "${archive}.md5"
relocated="$work/relocated"
mkdir -p "$relocated"
cp "$archive" "${archive}.md5" "$relocated/"
rm -f "$archive" "${archive}.md5"
archive="$relocated/$(basename "$archive")"

"$test_project/setup.sh" --driver custom --import "$archive" --import-only >"$work/import.log" 2>&1

test -f "$test_project/build/offline-custom-driver/host-driver-net-test.tar.gz"
test -f "$test_project/build/offline-custom-driver/libc6_2.39-test_amd64.deb"
test -f "$test_project/build/kheaders-6.8.0-test/usr/src/linux-headers-6.8.0-test/Makefile"
test ! -e "$work/metadata-was-executed"
grep -Fq "自定义 DPU 驱动素材已导入" "$work/import.log"
grep -Fq "Kernel headers 已解开" "$work/import.log"
grep -Fq "自定义驱动使用离线源码包" "$work/import.log"
grep -Fq "DPU 编译使用离线兼容运行库" "$work/import.log"

# A valid digest without the required filename field is not a md5sum sidecar.
malformed_archive="$work/malformed-checksum.zip"
cp "$archive" "$malformed_archive"
malformed_hash=$(md5sum "$malformed_archive" | awk '{ print $1 }')
printf '%s\n' "$malformed_hash" > "${malformed_archive}.md5"
if "$test_project/setup.sh" --driver custom --import "$malformed_archive" --import-only >"$work/malformed-import.log" 2>&1; then
    echo "FAIL: setup accepted an incomplete MD5 sidecar" >&2
    exit 1
fi
grep -Fq "MD5 校验失败" "$work/malformed-import.log"

# GNU md5sum accepts uppercase hexadecimal digest records; import must too.
uppercase_archive="$work/uppercase-checksum.zip"
cp "$archive" "$uppercase_archive"
uppercase_hash=$(md5sum "$uppercase_archive" | awk '{ print toupper($1) }')
printf '%s  %s\n' "$uppercase_hash" "$(basename "$uppercase_archive")" > "${uppercase_archive}.md5"
if ! "$test_project/setup.sh" --driver custom --import "$uppercase_archive" --import-only >"$work/uppercase-import.log" 2>&1; then
    cat "$work/uppercase-import.log" >&2
    exit 1
fi
grep -Fq "MD5 校验通过" "$work/uppercase-import.log"

grep -Fq -- "--custom-driver" "$project_dir/scripts/prepare-offline.sh"
grep -Fq -- "--compat-runtime-deb" "$project_dir/scripts/prepare-offline.sh"
if ! grep -Fq 'DRIVER_MODE" = "custom' "$project_dir/setup.sh"; then
    echo "FAIL: --qemu-src skip does not retain Guest work for a custom driver" >&2
    exit 1
fi
skip_policy=$(sed -n '/if \[ "${QEMU_SRC_OPT:-}" = "skip" \]; then/,/^fi/p' "$project_dir/setup.sh")
if ! printf "%s\\n" "$skip_policy" | grep -Fq 'DRIVER_MODE" = "custom'; then
    echo "FAIL: --qemu-src skip clears Guest work for custom drivers" >&2
    exit 1
fi

if ! grep -Fq '*/usr/src/linux-headers-${KVER}/Makefile' "$project_dir/scripts/build_cosim_nic.sh"; then
    echo "FAIL: cosim_nic header lookup can select documentation directories" >&2
    exit 1
fi

if ! grep -Fq '*/usr/src/linux-headers-${guest_kernel}/Makefile' "$project_dir/setup.sh"; then
    echo "FAIL: DPU bundle lookup can select documentation directories" >&2
    exit 1
fi

echo "PASS: offline custom DPU driver import"
