#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE_SCRIPT="${REPO_ROOT}/scripts/stage_guest_debugutils.sh"
INSTALL_SCRIPT="${REPO_ROOT}/scripts/install_guest_debugutils.sh"
DEBIAN_BUILDER="${REPO_ROOT}/scripts/build_rootfs_debian.sh"
UBUNTU_SERVER_BUILDER="${REPO_ROOT}/scripts/build_rootfs_ubuntu_server.sh"
REAL_FILE="$(command -v file)"

mkdir -p "${REPO_ROOT}/build/tmp"
WORK_DIR="$(mktemp -d "${REPO_ROOT}/build/tmp/test-stage-debugutils.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() {
    echo "[stage-guest-debugutils] FAIL: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >"${WORK_DIR}/expected-failure.stdout" \
            2>"${WORK_DIR}/expected-failure.stderr"; then
        fail "command unexpectedly succeeded: $*"
    fi
}

assert_root_unchanged() {
    local root=$1

    test "$(cat "${root}/sentinel")" = 'unchanged' ||
        fail "target sentinel changed under ${root}"
    test ! -e "${root}/usr" || fail "target usr tree changed under ${root}"
    test ! -e "${root}/opt" || fail "target opt tree changed under ${root}"
}

test -x "${STAGE_SCRIPT}" || fail "missing executable staging script: ${STAGE_SCRIPT}"
test -x "${INSTALL_SCRIPT}" || fail "missing executable image wrapper: ${INSTALL_SCRIPT}"
test -x "${DEBIAN_BUILDER}" || fail "missing Debian image builder: ${DEBIAN_BUILDER}"
test -x "${UBUNTU_SERVER_BUILDER}" ||
    fail "missing Ubuntu Server image builder: ${UBUNTU_SERVER_BUILDER}"

FAKE_BIN_DIR="${WORK_DIR}/fake static bin"
MIXED_BIN_DIR="${WORK_DIR}/mixed bin"
SHIM_DIR="${WORK_DIR}/file shim"
export FAKE_BIN_DIR MIXED_BIN_DIR REAL_FILE
mkdir -p "${FAKE_BIN_DIR}" "${MIXED_BIN_DIR}" "${SHIM_DIR}"

printf '#!/bin/sh\necho pci-debug-fixture\n' >"${FAKE_BIN_DIR}/pci_debug"
printf '#!/bin/sh\necho reg-display-fixture\n' >"${FAKE_BIN_DIR}/reg_display"
cp "${FAKE_BIN_DIR}/pci_debug" "${MIXED_BIN_DIR}/pci_debug"
ln -s /bin/true "${MIXED_BIN_DIR}/reg_display"
chmod 0755 "${FAKE_BIN_DIR}/pci_debug" "${FAKE_BIN_DIR}/reg_display" \
    "${MIXED_BIN_DIR}/pci_debug"

cat >"${SHIM_DIR}/file" <<'FILE_SHIM'
#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
    case "${argument##*/}" in
        pci_debug)
            if cmp -s "${argument}" "${FAKE_BIN_DIR}/pci_debug" ||
               cmp -s "${argument}" "${MIXED_BIN_DIR}/pci_debug"; then
                printf '%s: ELF fixture executable, statically linked\n' "${argument}"
                exit 0
            fi
            ;;
        reg_display)
            if cmp -s "${argument}" "${FAKE_BIN_DIR}/reg_display"; then
                printf '%s: ELF fixture executable, statically linked\n' "${argument}"
                exit 0
            fi
            ;;
    esac

    if [[ -n "${FAKE_EXT4_IMAGE:-}" && "${argument}" == "${FAKE_EXT4_IMAGE}" ]]; then
        printf '%s: Linux rev 1.0 ext4 filesystem data\n' "${argument}"
        exit 0
    fi
done

exec "${REAL_FILE}" "$@"
FILE_SHIM
chmod 0755 "${SHIM_DIR}/file"

MKTEMP_SHIM_DIR="${WORK_DIR}/mktemp shim"
MKTEMP_LOG="${WORK_DIR}/mktemp.log"
MKTEMP_ALLOWED_PREFIX="${REPO_ROOT}/build/tmp/"
REAL_MKTEMP="$(command -v mktemp)"
export MKTEMP_LOG MKTEMP_ALLOWED_PREFIX REAL_MKTEMP
mkdir -p "${MKTEMP_SHIM_DIR}"
cat >"${MKTEMP_SHIM_DIR}/mktemp" <<'MKTEMP_SHIM'
#!/usr/bin/env bash
set -euo pipefail

template=${@: -1}
printf '%s\n' "${template}" >>"${MKTEMP_LOG}"
if [[ -n "${MKTEMP_FORBIDDEN_PREFIX:-}" &&
      "${template}" == "${MKTEMP_FORBIDDEN_PREFIX}"* ]]; then
    echo "mktemp template inside target root: ${template}" >&2
    exit 90
fi
case "${template}" in
    "${MKTEMP_ALLOWED_PREFIX}"*)
        exec "${REAL_MKTEMP}" "$@"
        ;;
    *)
        echo "mktemp template outside build tree: ${template}" >&2
        exit 91
        ;;
esac
MKTEMP_SHIM
chmod 0755 "${MKTEMP_SHIM_DIR}/mktemp"

TARGET_ROOT="${WORK_DIR}/target root"
MKTEMP_FORBIDDEN_PREFIX="${TARGET_ROOT}/"
export MKTEMP_FORBIDDEN_PREFIX
mkdir -p "${TARGET_ROOT}"
(
    cd "${REPO_ROOT}"
    PATH="${SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
        --root "${TARGET_ROOT}" \
        --bin-dir "${FAKE_BIN_DIR}" \
        --source-dir third_party/dpu-debugutils
)

for utility in pci_debug reg_display; do
    installed="${TARGET_ROOT}/usr/local/bin/${utility}"
    test -x "${installed}" || fail "installed ${utility} is not executable"
    cmp "${FAKE_BIN_DIR}/${utility}" "${installed}" ||
        fail "installed ${utility} content changed"
    test "$(stat -c '%a' "${installed}")" = 755 ||
        fail "installed ${utility} does not have mode 0755"
done

test ! -e "${TARGET_ROOT}/opt/dpu-debugutils" ||
    fail 'source was installed without --include-source'

DOC_DIR="${TARGET_ROOT}/usr/local/share/doc/cosim-dpu-debugutils"
mapfile -d '' DOC_FILES < <(find "${DOC_DIR}" -maxdepth 1 -type f -print0)
test "${#DOC_FILES[@]}" -eq 1 || fail 'expected exactly one usage note'
USAGE_NOTE="${DOC_FILES[0]}"
test "$(stat -c '%a' "${USAGE_NOTE}")" = 644 ||
    fail 'usage note does not have mode 0644'
grep -Fq '/usr/local/bin/pci_debug' "${USAGE_NOTE}" ||
    fail 'usage note omits pci_debug location'
grep -Fq '/usr/local/bin/reg_display' "${USAGE_NOTE}" ||
    fail 'usage note omits reg_display location'
grep -Fq '/opt/dpu-debugutils' "${USAGE_NOTE}" ||
    fail 'usage note omits optional source location'

SOURCE_FIXTURE="${WORK_DIR}/source fixture"
cp -a "${REPO_ROOT}/third_party/dpu-debugutils" "${SOURCE_FIXTURE}"
mkdir -p "${SOURCE_FIXTURE}/.git" \
    "${SOURCE_FIXTURE}/fpga" \
    "${SOURCE_FIXTURE}/contrib" \
    "${SOURCE_FIXTURE}/pcie_debug/bin" \
    "${SOURCE_FIXTURE}/reg_display/obj" \
    "${SOURCE_FIXTURE}/nested/output"
printf 'generated\n' >"${SOURCE_FIXTURE}/pcie_debug/bin/pci_debug"
printf 'generated\n' >"${SOURCE_FIXTURE}/reg_display/obj/reg_display.o"
printf 'generated\n' >"${SOURCE_FIXTURE}/nested/output/driver.ko"
printf 'metadata\n' >"${SOURCE_FIXTURE}/.git/config"
printf 'excluded\n' >"${SOURCE_FIXTURE}/fpga/file"
printf 'excluded\n' >"${SOURCE_FIXTURE}/contrib/file"

mkdir -p "${TARGET_ROOT}/opt/keep" "${TARGET_ROOT}/opt/dpu-debugutils"
printf 'keep\n' >"${TARGET_ROOT}/opt/keep/sentinel"
printf 'stale\n' >"${TARGET_ROOT}/opt/dpu-debugutils/stale"
PATH="${MKTEMP_SHIM_DIR}:${SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
    --root "${TARGET_ROOT}" \
    --bin-dir "${FAKE_BIN_DIR}" \
    --source-dir "${SOURCE_FIXTURE}" \
    --include-source

test -f "${TARGET_ROOT}/opt/dpu-debugutils/Makefile" ||
    fail 'source Makefile was not installed'
test "$(cat "${TARGET_ROOT}/opt/keep/sentinel")" = 'keep' ||
    fail 'install replaced unrelated content under /opt'
test ! -e "${TARGET_ROOT}/opt/dpu-debugutils/stale" ||
    fail 'source destination was not replaced'
test -s "${MKTEMP_LOG}" || fail 'include-source did not exercise mktemp boundary'
while IFS= read -r mktemp_template; do
    [[ "${mktemp_template}" == "${MKTEMP_ALLOWED_PREFIX}"* ]] ||
        fail "temporary template escaped repo/build/tmp: ${mktemp_template}"
    [[ "${mktemp_template}" != "${MKTEMP_FORBIDDEN_PREFIX}"* ]] ||
        fail "temporary template was created inside target root: ${mktemp_template}"
done <"${MKTEMP_LOG}"
hidden_source_tmp="$(find "${TARGET_ROOT}/opt" -maxdepth 1 \
    -name '.dpu-debugutils.*' -print -quit)"
test -z "${hidden_source_tmp}" ||
    fail "hidden source temporary remained in target root: ${hidden_source_tmp}"
excluded_path="$(find "${TARGET_ROOT}/opt/dpu-debugutils" \
    \( -name .git -o -name fpga -o -name contrib -o -name bin -o -name obj \
       -o -name '*.o' -o -name '*.ko' \) -print -quit)"
test -z "${excluded_path}" ||
    fail "excluded source artifact was installed: ${excluded_path}"

# The second utility fails static-link validation.  Nothing may be installed
# after the first utility has already passed validation.
ATOMIC_ROOT="${WORK_DIR}/atomic root"
mkdir -p "${ATOMIC_ROOT}"
printf 'unchanged\n' >"${ATOMIC_ROOT}/sentinel"
expect_failure env PATH="${SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
    --root "${ATOMIC_ROOT}" --bin-dir "${MIXED_BIN_DIR}"
assert_root_unchanged "${ATOMIC_ROOT}"

DYNAMIC_BIN_DIR="${WORK_DIR}/dynamic bin"
DYNAMIC_ROOT="${WORK_DIR}/dynamic root"
mkdir -p "${DYNAMIC_BIN_DIR}" "${DYNAMIC_ROOT}"
ln -s /bin/true "${DYNAMIC_BIN_DIR}/pci_debug"
ln -s /bin/true "${DYNAMIC_BIN_DIR}/reg_display"
printf 'unchanged\n' >"${DYNAMIC_ROOT}/sentinel"
expect_failure env PATH="${SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
    --root "${DYNAMIC_ROOT}" --bin-dir "${DYNAMIC_BIN_DIR}"
assert_root_unchanged "${DYNAMIC_ROOT}"

# Exercise the important argument and source boundary failures.
expect_failure "${STAGE_SCRIPT}"
expect_failure "${STAGE_SCRIPT}" --root
expect_failure "${STAGE_SCRIPT}" --unknown-option value
expect_failure "${STAGE_SCRIPT}" --root "${WORK_DIR}/missing root" \
    --bin-dir "${FAKE_BIN_DIR}"

REGULAR_ROOT="${WORK_DIR}/regular root"
printf 'not a directory\n' >"${REGULAR_ROOT}"
expect_failure "${STAGE_SCRIPT}" --root "${REGULAR_ROOT}" \
    --bin-dir "${FAKE_BIN_DIR}"

INVALID_SOURCE_ROOT="${WORK_DIR}/invalid source root"
INVALID_SOURCE_DIR="${WORK_DIR}/invalid source"
mkdir -p "${INVALID_SOURCE_ROOT}" "${INVALID_SOURCE_DIR}"
printf 'unchanged\n' >"${INVALID_SOURCE_ROOT}/sentinel"
expect_failure env PATH="${SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
    --root "${INVALID_SOURCE_ROOT}" --bin-dir "${FAKE_BIN_DIR}" \
    --include-source
assert_root_unchanged "${INVALID_SOURCE_ROOT}"
expect_failure env PATH="${SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
    --root "${INVALID_SOURCE_ROOT}" --bin-dir "${FAKE_BIN_DIR}" \
    --source-dir "${INVALID_SOURCE_DIR}" --include-source
assert_root_unchanged "${INVALID_SOURCE_ROOT}"

# Missing and non-ext4 images must be rejected before sudo or mount runs.
EARLY_REJECT_SHIM="${WORK_DIR}/early reject shim"
PRIVILEGED_LOG="${WORK_DIR}/privileged.log"
export PRIVILEGED_LOG
mkdir -p "${EARLY_REJECT_SHIM}"
for command_name in sudo mount; do
    cat >"${EARLY_REJECT_SHIM}/${command_name}" <<'PRIVILEGED_SHIM'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >>"${PRIVILEGED_LOG}"
exit 99
PRIVILEGED_SHIM
    chmod 0755 "${EARLY_REJECT_SHIM}/${command_name}"
done

expect_failure env PATH="${EARLY_REJECT_SHIM}:${PATH}" "${INSTALL_SCRIPT}" \
    --rootfs "${WORK_DIR}/missing.ext4" --bin-dir "${FAKE_BIN_DIR}"
test ! -e "${PRIVILEGED_LOG}" ||
    fail 'missing rootfs caused a sudo or mount invocation'

NON_REGULAR_ROOTFS="${WORK_DIR}/rootfs directory"
mkdir -p "${NON_REGULAR_ROOTFS}"
expect_failure env PATH="${EARLY_REJECT_SHIM}:${PATH}" "${INSTALL_SCRIPT}" \
    --rootfs "${NON_REGULAR_ROOTFS}" --bin-dir "${FAKE_BIN_DIR}"
test ! -e "${PRIVILEGED_LOG}" ||
    fail 'non-regular rootfs caused a sudo or mount invocation'

NON_EXT4_IMAGE="${WORK_DIR}/not ext4.img"
printf 'plain text, not an ext4 image\n' >"${NON_EXT4_IMAGE}"
expect_failure env PATH="${EARLY_REJECT_SHIM}:${PATH}" "${INSTALL_SCRIPT}" \
    --rootfs "${NON_EXT4_IMAGE}" --bin-dir "${FAKE_BIN_DIR}"
test ! -e "${PRIVILEGED_LOG}" ||
    fail 'non-ext4 rootfs caused a sudo or mount invocation'

expect_failure "${INSTALL_SCRIPT}"
expect_failure "${INSTALL_SCRIPT}" --rootfs
expect_failure "${INSTALL_SCRIPT}" --unknown-option value
expect_failure "${INSTALL_SCRIPT}" --rootfs "${NON_EXT4_IMAGE}" \
    --bin-dir "${FAKE_BIN_DIR}" --include-source

# Drive the complete wrapper lifecycle without privileges.  The fake sudo
# models a successful loop mount, delegates the staging result to the test,
# and makes e2fsck return 1 (filesystem corrected), which is an accepted result.
LIFECYCLE_SHIM="${WORK_DIR}/lifecycle shim"
FAKE_EXT4_IMAGE="${WORK_DIR}/fake ext4 image"
LIFECYCLE_LOG="${WORK_DIR}/lifecycle.log"
LIFECYCLE_MOUNT_DIR_FILE="${WORK_DIR}/lifecycle-mount-dir"
export FAKE_EXT4_IMAGE LIFECYCLE_LOG LIFECYCLE_MOUNT_DIR_FILE
mkdir -p "${LIFECYCLE_SHIM}"
printf 'fixture image\n' >"${FAKE_EXT4_IMAGE}"
cat >"${LIFECYCLE_SHIM}/sudo" <<'SUDO_SHIM'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == -n ]] || exit 98
shift
command_path=${1:?missing command}
shift

case "$(basename "${command_path}")" in
    mount)
        [[ "${1:-}" == -t && "${2:-}" == ext4 &&
           "${3:-}" == -o && "${4:-}" == loop,nosuid,nodev,noexec ]] || exit 96
        printf 'mount\n' >>"${LIFECYCLE_LOG}"
        printf '%s\n' "${@: -1}" >"${LIFECYCLE_MOUNT_DIR_FILE}"
        ;;
    stage_guest_debugutils.sh)
        printf 'stage\n' >>"${LIFECYCLE_LOG}"
        exit "${LIFECYCLE_STAGE_RESULT:-0}"
        ;;
    umount)
        [[ "${1:-}" == "$(cat "${LIFECYCLE_MOUNT_DIR_FILE}")" ]] || exit 95
        printf 'umount\n' >>"${LIFECYCLE_LOG}"
        ;;
    e2fsck)
        [[ "${1:-}" == -fy && "${2:-}" == "${FAKE_EXT4_IMAGE}" ]] || exit 94
        printf 'e2fsck\n' >>"${LIFECYCLE_LOG}"
        exit 1
        ;;
    *)
        printf 'unexpected:%s\n' "${command_path}" >>"${LIFECYCLE_LOG}"
        exit 97
        ;;
esac
SUDO_SHIM
chmod 0755 "${LIFECYCLE_SHIM}/sudo"

EXPECTED_LIFECYCLE=$'mount\nstage\numount\ne2fsck'
PATH="${LIFECYCLE_SHIM}:${SHIM_DIR}:${PATH}" LIFECYCLE_STAGE_RESULT=0 \
    "${INSTALL_SCRIPT}" --rootfs "${FAKE_EXT4_IMAGE}" \
    --bin-dir "${FAKE_BIN_DIR}"
test "$(cat "${LIFECYCLE_LOG}")" = "${EXPECTED_LIFECYCLE}" ||
    fail "unexpected successful wrapper lifecycle: $(tr '\n' ' ' <"${LIFECYCLE_LOG}")"
SUCCESS_MOUNT_DIR="$(cat "${LIFECYCLE_MOUNT_DIR_FILE}")"
[[ "${SUCCESS_MOUNT_DIR}" == "${REPO_ROOT}/build/tmp/"* ]] ||
    fail "mount directory was outside repo/build/tmp: ${SUCCESS_MOUNT_DIR}"
test ! -e "${SUCCESS_MOUNT_DIR}" ||
    fail "successful wrapper left mount directory: ${SUCCESS_MOUNT_DIR}"

: >"${LIFECYCLE_LOG}"
: >"${LIFECYCLE_MOUNT_DIR_FILE}"
set +e
PATH="${LIFECYCLE_SHIM}:${SHIM_DIR}:${PATH}" LIFECYCLE_STAGE_RESULT=17 \
    "${INSTALL_SCRIPT}" --rootfs "${FAKE_EXT4_IMAGE}" \
    --bin-dir "${FAKE_BIN_DIR}" \
    >"${WORK_DIR}/lifecycle-failure.stdout" \
    2>"${WORK_DIR}/lifecycle-failure.stderr"
LIFECYCLE_FAILURE_STATUS=$?
set -e
test "${LIFECYCLE_FAILURE_STATUS}" -eq 17 ||
    fail "staging failure status was not preserved: ${LIFECYCLE_FAILURE_STATUS}"
test "$(cat "${LIFECYCLE_LOG}")" = "${EXPECTED_LIFECYCLE}" ||
    fail "unexpected failing wrapper lifecycle: $(tr '\n' ' ' <"${LIFECYCLE_LOG}")"
FAILED_MOUNT_DIR="$(cat "${LIFECYCLE_MOUNT_DIR_FILE}")"
[[ "${FAILED_MOUNT_DIR}" == "${REPO_ROOT}/build/tmp/"* ]] ||
    fail "failure mount directory was outside repo/build/tmp: ${FAILED_MOUNT_DIR}"
test ! -e "${FAILED_MOUNT_DIR}" ||
    fail "failing wrapper left mount directory: ${FAILED_MOUNT_DIR}"

# Both image builders must build the static tools before creating an image and
# stage them while the Guest root is mounted.  The Ubuntu Server path already
# has a broad behavioral fixture of its own, so keep a small ordering contract
# here and drive the newly covered Debian path end-to-end with fake helpers.
ubuntu_build_line="$(grep -nF '"${PROJECT_DIR}/scripts/build_dpu_debugutils.sh" "${DEBUG_BIN_DIR}"' \
    "${UBUNTU_SERVER_BUILDER}" | cut -d: -f1)"
ubuntu_image_line="$(grep -nF 'truncate -s "${ROOTFS_SIZE}" "${ROOTFS_IMAGE}"' \
    "${UBUNTU_SERVER_BUILDER}" | cut -d: -f1)"
ubuntu_stage_line="$(grep -nF '"${PROJECT_DIR}/scripts/stage_guest_debugutils.sh"' \
    "${UBUNTU_SERVER_BUILDER}" | tail -1 | cut -d: -f1)"
ubuntu_unmount_line="$(grep -nF 'unmount_all' "${UBUNTU_SERVER_BUILDER}" | tail -1 | cut -d: -f1)"
[[ -n "${ubuntu_build_line}" && -n "${ubuntu_image_line}" &&
   -n "${ubuntu_stage_line}" && -n "${ubuntu_unmount_line}" ]] ||
    fail 'Ubuntu Server debug utility call-site contract is incomplete'
(( ubuntu_build_line < ubuntu_image_line )) ||
    fail 'Ubuntu Server debug utilities are not built before image creation'
(( ubuntu_image_line < ubuntu_stage_line && ubuntu_stage_line < ubuntu_unmount_line )) ||
    fail 'Ubuntu Server debug utilities are not staged while the image is mounted'
grep -Fq 'mktemp -d "${BUILD_TMP}/debian-rootfs.XXXXXX"' "${DEBIAN_BUILDER}" ||
    fail 'Debian rootfs mount temporary is not constrained to build/tmp'
grep -Fq 'mktemp -d "${BUILD_TMP}/debian-initramfs.XXXXXX"' "${DEBIAN_BUILDER}" ||
    fail 'Debian initramfs temporary is not constrained to build/tmp'
if grep -Eq 'mktemp .*([[:space:]]|^)/tmp/' "${DEBIAN_BUILDER}"; then
    fail 'Debian builder still creates production temporaries under /tmp'
fi

DEBIAN_FIXTURE="${WORK_DIR}/debian builder fixture"
DEBIAN_FAKE_BIN="${DEBIAN_FIXTURE}/fake bin"
DEBIAN_LOG="${DEBIAN_FIXTURE}/builder.log"
DEBIAN_MOUNT_FILE="${DEBIAN_FIXTURE}/mount-dir"
DEBIAN_OUTPUT="${DEBIAN_FIXTURE}/output"
export DEBIAN_FIXTURE DEBIAN_LOG DEBIAN_MOUNT_FILE
mkdir -p "${DEBIAN_FIXTURE}/scripts" "${DEBIAN_FIXTURE}/build/tmp" \
    "${DEBIAN_FAKE_BIN}" "${DEBIAN_OUTPUT}"
cp "${DEBIAN_BUILDER}" "${DEBIAN_FIXTURE}/scripts/build_rootfs_debian.sh"
chmod 0755 "${DEBIAN_FIXTURE}/scripts/build_rootfs_debian.sh"

cat >"${DEBIAN_FIXTURE}/scripts/build_dpu_debugutils.sh" <<'DEBIAN_BUILD_HELPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 0 ]] || exit 80
printf 'build\n' >>"${DEBIAN_LOG}"
build_result=${DEBIAN_BUILD_RESULT:-0}
(( build_result == 0 )) || exit "${build_result}"
mkdir -p "${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils"
for utility in pci_debug reg_display; do
    printf '#!/bin/sh\nexit 0\n' \
        >"${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils/${utility}"
    chmod 0755 "${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils/${utility}"
done
DEBIAN_BUILD_HELPER

cat >"${DEBIAN_FIXTURE}/scripts/stage_guest_debugutils.sh" <<'DEBIAN_STAGE_HELPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 && "$1" == --root && "$3" == --bin-dir ]] || exit 81
[[ "$2" == "$(cat "${DEBIAN_MOUNT_FILE}")" && -f "$2/.fixture-mounted" ]] || exit 82
[[ "$4" == "${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils" ]] || exit 83
printf 'stage:%s\n' "$2" >>"${DEBIAN_LOG}"
exit "${DEBIAN_STAGE_RESULT:-0}"
DEBIAN_STAGE_HELPER
chmod 0755 "${DEBIAN_FIXTURE}/scripts/build_dpu_debugutils.sh" \
    "${DEBIAN_FIXTURE}/scripts/stage_guest_debugutils.sh"

cat >"${DEBIAN_FAKE_BIN}/id" <<'DEBIAN_ID_SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == -u ]] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
DEBIAN_ID_SHIM

cat >"${DEBIAN_FAKE_BIN}/debootstrap" <<'DEBIAN_DEBOOTSTRAP_SHIM'
#!/usr/bin/env bash
set -euo pipefail
root=$3
mkdir -p "$root"/{boot,dev,etc,etc/profile.d,etc/systemd/system,proc,sys,usr/local/bin}
printf 'root:*:1:1:1:1:1:1:1\n' >"$root/etc/shadow"
DEBIAN_DEBOOTSTRAP_SHIM

cat >"${DEBIAN_FAKE_BIN}/dd" <<'DEBIAN_DD_SHIM'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    case "$argument" in
        of=*) image=${argument#of=} ;;
    esac
done
printf 'dd\n' >>"${DEBIAN_LOG}"
: >"${image:?missing output image}"
DEBIAN_DD_SHIM

cat >"${DEBIAN_FAKE_BIN}/mkfs.ext4" <<'DEBIAN_MKFS_SHIM'
#!/usr/bin/env bash
exit 0
DEBIAN_MKFS_SHIM

cat >"${DEBIAN_FAKE_BIN}/losetup" <<'DEBIAN_LOSETUP_SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --find ]]; then
    printf '/dev/loop-fixture\n'
else
    printf 'losetup-detach\n' >>"${DEBIAN_LOG}"
fi
DEBIAN_LOSETUP_SHIM

cat >"${DEBIAN_FAKE_BIN}/mount" <<'DEBIAN_MOUNT_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${@: -1}
mkdir -p "$target"
if [[ "${1:-}" == /dev/loop-fixture ]]; then
    printf '%s\n' "$target" >"${DEBIAN_MOUNT_FILE}"
    : >"$target/.fixture-mounted"
    printf 'mount-root:%s\n' "$target" >>"${DEBIAN_LOG}"
fi
DEBIAN_MOUNT_SHIM

cat >"${DEBIAN_FAKE_BIN}/umount" <<'DEBIAN_UMOUNT_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${1:?missing target}
if [[ -s "${DEBIAN_MOUNT_FILE}" && "$target" == "$(cat "${DEBIAN_MOUNT_FILE}")" ]]; then
    rm -f "$target/.fixture-mounted"
    printf 'umount-root:%s\n' "$target" >>"${DEBIAN_LOG}"
fi
DEBIAN_UMOUNT_SHIM

cat >"${DEBIAN_FAKE_BIN}/chroot" <<'DEBIAN_CHROOT_SHIM'
#!/usr/bin/env bash
exit 0
DEBIAN_CHROOT_SHIM

cat >"${DEBIAN_FAKE_BIN}/openssl" <<'DEBIAN_OPENSSL_SHIM'
#!/usr/bin/env bash
printf 'fixture-password-hash\n'
DEBIAN_OPENSSL_SHIM

cat >"${DEBIAN_FAKE_BIN}/ls" <<'DEBIAN_LS_SHIM'
#!/usr/bin/env bash
for argument in "$@"; do
    case "$argument" in
        */boot/vmlinuz-\*|*/boot/initrd.img-\*) exit 0 ;;
    esac
done
exec /usr/bin/ls "$@"
DEBIAN_LS_SHIM
chmod 0755 "${DEBIAN_FAKE_BIN}"/*

run_debian_builder() {
    PATH="${DEBIAN_FAKE_BIN}:${PATH}" \
        "${DEBIAN_FIXTURE}/scripts/build_rootfs_debian.sh" "${DEBIAN_OUTPUT}"
}

: >"${DEBIAN_LOG}"
run_debian_builder >"${DEBIAN_FIXTURE}/success.stdout" \
    2>"${DEBIAN_FIXTURE}/success.stderr"
DEBIAN_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
mapfile -t DEBIAN_EVENTS <"${DEBIAN_LOG}"
test "${DEBIAN_EVENTS[0]:-}" = build ||
    fail "Debian builder did not build tools first: $(tr '\n' ' ' <"${DEBIAN_LOG}")"
test "${DEBIAN_EVENTS[1]:-}" = dd ||
    fail "Debian builder created the image before building tools: $(tr '\n' ' ' <"${DEBIAN_LOG}")"
[[ "${DEBIAN_MOUNT_DIR}" == "${DEBIAN_FIXTURE}/build/tmp/"* ]] ||
    fail "Debian builder mount escaped build/tmp: ${DEBIAN_MOUNT_DIR}"
test ! -e "${DEBIAN_MOUNT_DIR}" ||
    fail "Debian builder left mount directory: ${DEBIAN_MOUNT_DIR}"
stage_event=''
unmount_event=''
for event in "${DEBIAN_EVENTS[@]}"; do
    [[ "$event" == stage:* ]] && stage_event=$event
    [[ "$event" == umount-root:* ]] && unmount_event=$event
done
test "${stage_event}" = "stage:${DEBIAN_MOUNT_DIR}" ||
    fail 'Debian builder did not stage tools into its mounted root'
test "${unmount_event}" = "umount-root:${DEBIAN_MOUNT_DIR}" ||
    fail 'Debian builder did not unmount its root after staging'

: >"${DEBIAN_LOG}"
set +e
DEBIAN_BUILD_RESULT=31 run_debian_builder \
    >"${DEBIAN_FIXTURE}/build-failure.stdout" \
    2>"${DEBIAN_FIXTURE}/build-failure.stderr"
DEBIAN_BUILD_STATUS=$?
set -e
test "${DEBIAN_BUILD_STATUS}" -eq 31 ||
    fail "Debian builder swallowed tool build failure: ${DEBIAN_BUILD_STATUS}"
test "$(cat "${DEBIAN_LOG}")" = build ||
    fail 'Debian builder continued after tool build failure'

: >"${DEBIAN_LOG}"
set +e
DEBIAN_STAGE_RESULT=37 run_debian_builder \
    >"${DEBIAN_FIXTURE}/stage-failure.stdout" \
    2>"${DEBIAN_FIXTURE}/stage-failure.stderr"
DEBIAN_STAGE_STATUS=$?
set -e
test "${DEBIAN_STAGE_STATUS}" -eq 37 ||
    fail "Debian builder swallowed staging failure: ${DEBIAN_STAGE_STATUS}"
DEBIAN_FAILED_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test ! -e "${DEBIAN_FAILED_MOUNT_DIR}" ||
    fail "Debian builder staging failure left mount directory: ${DEBIAN_FAILED_MOUNT_DIR}"
grep -Fxq "umount-root:${DEBIAN_FAILED_MOUNT_DIR}" "${DEBIAN_LOG}" ||
    fail 'Debian builder staging failure did not unmount the root'
grep -Fxq 'losetup-detach' "${DEBIAN_LOG}" ||
    fail 'Debian builder staging failure did not detach the loop device'

echo '[stage-guest-debugutils] PASS'
