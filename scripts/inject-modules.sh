#!/bin/bash
# inject-modules.sh — 将内核模块注入 rootfs
# 用法: ./scripts/inject-modules.sh [ubuntu|debian]
set -euo pipefail

SYSTEM="${1:-ubuntu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COSIM_DIR="${PROJECT_DIR}/guest/images/${SYSTEM}"

MODULES_TAR="${COSIM_DIR}/modules.tar.gz"
SRC_ROOTFS="${COSIM_DIR}/rootfs.ext4"
DST_ROOTFS="${COSIM_DIR}/rootfs.ext4"

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
if [ -f "$DST_ROOTFS" ]; then
    echo "  目标已存在，备份为 rootfs.ext4.bak"
    mv "$DST_ROOTFS" "${DST_ROOTFS}.bak"
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

TMPDIR=$(mktemp -d)
cd "$TMPDIR"
tar xzf "$MODULES_TAR"

if command -v depmod &>/dev/null; then
    depmod -b "$TMPDIR" "$NEW_KVER" 2>/dev/null || true
fi

DBGCMDS=$(mktemp)

OLD_KVER="6.6.134-0-virt"
echo "kill_file lib/modules/${OLD_KVER}" >> "$DBGCMDS"

find "lib/modules/${NEW_KVER}" -type d | sort | while read dir; do
    echo "mkdir $dir" >> "$DBGCMDS"
done

find "lib/modules/${NEW_KVER}" -type f | sort | while read file; do
    echo "write $(pwd)/$file $file" >> "$DBGCMDS"
done

CMD_COUNT=$(wc -l < "$DBGCMDS")
echo "  debugfs 命令数: $CMD_COUNT"

debugfs -w -f "$DBGCMDS" "$DST_ROOTFS" 2>/dev/null

rm -f "$DBGCMDS"

# ---- 4. 验证 ----
echo "[4/4] 验证注入结果..."
MOD_COUNT=$(debugfs -R "ls lib/modules/${NEW_KVER}/kernel" "$DST_ROOTFS" 2>/dev/null | wc -w)
echo "  模块目录条目: $MOD_COUNT"

VFIO_CHECK=$(debugfs -R "dump lib/modules/${NEW_KVER}/modules.dep /dev/stdout" "$DST_ROOTFS" 2>/dev/null | grep -c "vfio" || true)
echo "  VFIO 模块数: $VFIO_CHECK"

RDMA_CHECK=$(debugfs -R "dump lib/modules/${NEW_KVER}/modules.dep /dev/stdout" "$DST_ROOTFS" 2>/dev/null | grep -c "infiniband\|rdma" || true)
echo "  RDMA 模块数: $RDMA_CHECK"

rm -rf "$TMPDIR"

echo ""
echo "============================================"
echo " 模块注入完成 (${SYSTEM})"
echo " rootfs:  ${DST_ROOTFS}"
echo " 内核:    ${NEW_KVER}"
echo "============================================"
echo ""
echo "运行 cosim:"
echo "  KERNEL=${COSIM_DIR}/vmlinuz ./cosim.sh start qemu --drive ${DST_ROOTFS}"
