#!/usr/bin/env bash
# Build the supplied DPU driver archive for one exact Guest kernel.
set -euo pipefail

archive=''
kernel_build=''
output=''
compat_runtime_deb=''
validate_only=false
use_system_bonding=false

usage() {
    cat <<'USAGE'
Usage:
  build_dpu_driver_bundle.sh --validate-only --archive ARCHIVE.tar.gz
  build_dpu_driver_bundle.sh --archive ARCHIVE.tar.gz \
      --kernel-build LINUX_HEADERS --output OUTPUT_DIR [--use-system-bonding]
      --compat-runtime-deb NOBLE_LIBC6.deb enables Ubuntu 20.04 host compatibility
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --archive) archive=${2:?--archive requires a path}; shift 2 ;;
        --kernel-build) kernel_build=${2:?--kernel-build requires a path}; shift 2 ;;
        --output) output=${2:?--output requires a path}; shift 2 ;;
        --compat-runtime-deb) compat_runtime_deb=${2:?--compat-runtime-deb requires a path}; shift 2 ;;
        --validate-only) validate_only=true; shift ;;
        --use-system-bonding) use_system_bonding=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ -n "$archive" ] && [ -f "$archive" ] || fail "archive not found: ${archive:-<unset>}"

validate_archive() {
    local entry normalized root
    local seen=false
    while IFS= read -r entry; do
        normalized=${entry#./}
        [ -n "$normalized" ] || continue
        case "$normalized" in
            /*|..|../*|*/../*|*/..)
                fail "unsafe archive entry: $entry"
                ;;
        esac
        root=${normalized%%/*}
        [ "$root" = 'host-driver-net' ] || fail "unexpected archive root: $entry"
        seen=true
    done < <(tar -tzf "$archive")
    "$seen" || fail 'archive is empty'
}

validate_archive
if "$validate_only"; then
    echo "validated archive: $archive"
    exit 0
fi

[ -n "$kernel_build" ] && [ -f "$kernel_build/Makefile" ] || \
    fail "kernel build directory is invalid: ${kernel_build:-<unset>}"
[ -n "$output" ] || fail '--output is required when building'
if [ -e "$output" ]; then
    [ -d "$output" ] || fail "output path exists and is not a directory: $output"
    if find "$output" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        fail "output directory is not empty: $output"
    fi
fi

utsrelease="$kernel_build/include/generated/utsrelease.h"
[ -f "$utsrelease" ] || fail "missing UTS release: $utsrelease"
kver=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$utsrelease")
[ -n "$kver" ] || fail "cannot parse UTS release: $utsrelease"

if [ -n "$compat_runtime_deb" ] && [ ! -f "$compat_runtime_deb" ]; then
    fail "compatibility runtime archive not found: $compat_runtime_deb"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-driver-build.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

tar -xzf "$archive" -C "$work" --no-same-owner --no-same-permissions
driver_dir="$work/host-driver-net"
[ -f "$driver_dir/Makefile" ] || fail 'driver archive has no Makefile'

compiler="${CC:-gcc}"
command -v "$compiler" >/dev/null 2>&1 || fail "C compiler not found: $compiler"

driver_cflags="${CFLAGS:-}"
if "$use_system_bonding"; then
    driver_cflags="${driver_cflags} -UDPU_LACP"
fi

if [ -n "$compat_runtime_deb" ]; then
    command -v dpkg-deb >/dev/null 2>&1 || fail 'dpkg-deb is required for compatibility mode'

    runtime_root="$work/compat-runtime"
    dpkg-deb -x "$compat_runtime_deb" "$runtime_root"
    runtime_libdir="$runtime_root/usr/lib/x86_64-linux-gnu"
    runtime_loader="$runtime_libdir/ld-linux-x86-64.so.2"
    if [ ! -x "$runtime_loader" ] || [ ! -f "$runtime_libdir/libc.so.6" ]; then
        fail 'compatibility runtime must be an amd64 Ubuntu/Debian libc6 package'
    fi
    if ! grep -aFq 'GLIBC_2.38' "$runtime_libdir/libc.so.6"; then
        fail 'compatibility runtime must provide GLIBC_2.38 or newer'
    fi

    # Ubuntu splits generated headers and common sources into siblings. Clone
    # their parent so every relative symlink remains valid in the private copy.
    compat_source_root="$work/kheaders"
    mkdir -p "$compat_source_root"
    cp -al "$(dirname "$kernel_build")/." "$compat_source_root/"
    kernel_build="$compat_source_root/$(basename "$kernel_build")"

    export COSIM_DPU_LOADER="$runtime_loader"
    export COSIM_DPU_LIBRARY_PATH="$runtime_libdir:/lib/x86_64-linux-gnu"
    for host_tool in scripts/basic/fixdep scripts/mod/modpost tools/objtool/objtool; do
        if [ ! -f "$kernel_build/$host_tool" ]; then
            fail "compatibility kernel headers are missing host tool: $host_tool"
        fi
        mv "$kernel_build/$host_tool" "$kernel_build/$host_tool.real"
        printf '%s\n%s\n' '#!/bin/sh' 'exec "$COSIM_DPU_LOADER" --library-path "$COSIM_DPU_LIBRARY_PATH" "$0.real" "$@"' > "$kernel_build/$host_tool"
        chmod +x "$kernel_build/$host_tool"
    done

    compat_compiler="$work/gcc-compat"
    export COSIM_DPU_COMPILER="$compiler"
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'args=()' 'for arg in "$@"; do' '    case "$arg" in' '        -mharden-sls=all|-ftrivial-auto-var-init=zero|-fzero-call-used-regs=used-gpr) ;;' '        *) args+=("$arg") ;;' '    esac' 'done' 'exec "$COSIM_DPU_COMPILER" "${args[@]}"' > "$compat_compiler"
    chmod +x "$compat_compiler"
    compiler="$compat_compiler"
fi
make -C "$driver_dir" KERNELDIR="$kernel_build" CC="$compiler" clean
make -C "$driver_dir" KERNELDIR="$kernel_build" CC="$compiler" \
    CFLAGS="$driver_cflags" modules

primary="$driver_dir/dpu_snd1.ko"
dependency="$driver_dir/bonding/bonding.ko"
[ -f "$primary" ] || fail 'build did not produce dpu_snd1.ko'
if ! "$use_system_bonding"; then
    [ -f "$dependency" ] || fail 'build did not produce bonding/bonding.ko'
fi

modules=("$primary")
if ! "$use_system_bonding"; then
    modules+=("$dependency")
fi
for module in "${modules[@]}"; do
    file "$module" | grep -q 'x86-64' || fail "module is not x86-64: $module"
    vermagic=$(modinfo -F vermagic "$module")
    case "$vermagic" in
        "$kver"' '*) ;;
        *) fail "vermagic mismatch for $module: expected $kver, got ${vermagic:-<empty>}" ;;
    esac
done

mkdir -p "$output"
cp "$primary" "$output/dpu_snd1.ko"
if "$use_system_bonding"; then
    dependencies=''
else
    cp "$dependency" "$output/bonding.ko"
    dependencies='bonding.ko'
fi
printf 'ko_dir=cosim-drivers/dpu_snd1\nko_deps=%s\nko_name=dpu_snd1.ko\nkver=%s\n' \
    "$dependencies" "$kver" \
    > "$output/driver.conf"

echo "built DPU driver bundle: $output"
[ -z "$compat_runtime_deb" ] || [ -f "$compat_runtime_deb" ] || \
    fail "compatibility runtime archive not found: $compat_runtime_deb"
