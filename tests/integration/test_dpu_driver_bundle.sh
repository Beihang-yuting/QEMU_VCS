#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
builder="${project_dir}/scripts/build_dpu_driver_bundle.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-bundle-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/safe/host-driver-net"
printf 'obj-m += dpu_snd1.o\n' > "$work/safe/host-driver-net/Makefile"
tar -C "$work/safe" -czf "$work/safe.tar.gz" host-driver-net

tar -C "$work/safe" --transform='s,^host-driver-net/,../,' \
    -czf "$work/traversal.tar.gz" host-driver-net

"$builder" --validate-only --archive "$work/safe.tar.gz"
"$builder" --validate-only --use-system-bonding --archive "$work/safe.tar.gz"
if ! grep -Fq "dependencies=''" "$builder"; then
    echo 'FAIL: the no-LACP build must not declare a bonding dependency' >&2
    exit 1
fi
if ! grep -Fq "dependencies='bonding.ko'" "$builder"; then
    echo 'FAIL: the bundled-bonding build must retain its ordered dependency' >&2
    exit 1
fi
if "$builder" --validate-only --archive "$work/traversal.tar.gz"; then
    echo 'FAIL: traversal archive was accepted' >&2
    exit 1
fi

mkdir -p "$work/fake-headers/include/generated"
touch "$work/fake-headers/Makefile"
printf '#define UTS_RELEASE "6.8.0-test"\n' > "$work/fake-headers/include/generated/utsrelease.h"
if "$builder" --archive "$work/safe.tar.gz" \
        --kernel-build "$work/fake-headers" --output "$work/bundle" \
        --compat-runtime-deb "$work/missing-libc6.deb" >"$work/compat.err" 2>&1; then
    echo 'FAIL: missing compatibility runtime was accepted' >&2
    exit 1
fi
grep -Fq 'compatibility runtime archive not found' "$work/compat.err" || {
    echo 'FAIL: missing compatibility runtime did not produce a clear error' >&2
    exit 1
}

grep -Fq 'CUSTOM_DRIVER_COMPAT_RUNTIME_DEB' "$project_dir/setup.sh" || {
    echo 'FAIL: setup does not pass the optional compatibility runtime to the DPU builder' >&2
    exit 1
}

if ! grep -Fq "output directory is not empty" "$builder"; then
    echo "FAIL: DPU builder does not accept setup.sh empty mktemp output directories" >&2
    exit 1
fi
echo 'PASS: DPU driver archive validation'
