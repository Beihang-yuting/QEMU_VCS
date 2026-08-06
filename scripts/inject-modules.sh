#!/bin/bash
# inject-modules.sh — 将内核模块注入 rootfs
# 用法: ./scripts/inject-modules.sh [ubuntu|debian]
set -euo pipefail

SYSTEM="${1:-ubuntu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COSIM_DIR="${PROJECT_DIR}/guest/images/${SYSTEM}"

MODULES_TAR="${MODULES_TAR:-${COSIM_DIR}/modules.tar.gz}"
SRC_ROOTFS="${SRC_ROOTFS:-${COSIM_DIR}/rootfs.ext4}"
DST_ROOTFS="${DST_ROOTFS:-${COSIM_DIR}/rootfs.ext4}"
BUILD_TMP="${PROJECT_DIR}/build/tmp"

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
    --bin-dir "${PROJECT_DIR}/build/guest_tools/dpu-debugutils"

echo ""
echo "============================================"
echo " 模块注入完成 (${SYSTEM})"
echo " rootfs:  ${DST_ROOTFS}"
echo " 内核:    ${NEW_KVER}"
echo "============================================"
echo ""
echo "运行 cosim:"
echo "  make run-qemu   # 起 QEMU（见 docs/COSIM-ISOLATED-ENVS.md）"
