#!/usr/bin/env bash
# Ensure module injection writes a real directory hierarchy, not debugfs
# directory entries whose names contain literal slash characters.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/build/tmp"
tmp="$(mktemp -d "$repo/build/tmp/test-inject-modules.XXXXXX")"
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
fixture_project="$tmp/project"
fixture_bin="$tmp/fake-bin"
inject_log="$tmp/inject.log"
script="$fixture_project/scripts/inject-modules.sh"
mkdir -p "$base_dir/etc" \
         "$module_dir/lib/modules/6.8.0-test/kernel/drivers/net/ethernet/intel/e1000e" \
         "$fixture_project/scripts" "$fixture_project/build/tmp" \
         "$fixture_bin"
cp "$repo/scripts/inject-modules.sh" "$script"
chmod 0755 "$script"
printf 'base rootfs\n' > "$base_dir/etc/issue"
printf 'test module\n' > "$module_dir/lib/modules/6.8.0-test/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst"
truncate -s 32M "$base_image"
mkfs.ext4 -q -F -d "$base_dir" "$base_image"
tar -C "$module_dir" -czf "$modules_tar" lib

real_debugfs="$(command -v debugfs)"
real_e2fsck="$(command -v e2fsck)"
real_mktemp="$(command -v mktemp)"
expected_build_tmp="$fixture_project/build/tmp"
export INJECT_LOG="$inject_log" REAL_DEBUGFS="$real_debugfs" \
    REAL_E2FSCK="$real_e2fsck" REAL_MKTEMP="$real_mktemp" \
    EXPECTED_BUILD_TMP="$expected_build_tmp"

cat >"$fixture_bin/debugfs" <<'DEBUGFS_SHIM'
#!/usr/bin/env bash
set -euo pipefail
event=debugfs-read
for argument in "$@"; do
    [[ "$argument" == -w ]] && event=debugfs-write
done
printf '%s\n' "$event" >>"${INJECT_LOG}"
exec "${REAL_DEBUGFS}" "$@"
DEBUGFS_SHIM

cat >"$fixture_bin/e2fsck" <<'E2FSCK_SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'e2fsck\n' >>"${INJECT_LOG}"
exec "${REAL_E2FSCK}" "$@"
E2FSCK_SHIM

cat >"$fixture_bin/file" <<'FILE_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${@: -1}
if grep -Fq 'DYNAMIC-FIXTURE' "$target"; then
    printf '%s: ELF fixture executable, dynamically linked\n' "$target"
else
    printf '%s: ELF fixture executable, statically linked\n' "$target"
fi
FILE_SHIM

cat >"$fixture_bin/mktemp" <<'MKTEMP_SHIM'
#!/usr/bin/env bash
set -euo pipefail
template=${@: -1}
case "$template" in
    "${EXPECTED_BUILD_TMP}/inject-modules."*|\
    "${EXPECTED_BUILD_TMP}/inject-modules-debugfs."*) ;;
    *)
        printf 'mktemp-outside-build:%s\n' "$template" >>"${INJECT_LOG}"
        exit 91
        ;;
esac
printf 'mktemp:%s\n' "$template" >>"${INJECT_LOG}"
created="$("${REAL_MKTEMP}" "$@")"
if [[ "${1:-}" == -d ]]; then
    [[ "$(stat -c '%a' "$created")" == 700 ]] || exit 92
else
    [[ "$(stat -c '%a' "$created")" == 600 ]] || exit 93
fi
printf '%s\n' "$created"
MKTEMP_SHIM

cat >"$fixture_project/scripts/install_guest_debugutils.sh" <<'INSTALL_SHIM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 && "$1" == --rootfs && "$3" == --bin-dir ]] || exit 81
[[ "$2" == "${EXPECTED_ROOTFS}" ]] || exit 82
[[ "$4" == "${EXPECTED_BIN_DIR}" ]] || exit 83
for utility in pci_debug reg_display; do
    [[ -x "$4/$utility" ]] || exit 84
done
printf 'install\n' >>"${INJECT_LOG}"
exit "${INSTALL_RESULT:-0}"
INSTALL_SHIM

cat >"$fixture_project/scripts/build_dpu_debugutils.sh" <<'BUILD_SHIM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 1 && "$1" == "${EXPECTED_BIN_DIR}" ]] || exit 85
printf 'build\n' >>"${INJECT_LOG}"
build_result=${BUILD_RESULT:-0}
(( build_result == 0 )) || exit "$build_result"
mkdir -p "$1"
case "${BUILD_OUTPUT_KIND:-valid}" in
    pci-directory)
        mkdir -p "$1/pci_debug"
        printf '#!/bin/sh\nexit 0\n' >"$1/reg_display"
        chmod 0755 "$1/reg_display"
        ;;
    pci-symlink)
        printf '#!/bin/sh\nexit 0\n' >"$1/reg_display"
        chmod 0755 "$1/reg_display"
        ln -s "$1/reg_display" "$1/pci_debug"
        ;;
    pci-fifo)
        mkfifo "$1/pci_debug"
        chmod 0755 "$1/pci_debug"
        printf '#!/bin/sh\nexit 0\n' >"$1/reg_display"
        chmod 0755 "$1/reg_display"
        ;;
    pci-nonexec)
        printf '#!/bin/sh\nexit 0\n' >"$1/pci_debug"
        chmod 0644 "$1/pci_debug"
        printf '#!/bin/sh\nexit 0\n' >"$1/reg_display"
        chmod 0755 "$1/reg_display"
        ;;
    pci-dynamic)
        printf '#!/bin/sh\n# DYNAMIC-FIXTURE\nexit 0\n' >"$1/pci_debug"
        chmod 0755 "$1/pci_debug"
        printf '#!/bin/sh\nexit 0\n' >"$1/reg_display"
        chmod 0755 "$1/reg_display"
        ;;
    valid)
        for utility in pci_debug reg_display; do
            printf '#!/bin/sh\nexit 0\n' >"$1/$utility"
            chmod 0755 "$1/$utility"
        done
        ;;
    *) exit 86 ;;
esac
BUILD_SHIM
chmod 0755 "$fixture_bin/debugfs" "$fixture_bin/e2fsck" "$fixture_bin/file" \
    "$fixture_bin/mktemp" \
    "$fixture_project/scripts/install_guest_debugutils.sh" \
    "$fixture_project/scripts/build_dpu_debugutils.sh"

run_inject() {
    PATH="$fixture_bin:$PATH" \
        MODULES_TAR="$modules_tar" \
        SRC_ROOTFS="$base_image" \
        DST_ROOTFS="$output_image" \
        EXPECTED_ROOTFS="$output_image" \
        EXPECTED_BIN_DIR="$fixture_project/build/guest_tools/dpu-debugutils" \
        BUILD_RESULT="${BUILD_RESULT:-0}" \
        BUILD_OUTPUT_KIND="${BUILD_OUTPUT_KIND:-valid}" \
        bash "$script" unit-test
}

# A missing toolchain must be prepared before the destination is copied or
# resized.  Build failure must preserve both absent and existing destinations.
: >"$inject_log"
rm -f "$output_image"
set +e
BUILD_RESULT=44 run_inject >"$tmp/build-failure-absent.stdout" \
    2>"$tmp/build-failure-absent.stderr"
build_absent_status=$?
set -e
[[ "$build_absent_status" -eq 44 ]] ||
    fail "debug utility build failure was not propagated before injection: $build_absent_status"
[[ ! -e "$output_image" ]] ||
    fail 'debug utility build failure created the destination image'

printf 'existing destination must stay unchanged\n' >"$output_image"
existing_output_before="$(sha256sum "$output_image")"
set +e
BUILD_RESULT=44 run_inject >"$tmp/build-failure-existing.stdout" \
    2>"$tmp/build-failure-existing.stderr"
build_existing_status=$?
set -e
[[ "$build_existing_status" -eq 44 ]] ||
    fail "existing-image build failure status changed: $build_existing_status"
[[ "$(sha256sum "$output_image")" == "$existing_output_before" ]] ||
    fail 'debug utility build failure modified the existing destination image'

# An apparently successful helper may still produce a directory where a
# binary is required.  Reject it before copying, truncating, or opening DST.
rm -rf "$fixture_project/build/guest_tools"
printf 'directory artifact must not mutate destination\n' >"$output_image"
directory_output_before="$(sha256sum "$output_image")"
: >"$inject_log"
set +e
BUILD_OUTPUT_KIND=pci-directory run_inject \
    >"$tmp/directory-artifact.stdout" 2>"$tmp/directory-artifact.stderr"
directory_artifact_status=$?
set -e
[[ "$directory_artifact_status" -ne 0 ]] ||
    fail 'module injector accepted a debug utility directory'
[[ "$(sha256sum "$output_image")" == "$directory_output_before" ]] ||
    fail 'debug utility directory modified the destination image'
if grep -Eq '^(debugfs-write|install)$' "$inject_log"; then
    fail 'debug utility directory reached a destination mutation helper'
fi

# A pre-existing binary symlink is unsafe even if the helper could replace it:
# invoking the helper may follow the link and modify data outside its output.
rm -rf "$fixture_project/build/guest_tools"
mkdir -p "$fixture_project/build/guest_tools/dpu-debugutils"
printf 'outside debug target must remain unchanged\n' >"$tmp/outside-pci"
chmod 0755 "$tmp/outside-pci"
outside_pci_before="$(sha256sum "$tmp/outside-pci")"
ln -s "$tmp/outside-pci" \
    "$fixture_project/build/guest_tools/dpu-debugutils/pci_debug"
printf '#!/bin/sh\nexit 0\n' \
    >"$fixture_project/build/guest_tools/dpu-debugutils/reg_display"
chmod 0755 "$fixture_project/build/guest_tools/dpu-debugutils/reg_display"
printf 'binary symlink must not mutate destination\n' >"$output_image"
symlink_output_before="$(sha256sum "$output_image")"
: >"$inject_log"
set +e
run_inject >"$tmp/binary-symlink.stdout" 2>"$tmp/binary-symlink.stderr"
binary_symlink_status=$?
set -e
[[ "$binary_symlink_status" -ne 0 ]] ||
    fail 'module injector accepted a debug utility symlink'
[[ "$(sha256sum "$output_image")" == "$symlink_output_before" ]] ||
    fail 'debug utility symlink modified the destination image'
[[ "$(sha256sum "$tmp/outside-pci")" == "$outside_pci_before" ]] ||
    fail 'debug utility helper followed a pre-existing output symlink'
if grep -Eq '^(build|debugfs-write|install)$' "$inject_log"; then
    fail 'debug utility symlink reached a build or destination mutation helper'
fi

# A symlink in the fixed output directory chain is a canonical escape and is
# rejected before trusting binaries or invoking any helper.
rm -rf "$fixture_project/build/guest_tools"
mkdir -p "$tmp/escaped-guest-tools/dpu-debugutils"
for utility in pci_debug reg_display; do
    printf '#!/bin/sh\nexit 0\n' \
        >"$tmp/escaped-guest-tools/dpu-debugutils/$utility"
    chmod 0755 "$tmp/escaped-guest-tools/dpu-debugutils/$utility"
done
ln -s "$tmp/escaped-guest-tools" "$fixture_project/build/guest_tools"
printf 'canonical escape must not mutate destination\n' >"$output_image"
escape_output_before="$(sha256sum "$output_image")"
: >"$inject_log"
set +e
run_inject >"$tmp/canonical-escape.stdout" 2>"$tmp/canonical-escape.stderr"
canonical_escape_status=$?
set -e
[[ "$canonical_escape_status" -ne 0 ]] ||
    fail 'module injector accepted a symlinked debug output directory'
[[ "$(sha256sum "$output_image")" == "$escape_output_before" ]] ||
    fail 'canonical debug output escape modified the destination image'
[[ ! -s "$inject_log" ]] ||
    fail 'canonical debug output escape reached a helper'

# Revalidate every helper result before touching DST_ROOTFS.  This covers
# symlinks, non-regular files, permissions, and the static-link requirement
# shared with stage_guest_debugutils.sh.
assert_invalid_helper_output() {
    local output_kind=$1
    local description=$2
    local before
    local status

    rm -rf "$fixture_project/build/guest_tools"
    printf '%s must not mutate destination\n' "$description" >"$output_image"
    before="$(sha256sum "$output_image")"
    : >"$inject_log"
    set +e
    BUILD_OUTPUT_KIND="$output_kind" run_inject \
        >"$tmp/${output_kind}.stdout" 2>"$tmp/${output_kind}.stderr"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] ||
        fail "module injector accepted $description"
    [[ "$(sha256sum "$output_image")" == "$before" ]] ||
        fail "$description modified the destination image"
    if grep -Eq '^(debugfs-write|install)$' "$inject_log"; then
        fail "$description reached a destination mutation helper"
    fi
}

assert_invalid_helper_output pci-symlink 'a helper-produced symlink'
assert_invalid_helper_output pci-fifo 'a helper-produced FIFO'
assert_invalid_helper_output pci-nonexec 'a helper-produced non-executable file'
assert_invalid_helper_output pci-dynamic 'a dynamically linked helper output'

rm -rf "$fixture_project/build/guest_tools"
rm -f "$output_image"
: >"$inject_log"
set +e
run_inject >"$tmp/inject.stdout" 2>"$tmp/inject.stderr"
inject_status=$?
set -e
if [[ "$inject_status" -ne 0 ]]; then
    fail "fresh module injector could not prepare debug utilities: $inject_status"
fi

mapfile -t inject_events <"$inject_log"
build_index=-1
write_index=-1
closure_index=-1
first_read_index=-1
last_read_index=-1
install_index=-1
for index in "${!inject_events[@]}"; do
    case "${inject_events[$index]}" in
        build) build_index=$index ;;
        debugfs-write) write_index=$index ;;
        debugfs-read)
            if (( first_read_index < 0 )); then
                first_read_index=$index
            fi
            last_read_index=$index
            ;;
        e2fsck)
            if (( index > write_index )); then
                closure_index=$index
            fi
            ;;
        install) install_index=$index ;;
    esac
done
(( write_index >= 0 )) || fail 'module injection did not invoke writable debugfs'
(( closure_index > write_index )) ||
    fail 'filesystem was not safely closed after writable debugfs injection'
(( first_read_index > closure_index )) ||
    fail 'final read-only verification did not follow filesystem closure'
(( install_index > last_read_index )) ||
    fail 'debug utilities were installed before final read-only verification completed'
(( build_index >= 0 && build_index < write_index )) ||
    fail 'debug utilities were not built before destination injection'
[[ "$(grep -c '^mktemp:' "$inject_log")" -eq 2 ]] ||
    fail 'module injector did not create both temporaries with explicit templates'
leftover="$(find "$expected_build_tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'inject-modules.*' -o -name 'inject-modules-debugfs.*' \) \
    -print -quit)"
[[ -z "$leftover" ]] || fail "module injector left temporary path: $leftover"

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

: >"$inject_log"
set +e
INSTALL_RESULT=43 run_inject >"$tmp/install-failure.stdout" \
    2>"$tmp/install-failure.stderr"
install_status=$?
set -e
if [[ "$install_status" -ne 43 ]]; then
    fail "install helper failure was not propagated: $install_status"
fi
leftover="$(find "$expected_build_tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'inject-modules.*' -o -name 'inject-modules-debugfs.*' \) \
    -print -quit)"
[[ -z "$leftover" ]] ||
    fail "failing install left module injector temporary path: $leftover"

echo '[inject-modules-debugfs] PASS'
