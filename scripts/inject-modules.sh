#!/bin/bash
# inject-modules.sh — 将内核模块注入 rootfs
# 用法: ./scripts/inject-modules.sh [ubuntu|debian]
set -euo pipefail

SYSTEM="${1:-ubuntu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
COSIM_DIR="${PROJECT_DIR}/guest/images/${SYSTEM}"

MODULES_TAR="${MODULES_TAR:-${COSIM_DIR}/modules.tar.gz}"
SRC_ROOTFS="${SRC_ROOTFS:-${COSIM_DIR}/rootfs.ext4}"
DST_ROOTFS="${DST_ROOTFS:-${COSIM_DIR}/rootfs.ext4}"
BUILD_TMP="${PROJECT_DIR}/build/tmp"
DEBUG_BIN_DIR="${PROJECT_DIR}/build/guest_tools/dpu-debugutils"

preflight_fail() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_debug_output_paths() {
    local path
    local canonical_path
    local utility

    for path in \
        "${PROJECT_DIR}/build" \
        "${PROJECT_DIR}/build/guest_tools" \
        "$DEBUG_BIN_DIR"; do
        [ ! -L "$path" ] || preflight_fail "调试工具输出目录是符号链接: $path"
        if [ -e "$path" ]; then
            [ -d "$path" ] || preflight_fail "调试工具输出路径不是目录: $path"
            canonical_path=$(cd "$path" && pwd -P) ||
                preflight_fail "无法解析调试工具输出目录: $path"
            [ "$canonical_path" = "$path" ] ||
                preflight_fail "调试工具输出目录逃逸工作树: $path"
        fi
    done

    for utility in pci_debug reg_display; do
        path="${DEBUG_BIN_DIR}/${utility}"
        if [ -e "$path" ] || [ -L "$path" ]; then
            [ ! -L "$path" ] && [ -f "$path" ] ||
                preflight_fail "调试工具输出不是常规文件: $path"
        fi
    done
}

# 如果目标 rootfs 不存在，尝试用 Debian 基础 rootfs
if [ ! -f "$SRC_ROOTFS" ] && [ -f "${PROJECT_DIR}/guest/images/debian/rootfs.ext4" ]; then
    SRC_ROOTFS="${PROJECT_DIR}/guest/images/debian/rootfs.ext4"
fi

if [ ! -f "$MODULES_TAR" ]; then
    echo "ERROR: 找不到模块包: $MODULES_TAR"
    echo "  请先运行对应的 setup 脚本"
    exit 1
fi

if [ ! -f "$SRC_ROOTFS" ]; then
    echo "ERROR: 找不到基础 rootfs: $SRC_ROOTFS"
    exit 1
fi

debug_utility_is_executable_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ]
}

validate_debug_output_paths
if ! debug_utility_is_executable_file "${DEBUG_BIN_DIR}/pci_debug" ||
        ! debug_utility_is_executable_file "${DEBUG_BIN_DIR}/reg_display"; then
    "${PROJECT_DIR}/scripts/build_dpu_debugutils.sh" "$DEBUG_BIN_DIR"
fi
validate_debug_output_paths
for utility in pci_debug reg_display; do
    if ! debug_utility_is_executable_file "${DEBUG_BIN_DIR}/${utility}"; then
        echo "ERROR: 调试工具不是常规的可执行文件: ${DEBUG_BIN_DIR}/${utility}" >&2
        exit 1
    fi
    command -v file >/dev/null 2>&1 ||
        preflight_fail "缺少调试工具格式检查命令: file"
    if ! file_output=$(file -- "${DEBUG_BIN_DIR}/${utility}"); then
        preflight_fail "无法检查调试工具格式: ${DEBUG_BIN_DIR}/${utility}"
    fi
    case "$file_output" in
        *'statically linked'*) ;;
        *) preflight_fail "调试工具不是静态链接文件: ${DEBUG_BIN_DIR}/${utility}" ;;
    esac
done

# ---- 1. 复制基础 rootfs ----
echo "[1/4] 复制基础 rootfs 为 ${SYSTEM} rootfs..."
if [ "$SRC_ROOTFS" = "$DST_ROOTFS" ] && [ -f "$DST_ROOTFS" ]; then
    echo "  目标已存在，备份为 rootfs.ext4.bak"
    cp --reflink=auto --sparse=always "$DST_ROOTFS" "${DST_ROOTFS}.bak"
    SRC_ROOTFS="${DST_ROOTFS}.bak"
fi
cp "$SRC_ROOTFS" "$DST_ROOTFS"

# ---- 2. 扩展 rootfs ----
EXTRA_MB=200
echo "[2/4] 扩展 rootfs (+${EXTRA_MB}MB)..."
truncate -s "+${EXTRA_MB}M" "$DST_ROOTFS"
e2fsck -fy "$DST_ROOTFS" 2>/dev/null || true
resize2fs "$DST_ROOTFS" 2>/dev/null

# ---- 3. 注入模块 ----
echo "[3/4] 注入内核模块..."

NEW_KVER=$(tar tzf "$MODULES_TAR" 2>/dev/null | grep -oP 'lib/modules/\K[^/]+' | head -1 || true)
if [ -z "$NEW_KVER" ]; then
    echo "ERROR: 无法从 modules.tar.gz 中提取内核版本"
    exit 1
fi
echo "  新内核版本: $NEW_KVER"

mkdir -p "$BUILD_TMP"
WORK_DIR=$(mktemp -d "${BUILD_TMP}/inject-modules.XXXXXX")
chmod 0700 "$WORK_DIR"
cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "${DBGCMDS:-}"
}
trap cleanup EXIT

cd "$WORK_DIR"
tar xzf "$MODULES_TAR"

if command -v depmod &>/dev/null; then
    depmod -b "$WORK_DIR" "$NEW_KVER" 2>/dev/null || true
fi

DBGCMDS=$(mktemp "${BUILD_TMP}/inject-modules-debugfs.XXXXXX")
chmod 0600 "$DBGCMDS"

# debugfs does not interpret slashes in the destination argument of `write`.
# Enter the parent directory first so each module is stored in its real ext4
# hierarchy instead of becoming a root-directory entry named "lib/modules/...".
echo 'mkdir /lib' >> "$DBGCMDS"
echo 'mkdir /lib/modules' >> "$DBGCMDS"
find "lib/modules/${NEW_KVER}" -type d | sort | while IFS= read -r dir; do
    relative=${dir#./}
    # mkdir resolves absolute paths correctly.  The `write` command below
    # does not, which is why it still changes into its parent first.
    echo "mkdir /$relative" >> "$DBGCMDS"
done

find "lib/modules/${NEW_KVER}" -type f | sort | while IFS= read -r file; do
    relative=${file#./}
    parent=$(dirname "$relative")
    name=$(basename "$relative")
    if [ "$parent" = "." ]; then
        echo "cd /" >> "$DBGCMDS"
    else
        echo "cd /$parent" >> "$DBGCMDS"
    fi
    echo "write $(pwd)/$file $name" >> "$DBGCMDS"
    echo "cd /" >> "$DBGCMDS"
done

CMD_COUNT=$(wc -l < "$DBGCMDS")
echo "  debugfs 命令数: $CMD_COUNT"

debugfs -w -f "$DBGCMDS" "$DST_ROOTFS" >/dev/null

rm -f "$DBGCMDS"
DBGCMDS=''

# debugfs updates directory blocks directly.  Rebuild ext4 checksums before
# handing the image to QEMU so a later read-only check does not report a
# dirty/corrupt filesystem.
e2fsck -fy "$DST_ROOTFS" >/dev/null

# ---- 4. 验证 ----
echo "[4/4] 验证注入结果..."
if ! debugfs -R "stat /lib/modules/${NEW_KVER}" "$DST_ROOTFS" 2>&1 | grep -q 'Inode:'; then
    echo "ERROR: 模块目录未正确写入: /lib/modules/${NEW_KVER}"
    exit 1
fi

MOD_COUNT=$(debugfs -R "ls /lib/modules/${NEW_KVER}/kernel" "$DST_ROOTFS" 2>/dev/null | wc -w)
echo "  模块目录条目: $MOD_COUNT"

VFIO_CHECK=$(debugfs -R "dump lib/modules/${NEW_KVER}/modules.dep /dev/stdout" "$DST_ROOTFS" 2>/dev/null | grep -c "vfio" || true)
echo "  VFIO 模块数: $VFIO_CHECK"

RDMA_CHECK=$(debugfs -R "dump lib/modules/${NEW_KVER}/modules.dep /dev/stdout" "$DST_ROOTFS" 2>/dev/null | grep -c "infiniband\|rdma" || true)
echo "  RDMA 模块数: $RDMA_CHECK"

cd "$PROJECT_DIR"

"${PROJECT_DIR}/scripts/install_guest_debugutils.sh" \
    --rootfs "$DST_ROOTFS" \
    --bin-dir "$DEBUG_BIN_DIR"

echo ""
echo "============================================"
echo " 模块注入完成 (${SYSTEM})"
echo " rootfs:  ${DST_ROOTFS}"
echo " 内核:    ${NEW_KVER}"
echo "============================================"
echo ""
echo "运行 cosim:"
echo "  make run-qemu   # 起 QEMU（见 docs/COSIM-ISOLATED-ENVS.md）"
