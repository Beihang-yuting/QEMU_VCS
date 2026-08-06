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
         "$fixture_project/scripts" "$fixture_project/build/guest_tools/dpu-debugutils" \
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
printf 'install\n' >>"${INJECT_LOG}"
exit "${INSTALL_RESULT:-0}"
INSTALL_SHIM
chmod 0755 "$fixture_bin/debugfs" "$fixture_bin/e2fsck" "$fixture_bin/mktemp" \
    "$fixture_project/scripts/install_guest_debugutils.sh"

run_inject() {
    PATH="$fixture_bin:$PATH" \
        MODULES_TAR="$modules_tar" \
        SRC_ROOTFS="$base_image" \
        DST_ROOTFS="$output_image" \
        EXPECTED_ROOTFS="$output_image" \
        EXPECTED_BIN_DIR="$fixture_project/build/guest_tools/dpu-debugutils" \
        bash "$script" unit-test
}

: >"$inject_log"
set +e
run_inject >"$tmp/inject.stdout" 2>"$tmp/inject.stderr"
inject_status=$?
set -e
if [[ "$inject_status" -ne 0 ]]; then
    fail "module injector did not keep temporaries in project build/tmp: $inject_status"
fi

mapfile -t inject_events <"$inject_log"
write_index=-1
closure_index=-1
install_index=-1
for index in "${!inject_events[@]}"; do
    case "${inject_events[$index]}" in
        debugfs-write) write_index=$index ;;
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
(( install_index > closure_index )) ||
    fail 'debug utilities were not installed after module injection and filesystem closure'
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
