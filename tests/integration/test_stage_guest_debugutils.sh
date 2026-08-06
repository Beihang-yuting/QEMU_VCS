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
DEBIAN_MOUNT_STATE="${DEBIAN_FIXTURE}/mount-state"
DEBIAN_BUILD_USER_LOG="${DEBIAN_FIXTURE}/build-user.log"
DEBIAN_GUEST_TOOLS_TREE="${DEBIAN_FIXTURE}/guest-tools-tree"
DEBIAN_SIGNAL_STATE="${DEBIAN_FIXTURE}/signal-state"
DEBIAN_SUDO_LOG="${DEBIAN_FIXTURE}/sudo-boundaries.log"
DEBIAN_OUTPUT="${DEBIAN_FIXTURE}/output"
export DEBIAN_FIXTURE DEBIAN_LOG DEBIAN_MOUNT_FILE DEBIAN_MOUNT_STATE \
    DEBIAN_BUILD_USER_LOG DEBIAN_GUEST_TOOLS_TREE DEBIAN_SIGNAL_STATE \
    DEBIAN_SUDO_LOG
mkdir -p "${DEBIAN_FIXTURE}/scripts" "${DEBIAN_FIXTURE}/build/tmp" \
    "${DEBIAN_FIXTURE}/guest" "${DEBIAN_FAKE_BIN}" "${DEBIAN_OUTPUT}"
cp "${DEBIAN_BUILDER}" "${DEBIAN_FIXTURE}/scripts/build_rootfs_debian.sh"
chmod 0755 "${DEBIAN_FIXTURE}/scripts/build_rootfs_debian.sh"
printf '#!/bin/sh\nexec /bin/sh\n' >"${DEBIAN_FIXTURE}/guest/cosim-init"
chmod 0755 "${DEBIAN_FIXTURE}/guest/cosim-init"

cat >"${DEBIAN_FIXTURE}/scripts/build_dpu_debugutils.sh" <<'DEBIAN_BUILD_HELPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 0 ]] || exit 80
build_user=${DEBIAN_EFFECTIVE_USER:-root}
printf '%s\n' "$build_user" >"${DEBIAN_BUILD_USER_LOG}"
[[ "$build_user" == "${DEBIAN_EXPECT_BUILD_USER:-root}" ]] || exit 86
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
if [[ "${DEBIAN_CHECK_FINAL_TOOLS_TREE:-0}" == 1 ]]; then
    [[ ! -e "$2/usr/local/bin/dpu-debugutils" ]] || exit 88
    [[ -x "$2/usr/local/bin/other_tool" ]] || exit 89
    cp "$4/pci_debug" "$2/usr/local/bin/pci_debug"
    cp "$4/reg_display" "$2/usr/local/bin/reg_display"
    find "$2/usr/local/bin" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort \
        >"${DEBIAN_GUEST_TOOLS_TREE}"
fi
printf 'stage:%s\n' "$2" >>"${DEBIAN_LOG}"
exit "${DEBIAN_STAGE_RESULT:-0}"
DEBIAN_STAGE_HELPER
chmod 0755 "${DEBIAN_FIXTURE}/scripts/build_dpu_debugutils.sh" \
    "${DEBIAN_FIXTURE}/scripts/stage_guest_debugutils.sh"

cat >"${DEBIAN_FAKE_BIN}/id" <<'DEBIAN_ID_SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == -u && "$#" -eq 1 ]]; then
    printf '0\n'
    exit 0
fi
if [[ "${1:-}" == -u && "${2:-}" == fixture-builder ]]; then
    printf '1234\n'
    exit 0
fi
if [[ "${1:-}" == -g && "${2:-}" == fixture-builder ]]; then
    printf '1234\n'
    exit 0
fi
exec /usr/bin/id "$@"
DEBIAN_ID_SHIM

cat >"${DEBIAN_FAKE_BIN}/sudo" <<'DEBIAN_SUDO_SHIM'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -u && "${2:-}" == fixture-builder && "${3:-}" == -- ]] || exit 87
shift 3
if [[ "${DEBIAN_ENFORCE_BUILD_USER_BOUNDARIES:-0}" == 1 ]]; then
    command_name=${1:-}
    target=${@: -1}
    case "$command_name" in
        mkdir)
            printf 'mkdir:%s:fixture-builder\n' "$target" >>"${DEBIAN_SUDO_LOG}"
            if [[ "${DEBIAN_SUDO_DENY_MKDIR_PATH:-}" == "$target" ]]; then
                exit 52
            fi
            ;;
        test)
            [[ "${2:-}" == -w ]] || exit 90
            printf 'write:%s:fixture-builder\n' "$target" >>"${DEBIAN_SUDO_LOG}"
            if [[ "${DEBIAN_SUDO_DENY_WRITE_PATH:-}" == "$target" ]]; then
                exit 53
            fi
            exit 0
            ;;
        */scripts/build_dpu_debugutils.sh)
            printf 'helper:%s:fixture-builder\n' "$command_name" >>"${DEBIAN_SUDO_LOG}"
            ;;
        *) exit 91 ;;
    esac
fi
DEBIAN_EFFECTIVE_USER=fixture-builder exec "$@"
DEBIAN_SUDO_SHIM

cat >"${DEBIAN_FAKE_BIN}/debootstrap" <<'DEBIAN_DEBOOTSTRAP_SHIM'
#!/usr/bin/env bash
set -euo pipefail
root=$3
mkdir -p "$root"/{boot,dev,etc,etc/profile.d,etc/systemd/system,proc,sys,usr/local/bin}
printf 'root:*:1:1:1:1:1:1:1\n' >"$root/etc/shadow"
if [[ "${DEBIAN_WITH_INITRD:-0}" == 1 ]]; then
    printf 'fixture initrd\n' >"$root/boot/initrd.img-fixture"
fi
if [[ "${DEBIAN_SYMLINK_MOUNT_TARGET:-}" == /dev ]]; then
    rmdir "$root/dev"
    mkdir -p "${DEBIAN_FIXTURE}/escaped-mount-dev"
    ln -s "${DEBIAN_FIXTURE}/escaped-mount-dev" "$root/dev"
fi
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
    exit "${DEBIAN_LOSETUP_DETACH_RESULT:-0}"
fi
DEBIAN_LOSETUP_SHIM

cat >"${DEBIAN_FAKE_BIN}/mount" <<'DEBIAN_MOUNT_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${@: -1}
mkdir -p "$target"
printf '%s\n' "$target" >>"${DEBIAN_MOUNT_STATE}"
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
root=$(cat "${DEBIAN_MOUNT_FILE}")
target_kind=${target#"${root}"}
[[ -n "$target_kind" ]] || target_kind=root
if [[ "${DEBIAN_UMOUNT_FAIL_TARGET:-}" == "$target_kind" ]]; then
    printf 'umount-failed:%s\n' "$target" >>"${DEBIAN_LOG}"
    exit 47
fi
if [[ "${DEBIAN_UMOUNT_STICKY_TARGET:-}" == "$target_kind" ]]; then
    printf 'umount-still-mounted:%s\n' "$target" >>"${DEBIAN_LOG}"
    exit 0
fi
if [[ "${DEBIAN_UMOUNT_STICKY_ONCE_TARGET:-}" == "$target_kind" &&
      ! -e "${DEBIAN_SIGNAL_STATE}.umount-sticky-once" ]]; then
    : >"${DEBIAN_SIGNAL_STATE}.umount-sticky-once"
    printf 'umount-still-mounted-once:%s\n' "$target" >>"${DEBIAN_LOG}"
    exit 0
fi
if awk -v prefix="$target/" 'index($0, prefix) == 1 { found = 1 } END { exit !found }' \
        "${DEBIAN_MOUNT_STATE}"; then
    printf 'umount-has-child:%s\n' "$target" >>"${DEBIAN_LOG}"
    exit 48
fi
awk -v target="$target" '$0 != target' "${DEBIAN_MOUNT_STATE}" \
    >"${DEBIAN_MOUNT_STATE}.new"
mv "${DEBIAN_MOUNT_STATE}.new" "${DEBIAN_MOUNT_STATE}"
if [[ "$target" == "$root" ]]; then
    /usr/bin/find "$target" -mindepth 1 -delete
    if [[ "${DEBIAN_ROOT_UNMOUNT_SENTINEL:-0}" == 1 ]]; then
        printf 'host mountpoint sentinel\n' >"$target/host-sentinel"
    fi
    printf 'umount-root:%s\n' "$target" >>"${DEBIAN_LOG}"
fi
if [[ "${DEBIAN_SIGNAL_DURING_UMOUNT_TARGET:-}" == "$target_kind" &&
      ! -e "${DEBIAN_SIGNAL_STATE}.first" ]]; then
    : >"${DEBIAN_SIGNAL_STATE}.first"
    kill -TERM "$PPID"
fi
DEBIAN_UMOUNT_SHIM

cat >"${DEBIAN_FAKE_BIN}/mountpoint" <<'DEBIAN_MOUNTPOINT_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${@: -1}
root=$(cat "${DEBIAN_MOUNT_FILE}")
target_kind=${target#"${root}"}
[[ -n "$target_kind" ]] || target_kind=root
if [[ "${DEBIAN_MOUNTPOINT_ERROR_ONCE_TARGET:-}" == "$target_kind" &&
      ! -e "${DEBIAN_SIGNAL_STATE}.mountpoint-error-once" ]]; then
    : >"${DEBIAN_SIGNAL_STATE}.mountpoint-error-once"
    exit 65
fi
if [[ "${DEBIAN_MOUNTPOINT_ERROR_TARGET:-}" == "$target_kind" ]]; then
    exit 65
fi
if grep -Fxq "$target" "${DEBIAN_MOUNT_STATE}"; then
    exit 0
fi
if [[ "${DEBIAN_SECOND_SIGNAL_DURING_VERIFY_TARGET:-}" == "$target_kind" &&
      -e "${DEBIAN_SIGNAL_STATE}.first" &&
      ! -e "${DEBIAN_SIGNAL_STATE}.second" ]]; then
    : >"${DEBIAN_SIGNAL_STATE}.second"
    kill -INT "$PPID"
fi
inactive_status=${DEBIAN_MOUNTPOINT_INACTIVE_STATUS:-32}
if [[ "${1:-}" != -q && "$inactive_status" -eq 1 ]]; then
    [[ "${LC_ALL:-}" == C ]] || exit 97
    diagnostic_kind=not-mounted
    if [[ -z "${DEBIAN_MOUNTPOINT_DIAGNOSTIC_TARGET:-}" ||
          "${DEBIAN_MOUNTPOINT_DIAGNOSTIC_TARGET}" == "$target_kind" ]]; then
        diagnostic_kind=${DEBIAN_MOUNTPOINT_DIAGNOSTIC_KIND:-not-mounted}
    fi
    case "$diagnostic_kind" in
        not-mounted)
            printf '%s is not a mountpoint\n' "$target"
            ;;
        missing)
            printf 'mountpoint: %s: No such file or directory\n' "$target" >&2
            ;;
        permission)
            printf 'mountpoint: %s: Permission denied\n' "$target" >&2
            ;;
        system)
            printf 'mountpoint: failed to read mount table: Input/output error\n' >&2
            ;;
        unexpected)
            printf 'warning: %s is not a mountpoint\n' "$target" >&2
            ;;
        identity-change)
            identity_counter_file="${DEBIAN_SIGNAL_STATE}.identity-change"
            identity_counter=0
            [[ ! -f "$identity_counter_file" ]] ||
                identity_counter=$(<"$identity_counter_file")
            identity_counter=$((identity_counter + 1))
            printf '%s\n' "$identity_counter" >"$identity_counter_file"
            mv "$target" "${target}.identity-${identity_counter}"
            mkdir "$target"
            printf '%s is not a mountpoint\n' "$target"
            ;;
        identity-change-once)
            identity_once_file="${DEBIAN_SIGNAL_STATE}.identity-change-once"
            if [[ ! -e "$identity_once_file" ]]; then
                : >"$identity_once_file"
                mv "$target" "${target}.identity-once"
                mkdir "$target"
            fi
            printf '%s is not a mountpoint\n' "$target"
            ;;
        *) exit 96 ;;
    esac
fi
exit "$inactive_status"
DEBIAN_MOUNTPOINT_SHIM

cat >"${DEBIAN_FAKE_BIN}/chroot" <<'DEBIAN_CHROOT_SHIM'
#!/usr/bin/env bash
exit 0
DEBIAN_CHROOT_SHIM

cat >"${DEBIAN_FAKE_BIN}/openssl" <<'DEBIAN_OPENSSL_SHIM'
#!/usr/bin/env bash
printf 'fixture-password-hash\n'
DEBIAN_OPENSSL_SHIM

cat >"${DEBIAN_FAKE_BIN}/file" <<'DEBIAN_FILE_SHIM'
#!/usr/bin/env bash
printf '%s: gzip compressed data\n' "${1:-fixture}"
DEBIAN_FILE_SHIM

cat >"${DEBIAN_FAKE_BIN}/zcat" <<'DEBIAN_ZCAT_SHIM'
#!/usr/bin/env bash
printf 'fixture archive\n'
DEBIAN_ZCAT_SHIM

cat >"${DEBIAN_FAKE_BIN}/cpio" <<'DEBIAN_CPIO_SHIM'
#!/usr/bin/env bash
cat >/dev/null
exit "${DEBIAN_CPIO_RESULT:-0}"
DEBIAN_CPIO_SHIM

cat >"${DEBIAN_FAKE_BIN}/rm" <<'DEBIAN_RM_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${@: -1}
case "${DEBIAN_RM_FAIL_KIND:-}:$target" in
    repack:"${DEBIAN_FIXTURE}/build/tmp/debian-initramfs."*)
        printf 'rm-repack-failed:%s\n' "$target" >>"${DEBIAN_LOG}"
        exit 67
        ;;
esac
exec /usr/bin/rm "$@"
DEBIAN_RM_SHIM

cat >"${DEBIAN_FAKE_BIN}/rmdir" <<'DEBIAN_RMDIR_SHIM'
#!/usr/bin/env bash
set -euo pipefail
target=${@: -1}
case "${DEBIAN_RMDIR_FAIL_KIND:-}:$target" in
    root:"${DEBIAN_FIXTURE}/build/tmp/debian-rootfs."*)
        printf 'rmdir-root-failed:%s\n' "$target" >>"${DEBIAN_LOG}"
        exit 68
        ;;
esac
exec /usr/bin/rmdir "$@"
DEBIAN_RMDIR_SHIM

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
: >"${DEBIAN_MOUNT_STATE}"
if ! run_debian_builder >"${DEBIAN_FIXTURE}/success.stdout" \
        2>"${DEBIAN_FIXTURE}/success.stderr"; then
    fail "Debian builder success fixture failed: $(<"${DEBIAN_FIXTURE}/success.stderr")"
fi
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

# util-linux mountpoint commonly returns 1 for an ordinary non-mountpoint.
# Accept it only after an exact C-locale non-quiet diagnostic for the same
# existing, controlled directory.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
if ! DEBIAN_MOUNTPOINT_INACTIVE_STATUS=1 run_debian_builder \
        >"${DEBIAN_FIXTURE}/mountpoint-one.stdout" \
        2>"${DEBIAN_FIXTURE}/mountpoint-one.stderr"; then
    fail "Debian builder rejected mountpoint status 1 for an unmounted path: $(<"${DEBIAN_FIXTURE}/mountpoint-one.stderr")"
fi
DEBIAN_STATUS_ONE_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test ! -e "${DEBIAN_STATUS_ONE_MOUNT_DIR}" ||
    fail 'Debian builder retained an unmounted root when mountpoint returned 1'
grep -Fxq 'losetup-detach' "${DEBIAN_LOG}" ||
    fail 'Debian builder did not detach the loop after mountpoint returned 1'

# Status 32 remains the unambiguous util-linux non-mountpoint result used by
# newer versions.  Keep an explicit case alongside the status-1 compatibility
# fixture; status 0 is covered below by the sticky mounted-root case.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
if ! DEBIAN_MOUNTPOINT_INACTIVE_STATUS=32 run_debian_builder \
        >"${DEBIAN_FIXTURE}/mountpoint-thirty-two.stdout" \
        2>"${DEBIAN_FIXTURE}/mountpoint-thirty-two.stderr"; then
    fail "Debian builder rejected mountpoint status 32: $(<"${DEBIAN_FIXTURE}/mountpoint-thirty-two.stderr")"
fi

# Every queried mount path must be one of the builder's known directories and
# must canonically retain that identity.  Never mount through a Guest symlink.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_SYMLINK_MOUNT_TARGET=/dev run_debian_builder \
    >"${DEBIAN_FIXTURE}/symlink-mount-target.stdout" \
    2>"${DEBIAN_FIXTURE}/symlink-mount-target.stderr"
DEBIAN_SYMLINK_MOUNT_TARGET_STATUS=$?
set -e
DEBIAN_SYMLINK_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_SYMLINK_MOUNT_TARGET_STATUS}" -ne 0 ||
    fail 'Debian builder accepted a symlinked /dev mount target'
test -d "${DEBIAN_SYMLINK_MOUNT_DIR}" ||
    fail 'Debian builder removed a root with an unsafe mount target'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop with an unsafe mount target'

# Status 1 is ambiguous.  Missing-path, permission, system, and merely
# substring-matching diagnostics must remain unknown and fail closed.
for diagnostic_kind in missing permission system unexpected; do
    : >"${DEBIAN_LOG}"
    : >"${DEBIAN_MOUNT_STATE}"
    set +e
    DEBIAN_MOUNTPOINT_INACTIVE_STATUS=1 \
    DEBIAN_MOUNTPOINT_DIAGNOSTIC_TARGET=root \
    DEBIAN_MOUNTPOINT_DIAGNOSTIC_KIND="$diagnostic_kind" \
        run_debian_builder \
        >"${DEBIAN_FIXTURE}/mountpoint-${diagnostic_kind}.stdout" \
        2>"${DEBIAN_FIXTURE}/mountpoint-${diagnostic_kind}.stderr"
    DEBIAN_MOUNTPOINT_DIAGNOSTIC_STATUS=$?
    set -e
    DEBIAN_DIAGNOSTIC_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
    test "${DEBIAN_MOUNTPOINT_DIAGNOSTIC_STATUS}" -ne 0 ||
        fail "Debian builder accepted ambiguous mountpoint diagnostic: $diagnostic_kind"
    test -d "${DEBIAN_DIAGNOSTIC_MOUNT_DIR}" ||
        fail "Debian builder removed a root after $diagnostic_kind mountpoint diagnostic"
    test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
        fail "Debian builder detached its loop after $diagnostic_kind mountpoint diagnostic"
done

# Even the exact text is insufficient if the path's device/inode identity
# changes between quiet and diagnostic probes.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
rm -f "${DEBIAN_SIGNAL_STATE}.identity-change"
set +e
DEBIAN_MOUNTPOINT_INACTIVE_STATUS=1 \
DEBIAN_MOUNTPOINT_DIAGNOSTIC_TARGET=root \
DEBIAN_MOUNTPOINT_DIAGNOSTIC_KIND=identity-change \
    run_debian_builder >"${DEBIAN_FIXTURE}/mountpoint-identity-change.stdout" \
    2>"${DEBIAN_FIXTURE}/mountpoint-identity-change.stderr"
DEBIAN_MOUNTPOINT_IDENTITY_STATUS=$?
set -e
DEBIAN_IDENTITY_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_MOUNTPOINT_IDENTITY_STATUS}" -ne 0 ||
    fail 'Debian builder accepted a mountpoint path whose identity changed'
test -d "${DEBIAN_IDENTITY_MOUNT_DIR}" ||
    fail 'Debian builder removed a root whose identity changed during mountpoint probing'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop after mountpoint path identity changed'

# A one-shot identity change must poison the target for the remainder of the
# run.  Later exact not-mountpoint responses cannot establish a new baseline.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
rm -f "${DEBIAN_SIGNAL_STATE}.identity-change-once"
set +e
DEBIAN_MOUNTPOINT_INACTIVE_STATUS=1 \
DEBIAN_MOUNTPOINT_DIAGNOSTIC_TARGET=root \
DEBIAN_MOUNTPOINT_DIAGNOSTIC_KIND=identity-change-once \
    run_debian_builder >"${DEBIAN_FIXTURE}/mountpoint-identity-once.stdout" \
    2>"${DEBIAN_FIXTURE}/mountpoint-identity-once.stderr"
DEBIAN_MOUNTPOINT_IDENTITY_ONCE_STATUS=$?
set -e
DEBIAN_IDENTITY_ONCE_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_MOUNTPOINT_IDENTITY_ONCE_STATUS}" -ne 0 ||
    fail 'Debian builder forgot a one-shot mountpoint identity change'
test -d "${DEBIAN_IDENTITY_ONCE_MOUNT_DIR}" ||
    fail 'Debian builder removed a root after a one-shot identity change'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop after a one-shot identity change'

# A one-shot mountpoint query error is equally irreversible.  Cleanup must not
# accept a later healthy query and proceed with detach/removal.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
rm -f "${DEBIAN_SIGNAL_STATE}.mountpoint-error-once"
set +e
DEBIAN_MOUNTPOINT_ERROR_ONCE_TARGET=root run_debian_builder \
    >"${DEBIAN_FIXTURE}/mountpoint-error-once.stdout" \
    2>"${DEBIAN_FIXTURE}/mountpoint-error-once.stderr"
DEBIAN_MOUNTPOINT_ERROR_ONCE_STATUS=$?
set -e
DEBIAN_ERROR_ONCE_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_MOUNTPOINT_ERROR_ONCE_STATUS}" -ne 0 ||
    fail 'Debian builder forgot a one-shot mountpoint query error'
test -d "${DEBIAN_ERROR_ONCE_MOUNT_DIR}" ||
    fail 'Debian builder removed a root after a one-shot mountpoint query error'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop after a one-shot mountpoint query error'

# The host mountpoint may be removed only with rmdir after all mounts are known
# safe.  A non-empty directory must be retained; recursive removal is forbidden.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_ROOT_UNMOUNT_SENTINEL=1 run_debian_builder \
    >"${DEBIAN_FIXTURE}/nonempty-mount-dir.stdout" \
    2>"${DEBIAN_FIXTURE}/nonempty-mount-dir.stderr"
DEBIAN_NONEMPTY_MOUNT_STATUS=$?
set -e
DEBIAN_NONEMPTY_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_NONEMPTY_MOUNT_STATUS}" -ne 0 ||
    fail 'Debian builder ignored a non-empty host mount directory'
test -f "${DEBIAN_NONEMPTY_MOUNT_DIR}/host-sentinel" ||
    fail 'Debian builder recursively deleted a non-empty host mount directory'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 1 ||
    fail 'Debian builder did not detach before refusing a non-empty mount directory'

# A failure in the EXIT-only mount-directory removal turns an otherwise
# successful build into a failure and leaves the directory for inspection.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_RMDIR_FAIL_KIND=root run_debian_builder \
    >"${DEBIAN_FIXTURE}/mount-dir-cleanup.stdout" \
    2>"${DEBIAN_FIXTURE}/mount-dir-cleanup.stderr"
DEBIAN_MOUNT_DIR_CLEANUP_STATUS=$?
set -e
test "${DEBIAN_MOUNT_DIR_CLEANUP_STATUS}" -ne 0 ||
    fail 'Debian builder ignored mount-directory removal failure after success'
DEBIAN_UNREMOVED_MOUNT_DIR="$(sed -n 's/^rmdir-root-failed://p' "${DEBIAN_LOG}" | tail -1)"
test -n "${DEBIAN_UNREMOVED_MOUNT_DIR}" && test -d "${DEBIAN_UNREMOVED_MOUNT_DIR}" ||
    fail 'Debian fixture did not retain the rootfs directory after rmdir failure'
grep -Fq 'Could not remove rootfs work directory' \
    "${DEBIAN_FIXTURE}/mount-dir-cleanup.stderr" ||
    fail 'Debian cleanup did not report mount-directory removal failure'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 1 ||
    fail 'Debian cleanup did not detach before attempting mount-directory removal'

# A loop detach error participates in the same aggregate cleanup result.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_LOSETUP_DETACH_RESULT=69 run_debian_builder \
    >"${DEBIAN_FIXTURE}/loop-cleanup.stdout" \
    2>"${DEBIAN_FIXTURE}/loop-cleanup.stderr"
DEBIAN_LOOP_CLEANUP_STATUS=$?
set -e
test "${DEBIAN_LOOP_CLEANUP_STATUS}" -ne 0 ||
    fail 'Debian builder ignored loop detach failure'
grep -Fq 'Could not detach loop device /dev/loop-fixture' \
    "${DEBIAN_FIXTURE}/loop-cleanup.stderr" ||
    fail 'Debian cleanup did not report loop detach failure'

# Cleanup must report a failed removal of an in-progress initramfs workspace,
# while retaining the earlier build failure as the primary exit status.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_WITH_INITRD=1 DEBIAN_CPIO_RESULT=49 DEBIAN_RM_FAIL_KIND=repack \
    run_debian_builder >"${DEBIAN_FIXTURE}/repack-cleanup.stdout" \
    2>"${DEBIAN_FIXTURE}/repack-cleanup.stderr"
DEBIAN_REPACK_CLEANUP_STATUS=$?
set -e
test "${DEBIAN_REPACK_CLEANUP_STATUS}" -eq 49 ||
    fail "Debian cleanup replaced the initramfs failure: ${DEBIAN_REPACK_CLEANUP_STATUS}"
DEBIAN_REPACK_DIR="$(sed -n 's/^rm-repack-failed://p' "${DEBIAN_LOG}" | tail -1)"
test -n "${DEBIAN_REPACK_DIR}" && test -d "${DEBIAN_REPACK_DIR}" ||
    fail 'Debian fixture did not retain the initramfs directory after rm failure'
grep -Fq 'Could not remove initramfs work directory' \
    "${DEBIAN_FIXTURE}/repack-cleanup.stderr" ||
    fail 'Debian cleanup did not report the initramfs removal failure'

# Signals delivered after umount and during its mountpoint verification must
# be deferred until the tracked state is current.  Cleanup must then remain
# idempotent and finish even when a second signal arrives in that window.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
rm -f "${DEBIAN_SIGNAL_STATE}.first" "${DEBIAN_SIGNAL_STATE}.second"
set +e
DEBIAN_SIGNAL_DURING_UMOUNT_TARGET=root \
DEBIAN_SECOND_SIGNAL_DURING_VERIFY_TARGET=root \
    run_debian_builder >"${DEBIAN_FIXTURE}/unmount-signals.stdout" \
    2>"${DEBIAN_FIXTURE}/unmount-signals.stderr"
DEBIAN_UNMOUNT_SIGNALS_STATUS=$?
set -e
DEBIAN_SIGNAL_MOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_UNMOUNT_SIGNALS_STATUS}" -eq 130 ||
    fail "Debian builder did not preserve the final deferred signal status: ${DEBIAN_UNMOUNT_SIGNALS_STATUS}"
test -e "${DEBIAN_SIGNAL_STATE}.first" &&
    test -e "${DEBIAN_SIGNAL_STATE}.second" ||
    fail 'Debian builder did not exercise both unmount signal windows'
test "$(grep -Fc "umount-root:${DEBIAN_SIGNAL_MOUNT_DIR}" "${DEBIAN_LOG}" || true)" -eq 1 ||
    fail 'Debian cleanup retried a root already unmounted before a signal'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 1 ||
    fail 'Debian signal cleanup did not detach the loop exactly once'
test ! -e "${DEBIAN_SIGNAL_MOUNT_DIR}" ||
    fail 'Debian signal cleanup left its unmounted work directory'

: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
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
: >"${DEBIAN_MOUNT_STATE}"
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

# A successful umount return is not sufficient: if mountpoint still reports
# the root active, cleanup must fail closed without detaching or deleting it.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_UMOUNT_STICKY_TARGET=root run_debian_builder \
    >"${DEBIAN_FIXTURE}/sticky-root.stdout" \
    2>"${DEBIAN_FIXTURE}/sticky-root.stderr"
DEBIAN_STICKY_ROOT_STATUS=$?
set -e
DEBIAN_STICKY_ROOT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_STICKY_ROOT_STATUS}" -ne 0 ||
    fail 'Debian builder ignored a root that remained mounted after successful umount'
test -d "${DEBIAN_STICKY_ROOT_DIR}" ||
    fail 'Debian builder removed a root that remained mounted'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop device while the root remained mounted'

# A transient contradiction is still unsafe.  If umount reports success while
# the target remains mounted once, cleanup must not retry into an apparently
# healthy state and then detach or remove the loop-backed root.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
rm -f "${DEBIAN_SIGNAL_STATE}.umount-sticky-once"
set +e
DEBIAN_UMOUNT_STICKY_ONCE_TARGET=root run_debian_builder \
    >"${DEBIAN_FIXTURE}/sticky-root-once.stdout" \
    2>"${DEBIAN_FIXTURE}/sticky-root-once.stderr"
DEBIAN_STICKY_ROOT_ONCE_STATUS=$?
set -e
DEBIAN_STICKY_ROOT_ONCE_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_STICKY_ROOT_ONCE_STATUS}" -ne 0 ||
    fail 'Debian builder forgot a transient contradictory unmount result'
test -d "${DEBIAN_STICKY_ROOT_ONCE_DIR}" ||
    fail 'Debian builder removed a root after a contradictory unmount result'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop after a contradictory unmount result'
test "$(grep -c '^umount-root:' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian cleanup retried a target after a contradictory unmount result'

# An uncertain mountpoint query must fail closed even after umount returned
# success; otherwise cleanup cannot prove that recursive removal is safe.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_MOUNTPOINT_ERROR_TARGET=root run_debian_builder \
    >"${DEBIAN_FIXTURE}/uncertain-root.stdout" \
    2>"${DEBIAN_FIXTURE}/uncertain-root.stderr"
DEBIAN_UNCERTAIN_ROOT_STATUS=$?
set -e
DEBIAN_UNCERTAIN_ROOT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_UNCERTAIN_ROOT_STATUS}" -ne 0 ||
    fail 'Debian builder treated an uncertain mount query as unmounted'
test -d "${DEBIAN_UNCERTAIN_ROOT_DIR}" ||
    fail 'Debian builder removed a root whose mount state was uncertain'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop after an uncertain mount query'

# A child unmount failure keeps the root busy.  Neither the loop nor the work
# directory may be removed, and the unmount failure must remain visible.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_UMOUNT_FAIL_TARGET=/dev run_debian_builder \
    >"${DEBIAN_FIXTURE}/child-unmount.stdout" \
    2>"${DEBIAN_FIXTURE}/child-unmount.stderr"
DEBIAN_CHILD_UNMOUNT_STATUS=$?
set -e
DEBIAN_CHILD_UNMOUNT_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_CHILD_UNMOUNT_STATUS}" -ne 0 ||
    fail 'Debian builder ignored a child unmount failure'
test -d "${DEBIAN_CHILD_UNMOUNT_DIR}" ||
    fail 'Debian builder removed a root with a mounted child'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'Debian builder detached its loop device with a mounted child'

# Cleanup trouble must not replace an earlier, meaningful build failure.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
set +e
DEBIAN_STAGE_RESULT=37 DEBIAN_UMOUNT_STICKY_TARGET=root run_debian_builder \
    >"${DEBIAN_FIXTURE}/failure-with-sticky-root.stdout" \
    2>"${DEBIAN_FIXTURE}/failure-with-sticky-root.stderr"
DEBIAN_FAILURE_WITH_CLEANUP_STATUS=$?
set -e
DEBIAN_FAILURE_WITH_CLEANUP_DIR="$(cat "${DEBIAN_MOUNT_FILE}")"
test "${DEBIAN_FAILURE_WITH_CLEANUP_STATUS}" -eq 37 ||
    fail "cleanup replaced original stage status: ${DEBIAN_FAILURE_WITH_CLEANUP_STATUS}"
test -d "${DEBIAN_FAILURE_WITH_CLEANUP_DIR}" ||
    fail 'cleanup removed a mounted root after the original stage failure'
test "$(grep -c '^losetup-detach$' "${DEBIAN_LOG}" || true)" -eq 0 ||
    fail 'cleanup detached a mounted root after the original stage failure'

# A sudo-driven build must prepare tools as the invoking user so a later
# unprivileged rebuild can replace them.  The fake sudo models target-user
# mkdir/write denial, so these assertions do not rely on the root test runner's
# own access checks.  Direct-root cases above remain valid.
rm -rf "${DEBIAN_FIXTURE}/build/guest_tools"
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
: >"${DEBIAN_SUDO_LOG}"
SUDO_USER=fixture-builder DEBIAN_EXPECT_BUILD_USER=fixture-builder \
    DEBIAN_ENFORCE_BUILD_USER_BOUNDARIES=1 \
    run_debian_builder >"${DEBIAN_FIXTURE}/sudo-user.stdout" \
    2>"${DEBIAN_FIXTURE}/sudo-user.stderr" ||
    fail "Debian builder did not build as SUDO_USER: $(<"${DEBIAN_FIXTURE}/sudo-user.stderr")"
test "$(cat "${DEBIAN_BUILD_USER_LOG}")" = fixture-builder ||
    fail 'Debian debug utility helper did not run as the invoking user'
for boundary in \
    "mkdir:${DEBIAN_FIXTURE}/build/guest_tools:fixture-builder" \
    "mkdir:${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils:fixture-builder" \
    "write:${DEBIAN_FIXTURE}/build:fixture-builder" \
    "write:${DEBIAN_FIXTURE}/build/tmp:fixture-builder" \
    "write:${DEBIAN_FIXTURE}/build/guest_tools:fixture-builder" \
    "write:${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils:fixture-builder" \
    "helper:${DEBIAN_FIXTURE}/scripts/build_dpu_debugutils.sh:fixture-builder" \
    "write:${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils/pci_debug:fixture-builder" \
    "write:${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils/reg_display:fixture-builder"; do
    grep -Fxq "$boundary" "${DEBIAN_SUDO_LOG}" ||
        fail "Debian builder skipped invoking-user boundary: $boundary"
done

# A modeled target-user write denial must stop before any image operation,
# even though the root test process itself can write the file.
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
: >"${DEBIAN_SUDO_LOG}"
set +e
SUDO_USER=fixture-builder DEBIAN_EXPECT_BUILD_USER=fixture-builder \
    DEBIAN_ENFORCE_BUILD_USER_BOUNDARIES=1 \
    DEBIAN_SUDO_DENY_WRITE_PATH="${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils/reg_display" \
    run_debian_builder >"${DEBIAN_FIXTURE}/sudo-user-write-denied.stdout" \
    2>"${DEBIAN_FIXTURE}/sudo-user-write-denied.stderr"
DEBIAN_SUDO_WRITE_DENIED_STATUS=$?
set -e
test "${DEBIAN_SUDO_WRITE_DENIED_STATUS}" -ne 0 ||
    fail 'Debian builder ignored invoking-user write denial'
grep -Fxq "write:${DEBIAN_FIXTURE}/build/guest_tools/dpu-debugutils/reg_display:fixture-builder" \
    "${DEBIAN_SUDO_LOG}" ||
    fail 'Debian builder did not ask the invoking user to validate reg_display writability'
test "$(cat "${DEBIAN_LOG}")" = build ||
    fail 'Debian builder modified the image after invoking-user write denial'

# Directory creation is also an invoking-user boundary.  A modeled denial is
# propagated before the helper and before image creation.
rm -rf "${DEBIAN_FIXTURE}/build/guest_tools"
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
: >"${DEBIAN_SUDO_LOG}"
set +e
SUDO_USER=fixture-builder DEBIAN_EXPECT_BUILD_USER=fixture-builder \
    DEBIAN_ENFORCE_BUILD_USER_BOUNDARIES=1 \
    DEBIAN_SUDO_DENY_MKDIR_PATH="${DEBIAN_FIXTURE}/build/guest_tools" \
    run_debian_builder >"${DEBIAN_FIXTURE}/sudo-user-mkdir-denied.stdout" \
    2>"${DEBIAN_FIXTURE}/sudo-user-mkdir-denied.stderr"
DEBIAN_SUDO_MKDIR_DENIED_STATUS=$?
set -e
test "${DEBIAN_SUDO_MKDIR_DENIED_STATUS}" -eq 52 ||
    fail "Debian builder did not propagate invoking-user mkdir denial: ${DEBIAN_SUDO_MKDIR_DENIED_STATUS}"
grep -Fxq "mkdir:${DEBIAN_FIXTURE}/build/guest_tools:fixture-builder" \
    "${DEBIAN_SUDO_LOG}" ||
    fail 'Debian builder did not create guest_tools through the invoking-user runner'
test ! -s "${DEBIAN_LOG}" ||
    fail 'Debian builder invoked the helper after invoking-user mkdir denial'

: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
: >"${DEBIAN_SUDO_LOG}"
set +e
SUDO_USER=fixture-builder DEBIAN_EXPECT_BUILD_USER=fixture-builder \
    DEBIAN_ENFORCE_BUILD_USER_BOUNDARIES=1 DEBIAN_BUILD_RESULT=39 \
    run_debian_builder \
    >"${DEBIAN_FIXTURE}/sudo-user-build-failure.stdout" \
    2>"${DEBIAN_FIXTURE}/sudo-user-build-failure.stderr"
DEBIAN_SUDO_BUILD_STATUS=$?
set -e
test "${DEBIAN_SUDO_BUILD_STATUS}" -eq 39 ||
    fail "SUDO_USER build failure was not preserved: ${DEBIAN_SUDO_BUILD_STATUS}"
test "$(cat "${DEBIAN_BUILD_USER_LOG}")" = fixture-builder ||
    fail 'failing debug utility helper did not run as the invoking user'
test "$(cat "${DEBIAN_LOG}")" = build ||
    fail 'Debian builder modified the image after invoking-user build failure'

# Generic Guest tools are copied separately; the debugutils directory itself
# must not leak into /usr/local/bin before the staging helper installs binaries.
printf '#!/bin/sh\nexit 0\n' >"${DEBIAN_FIXTURE}/build/guest_tools/other_tool"
chmod 0755 "${DEBIAN_FIXTURE}/build/guest_tools/other_tool"
: >"${DEBIAN_LOG}"
: >"${DEBIAN_MOUNT_STATE}"
if ! DEBIAN_CHECK_FINAL_TOOLS_TREE=1 run_debian_builder \
        >"${DEBIAN_FIXTURE}/final-tools-tree.stdout" \
        2>"${DEBIAN_FIXTURE}/final-tools-tree.stderr"; then
    fail "Debian builder leaked the debugutils directory into the Guest: $(<"${DEBIAN_FIXTURE}/final-tools-tree.stderr")"
fi
EXPECTED_DEBIAN_TOOLS_TREE=$'other_tool\npci_debug\nreg_display'
test "$(cat "${DEBIAN_GUEST_TOOLS_TREE}")" = "${EXPECTED_DEBIAN_TOOLS_TREE}" ||
    fail "unexpected final Guest tools tree: $(tr '\n' ' ' <"${DEBIAN_GUEST_TOOLS_TREE}")"

# Root must not follow repository build-path symlinks before invoking a helper.
mv "${DEBIAN_FIXTURE}/build" "${DEBIAN_FIXTURE}/build.real"
mkdir -p "${DEBIAN_FIXTURE}/escaped-build/tmp"
ln -s "${DEBIAN_FIXTURE}/escaped-build" "${DEBIAN_FIXTURE}/build"
: >"${DEBIAN_LOG}"
set +e
run_debian_builder >"${DEBIAN_FIXTURE}/symlink-build.stdout" \
    2>"${DEBIAN_FIXTURE}/symlink-build.stderr"
DEBIAN_SYMLINK_BUILD_STATUS=$?
set -e
test "${DEBIAN_SYMLINK_BUILD_STATUS}" -ne 0 ||
    fail 'Debian builder accepted a symlinked repository build directory'
test ! -s "${DEBIAN_LOG}" ||
    fail 'Debian builder invoked the helper through a symlinked build directory'
rm "${DEBIAN_FIXTURE}/build"
mv "${DEBIAN_FIXTURE}/build.real" "${DEBIAN_FIXTURE}/build"

mv "${DEBIAN_FIXTURE}/build/tmp" "${DEBIAN_FIXTURE}/build/tmp.real"
mkdir -p "${DEBIAN_FIXTURE}/escaped-tmp"
ln -s "${DEBIAN_FIXTURE}/escaped-tmp" "${DEBIAN_FIXTURE}/build/tmp"
: >"${DEBIAN_LOG}"
set +e
run_debian_builder >"${DEBIAN_FIXTURE}/symlink-build-tmp.stdout" \
    2>"${DEBIAN_FIXTURE}/symlink-build-tmp.stderr"
DEBIAN_SYMLINK_TMP_STATUS=$?
set -e
test "${DEBIAN_SYMLINK_TMP_STATUS}" -ne 0 ||
    fail 'Debian builder accepted a symlinked repository build/tmp directory'
test ! -s "${DEBIAN_LOG}" ||
    fail 'Debian builder invoked the helper through symlinked build/tmp'
rm "${DEBIAN_FIXTURE}/build/tmp"
mv "${DEBIAN_FIXTURE}/build/tmp.real" "${DEBIAN_FIXTURE}/build/tmp"

echo '[stage-guest-debugutils] PASS'
