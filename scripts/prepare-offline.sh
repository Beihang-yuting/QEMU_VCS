#!/bin/bash
# ============================================================
# prepare-offline.sh — 在外网机器上打包离线安装包
#
# 用法: ./scripts/prepare-offline.sh [选项]
#   --guest ubuntu|ubuntu-server|debian   Guest 类型（默认 ubuntu）
#   --output <path>         输出 zip 路径（默认 cosim-offline-<date>.zip）
#   --skip-rootfs           跳过 rootfs 构建（已有镜像时）
#   --custom-driver <path>  DPU host-driver-net 源码包（可选）
#   --compat-runtime-deb <path>  DPU 编译兼容 libc6 .deb（可选）
#
# 产物: 一个 zip 文件，包含内网 setup.sh 所需的全部素材
# 内网使用: ./setup.sh 交互菜单选择"导入离线包"
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

prepare_project_tmp_root() {
    local tmp_root="$1" project_canonical expected_canonical
    local current component tmp_canonical identity_before identity_after
    local owner_uid current_uid mode

    project_canonical=$(cd -- "$PROJECT_DIR" && pwd -P) || {
        fail "无法解析项目目录: $PROJECT_DIR"
        return 1
    }
    expected_canonical="$project_canonical/build/tmp"
    [ "$tmp_root" = "${PROJECT_DIR}/build/tmp" ] || {
        fail "临时目录不在项目 build/tmp: $tmp_root"
        return 1
    }

    current=$PROJECT_DIR
    for component in build tmp; do
        current="$current/$component"
        if [ -L "$current" ]; then
            fail "项目 build/tmp 路径包含符号链接: $current"
            return 1
        fi
        if [ -e "$current" ]; then
            if [ ! -d "$current" ]; then
                fail "项目 build/tmp 路径不是目录: $current"
                return 1
            fi
        elif ! mkdir -- "$current"; then
            fail "无法创建项目临时目录: $current"
            return 1
        fi
        if [ -L "$current" ] || [ ! -d "$current" ]; then
            fail "项目 build/tmp 路径不安全: $current"
            return 1
        fi
    done

    tmp_canonical=$(cd -- "$tmp_root" && pwd -P) || return 1
    if [ "$tmp_canonical" != "$expected_canonical" ]; then
        fail "项目临时目录规范路径越界: $tmp_root"
        return 1
    fi
    current_uid=$(id -u) || return 1
    owner_uid=$(stat -c '%u' -- "$tmp_root") || return 1
    if [ "$owner_uid" != "$current_uid" ]; then
        fail "项目临时目录所有者不安全: $tmp_root"
        return 1
    fi
    identity_before=$(stat -Lc '%d:%i' -- "$tmp_root") || return 1
    chmod 0700 -- "$tmp_root" || return 1

    current=$PROJECT_DIR
    for component in build tmp; do
        current="$current/$component"
        if [ -L "$current" ] || [ ! -d "$current" ]; then
            fail "项目 build/tmp 路径在检查期间发生变化: $current"
            return 1
        fi
    done
    tmp_canonical=$(cd -- "$tmp_root" && pwd -P) || return 1
    identity_after=$(stat -Lc '%d:%i' -- "$tmp_root") || return 1
    owner_uid=$(stat -c '%u' -- "$tmp_root") || return 1
    mode=$(stat -c '%a' -- "$tmp_root") || return 1
    if [ "$tmp_canonical" != "$expected_canonical" ] ||
            [ "$identity_after" != "$identity_before" ] ||
            [ "$owner_uid" != "$current_uid" ] || [ "$mode" != 700 ]; then
        fail "项目临时目录安全属性在检查期间发生变化: $tmp_root"
        return 1
    fi
}

GUEST_TYPE="ubuntu"
SKIP_ROOTFS=false
OUTPUT=""
KVER="6.8.0-107-generic"
CUSTOM_DRIVER_ARCHIVE=""
COMPAT_RUNTIME_DEB=""
QEMU_VERSION="v9.2.0"
QEMU_RELEASE_URL="https://download.qemu.org/qemu-9.2.0.tar.xz"
QEMU_RELEASE_SHA256="f859f0bc65e1f533d040bbe8c92bcfecee5af2c921a6687c652fb44d089bd894"
QEMU_SOURCE_CLOSURE_VALIDATOR="${PROJECT_DIR}/scripts/validate-qemu-source-closure.py"

while [ $# -gt 0 ]; do
    case "$1" in
        --guest) GUEST_TYPE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --skip-rootfs) SKIP_ROOTFS=true; shift ;;
        --custom-driver) CUSTOM_DRIVER_ARCHIVE="$2"; shift 2 ;;
        --compat-runtime-deb) COMPAT_RUNTIME_DEB="$2"; shift 2 ;;
        --help|-h)
            echo "用法: $0 [--guest ubuntu|ubuntu-server|debian] [--output path.zip] [--custom-driver path.tar.gz] [--compat-runtime-deb libc6.deb] [--skip-rootfs]"
            exit 0 ;;
        *) fail "未知参数: $1"; exit 1 ;;
    esac
done

case "$GUEST_TYPE" in
    ubuntu|ubuntu-server|debian) ;;
    *) fail "不支持的 Guest 类型: $GUEST_TYPE"; exit 1 ;;
esac

OUTPUT="${OUTPUT:-${PROJECT_DIR}/cosim-offline-$(date +%Y%m%d).zip}"
TMP_ROOT="${PROJECT_DIR}/build/tmp"
prepare_project_tmp_root "$TMP_ROOT" || exit 1
STAGING=$(mktemp -d "$TMP_ROOT/offline-staging.XXXXXX")
PACKAGE_TMP=""
MD5_TMP=""
ACTIVE_MOUNTS=()
PENDING_MOUNT=""
MOUNT_TRANSITION=false
PENDING_SIGNAL_STATUS=0

rootfs_mount_target_is_registered() {
    local target="$1" active
    [ -n "$PENDING_MOUNT" ] && [ "$target" = "$PENDING_MOUNT" ] && return 0
    for active in "${ACTIVE_MOUNTS[@]}"; do
        [ "$target" = "$active" ] && return 0
    done
    return 1
}

rootfs_mount_path_identity() {
    local target="$1" canonical identity
    [ -d "$target" ] && [ ! -L "$target" ] || return 1
    canonical=$(cd -- "$target" && pwd -P) || return 1
    [ "$canonical" = "$target" ] || return 1
    identity=$(stat -Lc '%d:%i' -- "$target") || return 1
    printf '%s|%s\n' "$canonical" "$identity"
}

rootfs_mount_state() {
    local target="$1" status diagnostic_status
    local identity_before identity_after mountpoint_output
    ROOTFS_MOUNT_STATE=unknown
    rootfs_mount_target_is_registered "$target" || return 1
    identity_before=$(rootfs_mount_path_identity "$target") || return 1
    if mountpoint -q -- "$target"; then
        status=0
    else
        status=$?
    fi
    identity_after=$(rootfs_mount_path_identity "$target") || return 1
    [ "$identity_before" = "$identity_after" ] || return 1

    case "$status" in
        0)
            ROOTFS_MOUNT_STATE=active
            return 0
            ;;
        32)
            ROOTFS_MOUNT_STATE=inactive
            return 0
            ;;
        1) ;;
        *) return 1 ;;
    esac

    if mountpoint_output=$(LC_ALL=C mountpoint -- "$target" 2>&1); then
        diagnostic_status=0
    else
        diagnostic_status=$?
    fi
    identity_after=$(rootfs_mount_path_identity "$target") || return 1
    [ "$identity_before" = "$identity_after" ] || return 1
    case "$diagnostic_status" in
        1|32) ;;
        *) return 1 ;;
    esac
    if [ "$mountpoint_output" != "$target is not a mountpoint" ]; then
        return 1
    fi
    ROOTFS_MOUNT_STATE=inactive
}

forget_active_mount() {
    local target="$1" active
    local -a retained=()
    for active in "${ACTIVE_MOUNTS[@]}"; do
        [ "$active" = "$target" ] || retained+=("$active")
    done
    ACTIVE_MOUNTS=("${retained[@]}")
}

release_rootfs_mount() {
    local target="$1"
    if ! rootfs_mount_state "$target"; then
        fail "无法确认 rootfs 挂载状态，保留目录以供恢复: $target"
        return 1
    fi
    if [ "$ROOTFS_MOUNT_STATE" = active ]; then
        if ! sudo umount -- "$target"; then
            fail "无法卸载 rootfs，保留目录以供恢复: $target"
            return 1
        fi
        if ! rootfs_mount_state "$target" ||
                [ "$ROOTFS_MOUNT_STATE" != inactive ]; then
            fail "无法确认 rootfs 已卸载，保留目录以供恢复: $target"
            return 1
        fi
    fi
    forget_active_mount "$target"
    rm -rf -- "$target"
}

cleanup() {
    local status=$?
    local cleanup_failed=0 mount_dir i pending_is_active=false
    trap - EXIT INT TERM HUP
    MOUNT_TRANSITION=false

    if [ -n "$PENDING_MOUNT" ]; then
        if rootfs_mount_state "$PENDING_MOUNT"; then
            if [ "$ROOTFS_MOUNT_STATE" = active ]; then
                for mount_dir in "${ACTIVE_MOUNTS[@]}"; do
                    [ "$mount_dir" = "$PENDING_MOUNT" ] && pending_is_active=true
                done
                [ "$pending_is_active" = true ] || ACTIVE_MOUNTS+=("$PENDING_MOUNT")
            else
                rm -rf -- "$PENDING_MOUNT"
            fi
        else
            fail "无法确认 rootfs 挂载状态，保留目录以供恢复: $PENDING_MOUNT"
            cleanup_failed=1
        fi
        PENDING_MOUNT=""
    fi

    for ((i=${#ACTIVE_MOUNTS[@]} - 1; i >= 0; i--)); do
        mount_dir=${ACTIVE_MOUNTS[$i]}
        if ! release_rootfs_mount "$mount_dir"; then
            cleanup_failed=1
        fi
    done
    rm -rf -- "$STAGING"
    if [ -n "$PACKAGE_TMP" ]; then
        rm -f -- "$PACKAGE_TMP"
    fi
    if [ -n "$MD5_TMP" ]; then
        rm -f -- "$MD5_TMP"
    fi
    if [ "$cleanup_failed" -ne 0 ] && [ "$status" -eq 0 ]; then
        status=1
    fi
    exit "$status"
}

handle_signal() {
    local signal_status="$1"
    if [ "$MOUNT_TRANSITION" = true ]; then
        if [ "$PENDING_SIGNAL_STATUS" -eq 0 ]; then
            PENDING_SIGNAL_STATUS=$signal_status
        fi
        return
    fi
    exit "$signal_status"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}       CoSim 离线包打包工具${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
info "Guest 类型: ${GUEST_TYPE}"
info "输出路径:   ${OUTPUT}"
echo ""
if [ -n "$CUSTOM_DRIVER_ARCHIVE" ]; then
    [ -f "$CUSTOM_DRIVER_ARCHIVE" ] || { fail "DPU 驱动源码包不存在: $CUSTOM_DRIVER_ARCHIVE"; exit 1; }
    info "DPU 驱动:   ${CUSTOM_DRIVER_ARCHIVE}"
fi
if [ -n "$COMPAT_RUNTIME_DEB" ]; then
    [ -f "$COMPAT_RUNTIME_DEB" ] || { fail "DPU 兼容运行库不存在: $COMPAT_RUNTIME_DEB"; exit 1; }
    info "兼容运行库: ${COMPAT_RUNTIME_DEB}"
fi

# ---- 检查依赖 ----
for cmd in curl zip mountpoint python3 sha256sum; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "缺少依赖: $cmd"
        exit 1
    fi
done
[ -x "$QEMU_SOURCE_CLOSURE_VALIDATOR" ] || {
    fail "缺少 QEMU source closure 校验器: $QEMU_SOURCE_CLOSURE_VALIDATOR"
    exit 1
}

# ---- 准备 staging 目录 ----
mkdir -p "$STAGING"/{qemu-src,guest/debian,guest/ubuntu,guest/ubuntu-server,kheaders}

ROOTFS_RESOLVED_PATH=""

# Resolve a guest-absolute path without ever applying host-root symlink
# semantics.  Each link target is folded back into the component queue:
# absolute targets restart at the mounted root, while relative targets restart
# at the link's guest directory.  Reject loops and attempts to walk above /.
rootfs_resolve_path() {
    local root="$1" guest_path="$2"
    local remaining component candidate target part
    local symlink_hops=0
    local -a resolved_parts=()

    ROOTFS_RESOLVED_PATH=""
    case "$guest_path" in
        /*) remaining=${guest_path#/} ;;
        *) return 1 ;;
    esac

    while [ -n "$remaining" ]; do
        case "$remaining" in
            */*)
                component=${remaining%%/*}
                remaining=${remaining#*/}
                ;;
            *)
                component=$remaining
                remaining=""
                ;;
        esac

        case "$component" in
            ''|.) continue ;;
            ..)
                [ "${#resolved_parts[@]}" -gt 0 ] || return 1
                unset "resolved_parts[${#resolved_parts[@]}-1]"
                continue
                ;;
        esac

        candidate=$root
        for part in "${resolved_parts[@]}"; do
            candidate="$candidate/$part"
        done
        candidate="$candidate/$component"

        if [ -L "$candidate" ]; then
            symlink_hops=$((symlink_hops + 1))
            [ "$symlink_hops" -le 40 ] || return 1
            target=$(readlink -- "$candidate") || return 1
            case "$target" in
                /*)
                    resolved_parts=()
                    target=${target#/}
                    ;;
            esac
            if [ -n "$target" ]; then
                if [ -n "$remaining" ]; then
                    remaining="$target/$remaining"
                else
                    remaining=$target
                fi
            fi
            continue
        fi

        resolved_parts+=("$component")
        if [ -n "$remaining" ] && [ ! -d "$candidate" ]; then
            return 1
        fi
    done

    ROOTFS_RESOLVED_PATH=$root
    for part in "${resolved_parts[@]}"; do
        ROOTFS_RESOLVED_PATH="$ROOTFS_RESOLVED_PATH/$part"
    done
}

rootfs_has_regular_file() {
    rootfs_resolve_path "$1" "$2" && [ -f "$ROOTFS_RESOLVED_PATH" ]
}

rootfs_has_executable() {
    rootfs_resolve_path "$1" "$2" &&
        [ -f "$ROOTFS_RESOLVED_PATH" ] && [ -x "$ROOTFS_RESOLVED_PATH" ]
}

rootfs_has_directory() {
    rootfs_resolve_path "$1" "$2" && [ -d "$ROOTFS_RESOLVED_PATH" ]
}

validate_rootfs() {
    local image="$1" profile="$2"
    local mount_dir mount_status mount_is_active=false
    local validation_failed=0 unmount_failed=0 signal_status
    mount_dir=$(mktemp -d "$TMP_ROOT/offline-rootfs-${profile}.XXXXXX")

    PENDING_MOUNT=$mount_dir
    MOUNT_TRANSITION=true
    if sudo mount -o loop,ro,nosuid,nodev -- "$image" "$mount_dir"; then
        mount_status=0
    else
        mount_status=$?
    fi
    if rootfs_mount_state "$mount_dir"; then
        if [ "$ROOTFS_MOUNT_STATE" = active ]; then
            ACTIVE_MOUNTS+=("$mount_dir")
            mount_is_active=true
            PENDING_MOUNT=""
        elif rm -rf -- "$mount_dir"; then
            PENDING_MOUNT=""
        fi
    fi
    MOUNT_TRANSITION=false
    if [ "$PENDING_SIGNAL_STATUS" -ne 0 ]; then
        signal_status=$PENDING_SIGNAL_STATUS
        PENDING_SIGNAL_STATUS=0
        exit "$signal_status"
    fi

    if [ "$mount_status" -ne 0 ] || [ "$mount_is_active" != true ]; then
        fail "无法只读挂载 ${profile} rootfs: $image"
        if [ "$mount_is_active" = true ]; then
            release_rootfs_mount "$mount_dir" || true
        elif [ "$ROOTFS_MOUNT_STATE" = inactive ]; then
            rm -rf -- "$mount_dir"
        fi
        return 1
    fi

    for required in /usr/local/bin/pci_debug /usr/local/bin/reg_display; do
        if ! rootfs_has_executable "$mount_dir" "$required"; then
            fail "${profile} rootfs 缺少可执行文件: ${required}"
            validation_failed=1
        fi
    done

    if [ "$profile" = ubuntu-server ]; then
        if ! rootfs_has_regular_file "$mount_dir" /etc/os-release ||
                ! grep -Eq '^ID=ubuntu$' "$ROOTFS_RESOLVED_PATH" 2>/dev/null; then
            fail 'ubuntu-server rootfs 的 /etc/os-release 缺少 ID=ubuntu'
            validation_failed=1
        fi
        if ! rootfs_has_regular_file "$mount_dir" /etc/os-release ||
                ! grep -Eq '^VERSION_ID="?24\.04"?$' "$ROOTFS_RESOLVED_PATH" 2>/dev/null; then
            fail 'ubuntu-server rootfs 的 /etc/os-release 缺少 VERSION_ID="24.04"'
            validation_failed=1
        fi
        for required in /usr/bin/gcc /usr/bin/make; do
            if ! rootfs_has_executable "$mount_dir" "$required"; then
                fail "ubuntu-server rootfs 缺少: ${required}"
                validation_failed=1
            fi
        done
        for required in \
            "/usr/src/linux-headers-${KVER}/Makefile" \
            /opt/dpu-debugutils/Makefile; do
            if ! rootfs_has_regular_file "$mount_dir" "$required"; then
                fail "ubuntu-server rootfs 缺少: ${required}"
                validation_failed=1
            fi
        done
        required="/lib/modules/${KVER}/build"
        if ! rootfs_has_directory "$mount_dir" "$required"; then
            fail "ubuntu-server rootfs 缺少: ${required}"
            validation_failed=1
        fi
    fi

    if ! release_rootfs_mount "$mount_dir"; then
        fail "无法卸载 ${profile} rootfs: $mount_dir"
        unmount_failed=1
    fi

    [ "$validation_failed" -eq 0 ] && [ "$unmount_failed" -eq 0 ]
}

PASS=0
FAIL_COUNT=0

# ============================================================
# [1/5] QEMU 源码
# ============================================================
echo ""
echo -e "${BOLD}[1/5] 获取 QEMU 源码${NC}"

TARBALL="${STAGING}/qemu-src/qemu-9.2.0.tar.xz"
if [ -f "${PROJECT_DIR}/third_party/qemu-9.2.0.tar.xz" ]; then
    info "复制本地已有 tarball..."
    cp "${PROJECT_DIR}/third_party/qemu-9.2.0.tar.xz" "$TARBALL"
    ok "QEMU tarball 已复制"
    PASS=$((PASS + 1))
elif [ -d "${PROJECT_DIR}/third_party/qemu" ]; then
    info "本地已有 QEMU 源码目录，创建 tarball..."
    cd "${PROJECT_DIR}/third_party"
    tar cJf "$TARBALL" --transform 's,^qemu,qemu-9.2.0,' qemu/
    cd "$PROJECT_DIR"
    ok "QEMU tarball 创建完成"
    PASS=$((PASS + 1))
else
    info "从 QEMU 官方 release 下载 ${QEMU_VERSION}..."
    if curl -fSL -o "$TARBALL" "$QEMU_RELEASE_URL"; then
        actual_qemu_sha256=$(sha256sum -- "$TARBALL" | awk '{ print $1 }')
        if [ "$actual_qemu_sha256" != "$QEMU_RELEASE_SHA256" ]; then
            fail "QEMU 官方 release SHA-256 校验失败"
            fail "  expected: $QEMU_RELEASE_SHA256"
            fail "  actual:   $actual_qemu_sha256"
            rm -f -- "$TARBALL"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            ok "QEMU 官方 release SHA-256 校验通过"
            ok "QEMU 源码下载完成: $(du -h "$TARBALL" | cut -f1)"
            PASS=$((PASS + 1))
        fi
    else
        fail "QEMU 源码下载失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ============================================================
# [2/5] 构建 Debian rootfs
# ============================================================
echo ""
echo -e "${BOLD}[2/5] Debian rootfs（Ubuntu rootfs 的基础镜像）${NC}"

DEBIAN_DIR="${PROJECT_DIR}/guest/images/debian"
if [ -f "${DEBIAN_DIR}/rootfs.ext4" ] && [ -f "${DEBIAN_DIR}/bzImage" ]; then
    info "复制已有的 Debian 镜像..."
    cp "${DEBIAN_DIR}/bzImage" "${STAGING}/guest/debian/"
    cp "${DEBIAN_DIR}/rootfs.ext4" "${STAGING}/guest/debian/"
    [ -f "${DEBIAN_DIR}/initramfs.gz" ] && cp "${DEBIAN_DIR}/initramfs.gz" "${STAGING}/guest/debian/"
    ok "Debian 镜像已复制"
    PASS=$((PASS + 1))
elif [ "$SKIP_ROOTFS" = true ]; then
    warn "跳过 rootfs 构建（--skip-rootfs）"
else
    if ! sudo -n true 2>/dev/null; then
        fail "构建 rootfs 需要 sudo 权限"
        info "请先执行:"
        info "  sudo ${PROJECT_DIR}/scripts/build_rootfs_debian.sh ${DEBIAN_DIR}"
        info "然后重新运行: $0"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        info "编译 Guest 测试工具..."
        "${PROJECT_DIR}/scripts/build_guest_tools.sh" || warn "部分工具编译失败"

        info "构建 Debian rootfs（需要几分钟）..."
        if sudo "${PROJECT_DIR}/scripts/build_rootfs_debian.sh" "${DEBIAN_DIR}"; then
            cp "${DEBIAN_DIR}/bzImage" "${STAGING}/guest/debian/"
            cp "${DEBIAN_DIR}/rootfs.ext4" "${STAGING}/guest/debian/"
            [ -f "${DEBIAN_DIR}/initramfs.gz" ] && cp "${DEBIAN_DIR}/initramfs.gz" "${STAGING}/guest/debian/"
            ok "Debian rootfs 构建并复制完成"
            PASS=$((PASS + 1))
        else
            fail "Debian rootfs 构建失败"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
fi

# ============================================================
# [3/5] Ubuntu 内核 + rootfs
# ============================================================
echo ""
echo -e "${BOLD}[3/5] Ubuntu 内核${NC}"

UBUNTU_DIR="${PROJECT_DIR}/guest/images/ubuntu"
if [ -f "${UBUNTU_DIR}/vmlinuz" ] && [ -f "${UBUNTU_DIR}/rootfs.ext4" ]; then
    info "复制已有的 Ubuntu 镜像..."
    cp "${UBUNTU_DIR}/vmlinuz" "${STAGING}/guest/ubuntu/"
    [ -f "${UBUNTU_DIR}/modules.tar.gz" ] && cp "${UBUNTU_DIR}/modules.tar.gz" "${STAGING}/guest/ubuntu/"
    cp "${UBUNTU_DIR}/rootfs.ext4" "${STAGING}/guest/ubuntu/"
    ok "Ubuntu 镜像已复制"
    PASS=$((PASS + 1))
else
    # 提取内核
    info "提取 Ubuntu LTS 内核..."
    "${PROJECT_DIR}/scripts/setup-ubuntu-kernel.sh" "$KVER" || warn "内核提取失败"

    # 注入模块生成 rootfs
    if [ -f "${UBUNTU_DIR}/modules.tar.gz" ] && [ -f "${DEBIAN_DIR}/rootfs.ext4" ]; then
        info "注入模块生成 Ubuntu rootfs..."
        "${PROJECT_DIR}/scripts/inject-modules.sh" ubuntu || warn "模块注入失败"
    fi

    # 复制产物
    if [ -f "${UBUNTU_DIR}/vmlinuz" ]; then
        cp "${UBUNTU_DIR}/vmlinuz" "${STAGING}/guest/ubuntu/"
        [ -f "${UBUNTU_DIR}/modules.tar.gz" ] && cp "${UBUNTU_DIR}/modules.tar.gz" "${STAGING}/guest/ubuntu/"
        [ -f "${UBUNTU_DIR}/rootfs.ext4" ] && cp "${UBUNTU_DIR}/rootfs.ext4" "${STAGING}/guest/ubuntu/"
        ok "Ubuntu 内核已复制"
        PASS=$((PASS + 1))
    else
        fail "Ubuntu 内核不可用"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ============================================================
# Ubuntu Server kernel + rootfs（选择该 profile 时必须完整）
# ============================================================
UBUNTU_SERVER_DIR="${PROJECT_DIR}/guest/images/ubuntu-server"
if [ "$GUEST_TYPE" = ubuntu-server ]; then
    if [ ! -f "${UBUNTU_SERVER_DIR}/vmlinuz" ] || \
            [ ! -f "${UBUNTU_SERVER_DIR}/modules.tar.gz" ] || \
            [ ! -f "${UBUNTU_SERVER_DIR}/rootfs.ext4" ]; then
        if [ "$SKIP_ROOTFS" = false ] && \
                [ -x "${PROJECT_DIR}/scripts/build_rootfs_ubuntu_server.sh" ]; then
            info "构建独立 Ubuntu Server rootfs..."
            "${PROJECT_DIR}/scripts/build_rootfs_ubuntu_server.sh" "$UBUNTU_SERVER_DIR" || true
        fi
    fi

    missing_artifacts=()
    for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
        [ -f "${UBUNTU_SERVER_DIR}/${artifact}" ] || missing_artifacts+=("$artifact")
    done
    if [ "${#missing_artifacts[@]}" -ne 0 ]; then
        fail "Ubuntu Server 离线包缺少完整产物: ${missing_artifacts[*]}"
        exit 1
    fi
    if [ ! -f "${UBUNTU_DIR}/vmlinuz" ] || [ ! -f "${UBUNTU_DIR}/rootfs.ext4" ]; then
        fail 'Ubuntu Server 离线包还要求完整 compact Ubuntu 产物: vmlinuz rootfs.ext4'
        exit 1
    fi

    cp "${UBUNTU_SERVER_DIR}/vmlinuz" "${STAGING}/guest/ubuntu-server/"
    cp "${UBUNTU_SERVER_DIR}/modules.tar.gz" "${STAGING}/guest/ubuntu-server/"
    cp "${UBUNTU_SERVER_DIR}/rootfs.ext4" "${STAGING}/guest/ubuntu-server/"
    ok "Ubuntu Server 镜像已复制"
    PASS=$((PASS + 1))
fi

UBUNTU_SERVER_HAS_HEADERS=false
case "$GUEST_TYPE" in
    ubuntu)
        validate_rootfs "${UBUNTU_DIR}/rootfs.ext4" ubuntu || exit 1
        ;;
    ubuntu-server)
        validate_rootfs "${UBUNTU_DIR}/rootfs.ext4" ubuntu || exit 1
        if validate_rootfs "${UBUNTU_SERVER_DIR}/rootfs.ext4" ubuntu-server; then
            UBUNTU_SERVER_HAS_HEADERS=true
        else
            exit 1
        fi
        ;;
    debian)
        validate_rootfs "${DEBIAN_DIR}/rootfs.ext4" debian || exit 1
        ;;
esac

# ============================================================
# [4/5] Kernel headers（用于编译 cosim_nic.ko）
# ============================================================
echo ""
echo -e "${BOLD}[4/5] Kernel headers${NC}"

BASE_KVER="${KVER%-generic}"
_MIRROR="http://archive.ubuntu.com/ubuntu"

# 推断 suite
_kver_major="${KVER%%.*}"
_kver_rest="${KVER#*.}"
_kver_minor="${_kver_rest%%.*}"
case "${_kver_major}.${_kver_minor}" in
    6.8|6.11) _SUITE="noble" ;;
    6.5) _SUITE="mantic" ;;
    5.15) _SUITE="jammy" ;;
    5.4) _SUITE="focal" ;;
    *) _SUITE="noble" ;;
esac

KHEADERS_DIR="${STAGING}/kheaders"
_headers_ok=true

for hdr_pkg in "linux-headers-${BASE_KVER}" "linux-headers-${KVER}"; do
    if ls "${KHEADERS_DIR}/${hdr_pkg}"_*.deb &>/dev/null; then
        info "${hdr_pkg} 已存在，跳过"
        continue
    fi

    info "下载 ${hdr_pkg}..."
    local_deb=""

    # apt download
    if command -v apt &>/dev/null; then
        (cd "$KHEADERS_DIR" && apt download "$hdr_pkg" 2>/dev/null) || true
        local_deb=$(ls "${KHEADERS_DIR}/${hdr_pkg}"_*.deb 2>/dev/null | head -1 || true)
    fi

    # fallback: Packages.gz 索引
    if [ -z "$local_deb" ]; then
        _pkg_url=""
        for _comp in "${_SUITE}-updates" "${_SUITE}"; do
            _idx="${_MIRROR}/dists/${_comp}/main/binary-amd64/Packages.gz"
            _pkg_url=$(curl -sf "$_idx" 2>/dev/null | gunzip 2>/dev/null | \
                awk -v pkg="$hdr_pkg" '
                    /^Package:/ { found = ($2 == pkg) }
                    found && /^Filename:/ { print $2; exit }
                ') || true
            [ -n "$_pkg_url" ] && break
        done

        if [ -n "$_pkg_url" ]; then
            _fname=$(basename "$_pkg_url")
            curl -fSL -o "${KHEADERS_DIR}/${_fname}" "${_MIRROR}/${_pkg_url}" && \
                local_deb="${KHEADERS_DIR}/${_fname}" || true
        fi
    fi

    if [ -n "$local_deb" ] && [ -s "$local_deb" ]; then
        ok "  ${hdr_pkg} 下载完成"
    else
        warn "  ${hdr_pkg} 下载失败"
        _headers_ok=false
    fi
done

if [ "$_headers_ok" = true ]; then
    PASS=$((PASS + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# [5/5] cosim_nic 预编译
# ============================================================
echo ""
echo -e "${BOLD}[5/5] cosim_nic.ko 预编译${NC}"

PREBUILT="${PROJECT_DIR}/guest/driver/prebuilt/cosim_nic_${KVER}.ko"
if [ "$GUEST_TYPE" = ubuntu-server ]; then
    info "Ubuntu Server v3 离线包不包含 direct cosim_nic.ko"
elif [ -f "$PREBUILT" ]; then
    mkdir -p "${STAGING}/driver"
    cp "$PREBUILT" "${STAGING}/driver/"
    ok "cosim_nic.ko 预编译已复制"
elif [ "$_headers_ok" = true ]; then
    info "尝试编译 cosim_nic.ko..."
    if "${PROJECT_DIR}/scripts/build_cosim_nic.sh" "$GUEST_TYPE" 2>&1 | tail -3; then
        PREBUILT="${PROJECT_DIR}/guest/driver/prebuilt/cosim_nic_${KVER}.ko"
        if [ -f "$PREBUILT" ]; then
            mkdir -p "${STAGING}/driver"
            cp "$PREBUILT" "${STAGING}/driver/"
            ok "cosim_nic.ko 编译并复制完成"
        fi
    else
        warn "cosim_nic.ko 编译失败，将在内网机器上编译"
    fi
else
    warn "headers 不可用，跳过 cosim_nic.ko 编译"
fi
PASS=$((PASS + 1))

# ============================================================
# [6/6] DPU 自定义驱动素材（可选）
# ============================================================
CUSTOM_ARCHIVE_NAME=""
COMPAT_RUNTIME_NAME=""
if [ -n "$CUSTOM_DRIVER_ARCHIVE" ]; then
    echo ""
    echo -e "${BOLD}[6/6] DPU 自定义驱动素材${NC}"
    if ! "${PROJECT_DIR}/scripts/build_dpu_driver_bundle.sh" \
            --validate-only --archive "$CUSTOM_DRIVER_ARCHIVE"; then
        fail "DPU 驱动源码包结构校验失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        mkdir -p "${STAGING}/custom-driver"
        CUSTOM_ARCHIVE_NAME=$(basename "$CUSTOM_DRIVER_ARCHIVE")
        cp "$CUSTOM_DRIVER_ARCHIVE" "${STAGING}/custom-driver/${CUSTOM_ARCHIVE_NAME}"
        if [ -n "$COMPAT_RUNTIME_DEB" ]; then
            COMPAT_RUNTIME_NAME=$(basename "$COMPAT_RUNTIME_DEB")
            cp "$COMPAT_RUNTIME_DEB" "${STAGING}/custom-driver/${COMPAT_RUNTIME_NAME}"
        fi
        ok "DPU 自定义驱动素材已加入离线包"
        PASS=$((PASS + 1))
    fi
fi

# ============================================================
# 写入元数据
# ============================================================
cat > "${STAGING}/offline-meta.env" << EOF
# CoSim 离线包元数据（自动生成，请勿修改）
OFFLINE_VERSION=3
OFFLINE_DATE=$(date +%Y-%m-%d)
OFFLINE_GUEST_TYPE=${GUEST_TYPE}
OFFLINE_KVER=${KVER}
OFFLINE_HAS_CUSTOM_DPU=$([ -n "${CUSTOM_ARCHIVE_NAME}" ] && echo true || echo false)
OFFLINE_CUSTOM_DPU_ARCHIVE=${CUSTOM_ARCHIVE_NAME}
OFFLINE_CUSTOM_DPU_RUNTIME=${COMPAT_RUNTIME_NAME}
OFFLINE_QEMU_VERSION=${QEMU_VERSION}
OFFLINE_HAS_DEBIAN_ROOTFS=$([ -f "${STAGING}/guest/debian/rootfs.ext4" ] && echo true || echo false)
OFFLINE_HAS_UBUNTU_ROOTFS=$([ -f "${STAGING}/guest/ubuntu/rootfs.ext4" ] && echo true || echo false)
OFFLINE_HAS_UBUNTU_SERVER_ROOTFS=$([ -f "${STAGING}/guest/ubuntu-server/rootfs.ext4" ] && echo true || echo false)
OFFLINE_UBUNTU_SERVER_HAS_HEADERS=${UBUNTU_SERVER_HAS_HEADERS}
OFFLINE_DPU_DEBUGUTILS_SHA256=1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab
OFFLINE_HAS_UBUNTU_KERNEL=$([ -f "${STAGING}/guest/ubuntu/vmlinuz" ] && echo true || echo false)
OFFLINE_HAS_KHEADERS=$_headers_ok
OFFLINE_HAS_COSIM_NIC=$([ -f "${STAGING}/driver/cosim_nic_${KVER}.ko" ] && echo true || echo false)
EOF

# ============================================================
# 打包
# ============================================================
echo ""
echo -e "${BOLD}打包离线安装包...${NC}"

if [ "$FAIL_COUNT" -gt 0 ]; then
    fail "有 ${FAIL_COUNT} 个组件准备失败，拒绝发布不完整离线包"
    exit 1
fi

if ! "$QEMU_SOURCE_CLOSURE_VALIDATOR" "$TARBALL"; then
    fail "QEMU source closure 不完整，拒绝发布离线包"
    exit 1
fi
ok "QEMU source closure 校验通过"

cd "$STAGING"
info "正在压缩（大文件可能需要几分钟）..."
PACKAGE_TMP=$(mktemp "$TMP_ROOT/offline-package.XXXXXX.zip")
rm -f -- "$PACKAGE_TMP"
if ! zip -qr "$PACKAGE_TMP" .; then
    fail "zip 打包失败（磁盘空间不足？）"
    cd "$PROJECT_DIR"
    exit 1
fi

# 校验 zip 完整性
info "校验 zip 完整性..."
if ! zip -T "$PACKAGE_TMP" &>/dev/null; then
    fail "zip 文件校验失败，文件可能损坏"
    cd "$PROJECT_DIR"
    exit 1
fi
ok "zip 校验通过"

cd "$PROJECT_DIR"
output_dir=$(dirname "$OUTPUT")
output_base=$(basename "$OUTPUT")
mkdir -p "$output_dir"
mv -f -- "$PACKAGE_TMP" "$OUTPUT"
PACKAGE_TMP=""

# 生成 md5sum 便于传输后校验
MD5_TMP=$(mktemp "$TMP_ROOT/offline-package-md5.XXXXXX")
printf '%s  %s\n' "$(md5sum -- "$OUTPUT" | awk '{ print $1 }')" "$output_base" > "$MD5_TMP"
mv -f -- "$MD5_TMP" "${OUTPUT}.md5"
MD5_TMP=""

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}       打包完成${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  文件: ${OUTPUT}"
echo "  大小: $(du -h "$OUTPUT" | cut -f1)"
echo "  MD5:  $(cut -d' ' -f1 "${OUTPUT}.md5")"
echo "  成功: ${PASS}  失败: ${FAIL_COUNT}"
echo ""

echo -e "${BOLD}  内网使用方法:${NC}"
echo "    1. 将 $(basename "$OUTPUT") 和 $(basename "${OUTPUT}.md5") 拷贝到内网机器"
echo "    2. 校验: md5sum -c $(basename "${OUTPUT}.md5")"
echo "    3. 将 zip 放到项目目录，运行 ./setup.sh"
echo "    4. 选择「导入离线包」"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    warn "有 ${FAIL_COUNT} 个组件打包失败，部分功能可能需要在内网手动处理"
    exit 1
fi
