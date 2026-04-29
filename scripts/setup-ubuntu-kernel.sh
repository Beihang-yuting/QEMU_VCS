#!/bin/bash
# setup-ubuntu-kernel.sh — 从 Ubuntu apt 仓库提取 LTS 内核及模块
# 用于 cosim guest，包含 VFIO/RDMA/NVMe-oF 等完整模块
set -euo pipefail

KVER="${1:-6.8.0-107-generic}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_DIR}/guest/images/ubuntu"
WORK_DIR="/tmp/cosim-ubuntu-kernel-${KVER}"

echo "============================================"
echo " Ubuntu 内核提取: ${KVER}"
echo "============================================"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR"

# ---- 1. 下载 deb 包 ----
echo "[1/4] 下载内核包..."
for pkg in \
    "linux-image-unsigned-${KVER}" \
    "linux-modules-${KVER}" \
    "linux-modules-extra-${KVER}"; do
    if [ ! -f "${pkg}"_*.deb ]; then
        echo "  下载 $pkg..."
        apt-get download "$pkg" 2>/dev/null || {
            echo "ERROR: 无法下载 $pkg"
            echo "  确保 apt 源包含 Ubuntu $(lsb_release -cs) 仓库"
            exit 1
        }
    else
        echo "  $pkg 已存在，跳过"
    fi
done

# ---- 2. 解压 ----
echo "[2/4] 解压..."
rm -rf extract && mkdir extract
for deb in *.deb; do
    dpkg-deb -x "$deb" extract/ 2>/dev/null
done

# ---- 3. 提取 vmlinuz ----
echo "[3/4] 提取内核和模块..."
VMLINUZ=$(find extract/boot -name "vmlinuz-*" -type f | head -1)
if [ -z "$VMLINUZ" ]; then
    echo "ERROR: vmlinuz not found in extracted packages"
    exit 1
fi
cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "  vmlinuz: $(ls -lh "$OUTPUT_DIR/vmlinuz" | awk '{print $5}')"

# ---- 4. 打包模块 ----
MODDIR=$(find extract/lib/modules -maxdepth 1 -mindepth 1 -type d | head -1)
if [ -z "$MODDIR" ]; then
    echo "ERROR: modules directory not found"
    exit 1
fi
REAL_KVER=$(basename "$MODDIR")
echo "  内核版本: $REAL_KVER"

if command -v depmod &>/dev/null; then
    depmod -b extract "$REAL_KVER" 2>/dev/null || true
fi

cd extract
tar czf "$OUTPUT_DIR/modules.tar.gz" lib/modules/
echo "  modules.tar.gz: $(ls -lh "$OUTPUT_DIR/modules.tar.gz" | awk '{print $5}')"

# ---- 验证关键模块 ----
echo "[4/4] 验证关键模块..."
MISSING=0
for mod in \
    "kernel/drivers/vfio/vfio.ko" \
    "kernel/drivers/vfio/pci/vfio-pci.ko" \
    "kernel/drivers/infiniband/core/ib_core.ko" \
    "kernel/drivers/infiniband/hw/mlx5/mlx5_ib.ko" \
    "kernel/drivers/nvme/host/nvme-tcp.ko" \
    "kernel/drivers/nvme/host/nvme-rdma.ko"; do
    found=$(find "lib/modules/$REAL_KVER" -path "*${mod}*" | head -1)
    if [ -n "$found" ]; then
        echo "  OK: $(basename "$found")"
    else
        echo "  MISSING: $mod"
        MISSING=1
    fi
done

if [ $MISSING -eq 1 ]; then
    echo "WARNING: 部分关键模块缺失"
else
    echo "  所有关键模块验证通过"
fi

echo ""
echo "============================================"
echo " 提取完成"
echo " vmlinuz:  ${OUTPUT_DIR}/vmlinuz"
echo " modules:  ${OUTPUT_DIR}/modules.tar.gz"
echo " 版本:     ${REAL_KVER}"
echo "============================================"
echo ""
echo "下一步: ./scripts/inject-modules.sh ubuntu"
