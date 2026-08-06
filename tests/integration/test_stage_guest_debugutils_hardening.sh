#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE_SCRIPT="${REPO_ROOT}/scripts/stage_guest_debugutils.sh"
INSTALL_SCRIPT="${REPO_ROOT}/scripts/install_guest_debugutils.sh"
SOURCE_DIR="${REPO_ROOT}/third_party/dpu-debugutils"
REAL_FILE="$(command -v file)"
REAL_MKTEMP="$(command -v mktemp)"

mkdir -p "${REPO_ROOT}/build/tmp"
WORK_DIR="$(mktemp -d "${REPO_ROOT}/build/tmp/test-stage-hardening.XXXXXX")"
TERM_CREATED_DIR_FILE="${WORK_DIR}/term-created-dir"

cleanup() {
    local status=$?
    local leaked_dir=''
    trap - EXIT
    if [[ -f "${TERM_CREATED_DIR_FILE}" ]]; then
        leaked_dir="$(cat "${TERM_CREATED_DIR_FILE}")"
        case "${leaked_dir}" in
            "${REPO_ROOT}/build/tmp/stage-debugutils."*)
                rm -rf -- "${leaked_dir}"
                ;;
        esac
    fi
    rm -rf -- "${WORK_DIR}"
    exit "${status}"
}
trap cleanup EXIT

fail() {
    echo "[stage-debugutils-hardening] FAIL: $*" >&2
    exit 1
}

make_static_fixture() {
    local case_dir=$1

    CASE_BIN_DIR="${case_dir}/static bin"
    CASE_SHIM_DIR="${case_dir}/static shim"
    mkdir -p "${CASE_BIN_DIR}" "${CASE_SHIM_DIR}"
    printf 'verified pci binary\n' >"${CASE_BIN_DIR}/pci_debug"
    printf 'verified reg binary\n' >"${CASE_BIN_DIR}/reg_display"
    chmod 0755 "${CASE_BIN_DIR}/pci_debug" "${CASE_BIN_DIR}/reg_display"

    export REAL_FILE
    cat >"${CASE_SHIM_DIR}/file" <<'FILE_SHIM'
#!/usr/bin/env bash
set -euo pipefail

target=${@: -1}
case "${target##*/}" in
    pci_debug|reg_display)
        printf '%s: ELF fixture executable, statically linked\n' "${target}"
        ;;
    *)
        exec "${REAL_FILE}" "$@"
        ;;
esac
FILE_SHIM
    chmod 0755 "${CASE_SHIM_DIR}/file"
}

run_stage() {
    local root=$1
    shift

    set +e
    PATH="${CASE_SHIM_DIR}:${PATH}" "${STAGE_SCRIPT}" \
        --root "${root}" --bin-dir "${CASE_BIN_DIR}" "$@" \
        >"${WORK_DIR}/stage.stdout" 2>"${WORK_DIR}/stage.stderr"
    STAGE_STATUS=$?
    set -e
}

test_symlink_absolute() {
    local case_dir="${WORK_DIR}/symlink absolute"
    local root="${case_dir}/root"
    local outside="${case_dir}/outside host"
    mkdir -p "${root}/usr" "${outside}"
    printf 'host sentinel\n' >"${outside}/sentinel"
    ln -s "${outside}" "${root}/usr/local"
    make_static_fixture "${case_dir}"

    run_stage "${root}"

    [[ "${STAGE_STATUS}" -ne 0 ]] || fail 'absolute usr/local symlink was accepted'
    [[ "$(cat "${outside}/sentinel")" == 'host sentinel' ]] ||
        fail 'absolute symlink changed host sentinel'
    [[ ! -e "${outside}/bin" && ! -e "${outside}/share" ]] ||
        fail 'absolute usr/local symlink escaped the target root'
}

test_symlink_relative() {
    local case_dir="${WORK_DIR}/symlink relative"
    local root="${case_dir}/root"
    local outside="${case_dir}/outside host"
    local relative_target
    mkdir -p "${root}" "${outside}"
    printf 'host sentinel\n' >"${outside}/sentinel"
    relative_target="$(realpath --relative-to="${root}" "${outside}")"
    ln -s "${relative_target}" "${root}/opt"
    make_static_fixture "${case_dir}"

    run_stage "${root}" --source-dir "${SOURCE_DIR}" --include-source

    [[ "${STAGE_STATUS}" -ne 0 ]] || fail 'relative opt symlink was accepted'
    [[ "$(cat "${outside}/sentinel")" == 'host sentinel' ]] ||
        fail 'relative symlink changed host sentinel'
    [[ ! -e "${outside}/dpu-debugutils" ]] ||
        fail 'relative opt symlink escaped the target root'
    [[ ! -e "${root}/usr" ]] ||
        fail 'target root changed before relative opt symlink rejection'
}

test_symlink_final() {
    local case_dir="${WORK_DIR}/symlink final"
    local root="${case_dir}/root"
    local outside="${case_dir}/outside host"
    mkdir -p "${root}/usr/local/bin" "${outside}"
    printf 'host executable sentinel\n' >"${outside}/pci-target"
    ln -s "${outside}/pci-target" "${root}/usr/local/bin/pci_debug"
    make_static_fixture "${case_dir}"

    run_stage "${root}"

    [[ "${STAGE_STATUS}" -ne 0 ]] || fail 'final binary symlink was accepted'
    [[ "$(cat "${outside}/pci-target")" == 'host executable sentinel' ]] ||
        fail 'final binary symlink overwrote host content'
    [[ ! -e "${root}/usr/local/bin/reg_display" ]] ||
        fail 'target root changed before final symlink rejection'
}

test_binary_snapshot() {
    local case_dir="${WORK_DIR}/binary snapshot"
    local root="${case_dir}/root"
    local expected="${case_dir}/expected-pci"
    local tampered="${case_dir}/tampered-pci"
    local marker="${case_dir}/attack-ran"
    mkdir -p "${root}"
    make_static_fixture "${case_dir}"
    cp "${CASE_BIN_DIR}/pci_debug" "${expected}"
    printf 'tampered after validation\n' >"${tampered}"

    export ORIGINAL_PCI="${CASE_BIN_DIR}/pci_debug"
    export TAMPERED_PCI="${tampered}"
    export TAMPER_MARKER="${marker}"
    cat >"${CASE_SHIM_DIR}/file" <<'TOCTOU_FILE_SHIM'
#!/usr/bin/env bash
set -euo pipefail

target=${@: -1}
if [[ ! -e "${TAMPER_MARKER}" ]]; then
    cp "${TAMPERED_PCI}" "${ORIGINAL_PCI}"
    chmod 0755 "${ORIGINAL_PCI}"
    : >"${TAMPER_MARKER}"
fi
case "${target##*/}" in
    pci_debug|reg_display)
        printf '%s: ELF fixture executable, statically linked\n' "${target}"
        ;;
    *)
        exec "${REAL_FILE}" "$@"
        ;;
esac
TOCTOU_FILE_SHIM
    chmod 0755 "${CASE_SHIM_DIR}/file"

    run_stage "${root}"

    [[ "${STAGE_STATUS}" -eq 0 ]] || fail 'snapshot staging failed unexpectedly'
    [[ -e "${marker}" ]] || fail 'TOCTOU mutation did not run'
    cmp "${tampered}" "${ORIGINAL_PCI}" || fail 'source binary was not mutated'
    cmp "${expected}" "${root}/usr/local/bin/pci_debug" ||
        fail 'installed binary was read again after validation'
}

make_wrapper_fixture() {
    local case_dir=$1

    W_IMAGE="${case_dir}/fake ext4 image"
    W_BIN_DIR="${case_dir}/bin dir"
    W_SHIM_DIR="${case_dir}/wrapper shim"
    W_EVENTS="${case_dir}/events"
    W_MOUNT_ARGS="${case_dir}/mount-args"
    W_MOUNT_DIR_FILE="${case_dir}/mount-dir"
    W_MARKER="${case_dir}/mounted-marker"
    mkdir -p "${W_BIN_DIR}" "${W_SHIM_DIR}"
    printf 'fake image\n' >"${W_IMAGE}"

    export W_IMAGE W_EVENTS W_MOUNT_ARGS W_MOUNT_DIR_FILE W_MARKER REAL_FILE
    cat >"${W_SHIM_DIR}/file" <<'IMAGE_FILE_SHIM'
#!/usr/bin/env bash
set -euo pipefail

target=${@: -1}
if [[ "${target}" == "${W_IMAGE}" ]]; then
    printf '%s: Linux rev 1.0 ext4 filesystem data\n' "${target}"
else
    exec "${REAL_FILE}" "$@"
fi
IMAGE_FILE_SHIM

    cat >"${W_SHIM_DIR}/sudo" <<'SUDO_SHIM'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == -n ]] || exit 98
shift
command_path=${1:?missing command}
shift
case "${command_path##*/}" in
    mount)
        printf 'mount\n' >>"${W_EVENTS}"
        {
            printf 'mount'
            for argument in "$@"; do printf '|%s' "${argument}"; done
            printf '\n'
        } >"${W_MOUNT_ARGS}"
        printf '%s\n' "${@: -1}" >"${W_MOUNT_DIR_FILE}"
        case "${WRAPPER_MODE:-success}" in
            mount-term)
                kill -TERM "${PPID}"
                ;;
            mount-failure)
                : >"${W_MARKER}"
                exit 32
                ;;
        esac
        ;;
    stage_guest_debugutils.sh)
        printf 'stage\n' >>"${W_EVENTS}"
        ;;
    umount)
        printf 'umount\n' >>"${W_EVENTS}"
        if [[ "${WRAPPER_MODE:-success}" == umount-failure ]]; then
            exit 32
        fi
        rm -f "${W_MARKER}"
        ;;
    e2fsck)
        printf 'e2fsck\n' >>"${W_EVENTS}"
        if [[ "${WRAPPER_MODE:-success}" == fsck-failure ]]; then
            exit 2
        fi
        exit 1
        ;;
    *)
        exit 97
        ;;
esac
SUDO_SHIM

    cat >"${W_SHIM_DIR}/mountpoint" <<'MOUNTPOINT_SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf 'mountpoint\n' >>"${W_EVENTS}"
[[ -e "${W_MARKER}" ]]
MOUNTPOINT_SHIM
    chmod 0755 "${W_SHIM_DIR}/file" "${W_SHIM_DIR}/sudo" \
        "${W_SHIM_DIR}/mountpoint"
}

run_wrapper() {
    local mode=$1

    set +e
    PATH="${W_SHIM_DIR}:${PATH}" WRAPPER_MODE="${mode}" \
        "${INSTALL_SCRIPT}" --rootfs "${W_IMAGE}" --bin-dir "${W_BIN_DIR}" \
        >"${WORK_DIR}/wrapper.stdout" 2>"${WORK_DIR}/wrapper.stderr"
    WRAPPER_STATUS=$?
    set -e
}

test_mount_term() {
    local case_dir="${WORK_DIR}/mount term"
    mkdir -p "${case_dir}"
    make_wrapper_fixture "${case_dir}"
    run_wrapper mount-term

    [[ "${WRAPPER_STATUS}" -eq 143 ]] ||
        fail "TERM during mount returned ${WRAPPER_STATUS}, expected 143"
    [[ "$(cat "${W_EVENTS}")" == $'mount\numount\ne2fsck' ]] ||
        fail "TERM cleanup sequence was: $(tr '\n' ' ' <"${W_EVENTS}")"
    [[ ! -e "$(cat "${W_MOUNT_DIR_FILE}")" ]] ||
        fail 'TERM during mount left the mount directory'
}

test_pre_mount_term() {
    local case_dir="${WORK_DIR}/pre mount term"
    local created_dir_file="${case_dir}/created-mount-dir"
    local created_dir
    mkdir -p "${case_dir}"
    make_wrapper_fixture "${case_dir}"
    export REAL_MKTEMP PRE_MOUNT_CREATED_DIR_FILE="${created_dir_file}"
    cat >"${W_SHIM_DIR}/mktemp" <<'PRE_MOUNT_MKTEMP_SHIM'
#!/usr/bin/env bash
set -euo pipefail

created_dir="$("${REAL_MKTEMP}" "$@")"
printf '%s\n' "${created_dir}"
printf '%s\n' "${created_dir}" >"${PRE_MOUNT_CREATED_DIR_FILE}"
kill -TERM "${PPID}"
PRE_MOUNT_MKTEMP_SHIM
    chmod 0755 "${W_SHIM_DIR}/mktemp"

    run_wrapper pre-mount-term
    created_dir="$(cat "${created_dir_file}")"

    [[ "${WRAPPER_STATUS}" -eq 143 ]] ||
        fail "TERM before mount returned ${WRAPPER_STATUS}, expected 143"
    [[ ! -s "${W_EVENTS}" ]] ||
        fail "TERM before mount still invoked: $(tr '\n' ' ' <"${W_EVENTS}")"
    [[ ! -e "${created_dir}" ]] ||
        fail 'TERM before mount left the mount directory'
}

test_stage_term() {
    local case_dir="${WORK_DIR}/stage term"
    local root="${case_dir}/root"
    local before after
    mkdir -p "${root}"
    make_static_fixture "${case_dir}"
    export TERM_MARKER="${case_dir}/term-sent"
    export REAL_MKTEMP TERM_CREATED_DIR_FILE
    cat >"${CASE_SHIM_DIR}/mktemp" <<'TERM_MKTEMP_SHIM'
#!/usr/bin/env bash
set -euo pipefail

created_dir="$("${REAL_MKTEMP}" "$@")"
printf '%s\n' "${created_dir}"
printf '%s\n' "${created_dir}" >"${TERM_CREATED_DIR_FILE}"
: >"${TERM_MARKER}"
kill -TERM "${PPID}"
TERM_MKTEMP_SHIM
    chmod 0755 "${CASE_SHIM_DIR}/mktemp"
    before="$(find "${REPO_ROOT}/build/tmp" -maxdepth 1 \
        -type d -name 'stage-debugutils.*' -printf '%f\n' | sort)"

    run_stage "${root}"

    after="$(find "${REPO_ROOT}/build/tmp" -maxdepth 1 \
        -type d -name 'stage-debugutils.*' -printf '%f\n' | sort)"
    [[ "${STAGE_STATUS}" -eq 143 ]] ||
        fail "TERM during staging returned ${STAGE_STATUS}, expected 143"
    [[ -e "${TERM_MARKER}" ]] || fail 'TERM mktemp injection did not run'
    [[ "${before}" == "${after}" ]] || fail 'TERM left a staging work directory'
    [[ ! -e "${root}/usr" ]] || fail 'TERM staging modified the target root'
}

test_mount_flags() {
    local case_dir="${WORK_DIR}/mount flags"
    local mount_dir expected
    mkdir -p "${case_dir}"
    make_wrapper_fixture "${case_dir}"
    run_wrapper success
    mount_dir="$(cat "${W_MOUNT_DIR_FILE}")"
    expected="mount|-t|ext4|-o|loop,nosuid,nodev,noexec|${W_IMAGE}|${mount_dir}"

    [[ "${WRAPPER_STATUS}" -eq 0 ]] || fail 'mount flag lifecycle failed'
    [[ "$(cat "${W_MOUNT_ARGS}")" == "${expected}" ]] ||
        fail "mount arguments were: $(cat "${W_MOUNT_ARGS}")"
}

test_build_tmp_symlink() {
    local case_dir="${WORK_DIR}/build tmp symlink"
    local fake_repo="${case_dir}/trusted repo"
    local outside="${case_dir}/outside temp"
    local root="${case_dir}/root"
    mkdir -p "${fake_repo}/scripts" "${fake_repo}/build" "${outside}" "${root}"
    cp "${STAGE_SCRIPT}" "${fake_repo}/scripts/stage_guest_debugutils.sh"
    chmod 0755 "${fake_repo}/scripts/stage_guest_debugutils.sh"
    ln -s "${outside}" "${fake_repo}/build/tmp"
    make_static_fixture "${case_dir}"

    set +e
    PATH="${CASE_SHIM_DIR}:${PATH}" "${fake_repo}/scripts/stage_guest_debugutils.sh" \
        --root "${root}" --bin-dir "${CASE_BIN_DIR}" \
        >"${WORK_DIR}/build-tree.stdout" 2>"${WORK_DIR}/build-tree.stderr"
    local status=$?
    set -e

    [[ "${status}" -ne 0 ]] || fail 'symlinked repo/build/tmp was accepted'
    [[ ! -e "${root}/usr" ]] ||
        fail 'target root changed before build/tmp symlink rejection'
}

test_mount_failure() {
    local case_dir="${WORK_DIR}/mount failure"
    mkdir -p "${case_dir}"
    make_wrapper_fixture "${case_dir}"
    run_wrapper mount-failure

    [[ "${WRAPPER_STATUS}" -ne 0 ]] || fail 'failed mount returned success'
    [[ "$(cat "${W_EVENTS}")" == $'mount\nmountpoint\numount\ne2fsck' ]] ||
        fail "uncertain mount cleanup was: $(tr '\n' ' ' <"${W_EVENTS}")"
    [[ ! -e "$(cat "${W_MOUNT_DIR_FILE}")" ]] ||
        fail 'failed mount left the mount directory'
}

test_umount_failure() {
    local case_dir="${WORK_DIR}/umount failure"
    mkdir -p "${case_dir}"
    make_wrapper_fixture "${case_dir}"
    run_wrapper umount-failure

    [[ "${WRAPPER_STATUS}" -ne 0 ]] || fail 'failed umount returned success'
    [[ "$(cat "${W_EVENTS}")" == $'mount\nstage\numount' ]] ||
        fail "failed umount lifecycle was: $(tr '\n' ' ' <"${W_EVENTS}")"
    [[ -d "$(cat "${W_MOUNT_DIR_FILE}")" ]] ||
        fail 'failed umount removed a potentially mounted directory'
    rmdir "$(cat "${W_MOUNT_DIR_FILE}")"
}

test_fsck_failure() {
    local case_dir="${WORK_DIR}/fsck failure"
    mkdir -p "${case_dir}"
    make_wrapper_fixture "${case_dir}"
    run_wrapper fsck-failure

    [[ "${WRAPPER_STATUS}" -ne 0 ]] || fail 'e2fsck status 2 returned success'
    [[ "$(cat "${W_EVENTS}")" == $'mount\nstage\numount\ne2fsck' ]] ||
        fail "fsck failure lifecycle was: $(tr '\n' ' ' <"${W_EVENTS}")"
    [[ ! -e "$(cat "${W_MOUNT_DIR_FILE}")" ]] ||
        fail 'fsck failure left the mount directory'
}

run_case() {
    case "$1" in
        symlink-absolute) test_symlink_absolute ;;
        symlink-relative) test_symlink_relative ;;
        symlink-final) test_symlink_final ;;
        binary-snapshot) test_binary_snapshot ;;
        mount-term) test_mount_term ;;
        pre-mount-term) test_pre_mount_term ;;
        stage-term) test_stage_term ;;
        mount-flags) test_mount_flags ;;
        build-tmp-symlink) test_build_tmp_symlink ;;
        mount-failure) test_mount_failure ;;
        umount-failure) test_umount_failure ;;
        fsck-failure) test_fsck_failure ;;
        *) fail "unknown hardening case: $1" ;;
    esac
    echo "[stage-debugutils-hardening:${1}] PASS"
}

if [[ $# -gt 0 ]]; then
    run_case "$1"
else
    for case_name in \
        symlink-absolute symlink-relative symlink-final binary-snapshot \
        mount-term pre-mount-term stage-term mount-flags build-tmp-symlink \
        mount-failure umount-failure fsck-failure; do
        "${BASH_SOURCE[0]}" "${case_name}"
    done
    echo '[stage-debugutils-hardening] PASS'
fi
