#!/bin/bash
# setup-ubuntu-kernel.sh — 从 Ubuntu apt 仓库提取 LTS 内核及模块
# 用于 cosim guest，包含 VFIO/RDMA/NVMe-oF 等完整模块
#
# 支持预下载: 将 .deb 文件放到 WORK_DIR 可跳过下载
#   <PROJECT>/build/ubuntu-kernel/linux-image-unsigned-<KVER>_*.deb
#   <PROJECT>/build/ubuntu-kernel/linux-modules-<KVER>_*.deb
#   <PROJECT>/build/ubuntu-kernel/linux-modules-extra-<KVER>_*.deb
set -euo pipefail

KVER="${1:-6.8.0-107-generic}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_DIR}/guest/images/ubuntu"
WORK_DIR="${PROJECT_DIR}/build/ubuntu-kernel"

# 从内核版本推断 Ubuntu 代号（用于构建下载 URL）
_kver_major="${KVER%%.*}"
_kver_rest="${KVER#*.}"
_kver_minor="${_kver_rest%%.*}"
case "${_kver_major}.${_kver_minor}" in
    6.8|6.11) _UBUNTU_SUITE="noble" ;;
    6.5)      _UBUNTU_SUITE="mantic" ;;
    6.2)      _UBUNTU_SUITE="lunar" ;;
    5.15)     _UBUNTU_SUITE="jammy" ;;
    5.4)      _UBUNTU_SUITE="focal" ;;
    *)        _UBUNTU_SUITE="noble" ;;
esac
_MIRROR_BASE="http://archive.ubuntu.com/ubuntu"

echo "============================================"
echo " Ubuntu 内核提取: ${KVER}"
echo " 目标 Suite: ${_UBUNTU_SUITE}"
echo "============================================"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR"

# ---- 1. 下载 deb 包 ----
echo "[1/4] 下载内核包..."

# 尝试多种方式下载单个包
_download_pkg() {
    local pkg="$1"

    # 已存在则跳过
    if ls "${pkg}"_*.deb &>/dev/null; then
        echo "  $pkg 已存在，跳过"
        return 0
    fi

    # 方式 1: apt-get download（本机 apt 源包含对应版本时可用）
    echo "  尝试 apt-get download $pkg..."
    if apt-get download "$pkg" 2>/dev/null; then
        return 0
    fi
    echo "  apt-get download 失败（本机 apt 源可能不含 ${_UBUNTU_SUITE} 仓库）"

    # 方式 2: 从 Ubuntu 官方镜像直接下载（不依赖本机 apt 源）
    echo "  尝试从 ${_UBUNTU_SUITE} 官方镜像直接下载..."
    local _pkg_url=""
    for _component in "${_UBUNTU_SUITE}-updates" "${_UBUNTU_SUITE}"; do
        local _packages_url="${_MIRROR_BASE}/dists/${_component}/main/binary-amd64/Packages.gz"
        _pkg_url=$(curl -sf "$_packages_url" 2>/dev/null | gunzip 2>/dev/null | \
            awk -v pkg="$pkg" '
                /^Package:/ { found = ($2 == pkg) }
                found && /^Filename:/ { print $2; exit }
            ') || true
        [ -n "$_pkg_url" ] && break
    done

    if [ -n "$_pkg_url" ]; then
        local _full_url="${_MIRROR_BASE}/${_pkg_url}"
        local _filename
        _filename=$(basename "$_pkg_url")
        echo "  下载: $_filename"
        if curl -fSL -o "$_filename" "$_full_url"; then
            return 0
        fi
    fi

    return 1
}

_DOWNLOAD_FAILED=false
for pkg in \
    "linux-image-unsigned-${KVER}" \
    "linux-modules-${KVER}" \
    "linux-modules-extra-${KVER}"; do
    if ! _download_pkg "$pkg"; then
        echo "  [FAIL] 无法下载: $pkg"
        _DOWNLOAD_FAILED=true
    fi
done

if [ "$_DOWNLOAD_FAILED" = true ]; then
    echo ""
    echo "============================================"
    echo " 自动下载失败"
    echo "============================================"
    echo ""
    echo " 原因: 内核 ${KVER} 来自 Ubuntu ${_UBUNTU_SUITE}，"
    echo "       本机 apt 源不含该版本，且官方镜像也无法访问"
    echo ""
    echo " === 手动下载方法 ==="
    echo ""
    echo " 在有网络的机器上（Ubuntu ${_UBUNTU_SUITE} 或任意能访问外网的机器）："
    echo ""
    echo "   apt-get download \\"
    echo "     linux-image-unsigned-${KVER} \\"
    echo "     linux-modules-${KVER} \\"
    echo "     linux-modules-extra-${KVER}"
    echo ""
    echo " 或从浏览器下载（搜索包名即可）："
    echo "   https://packages.ubuntu.com/${_UBUNTU_SUITE}/amd64/linux-image-unsigned-${KVER}/download"
    echo "   https://packages.ubuntu.com/${_UBUNTU_SUITE}/amd64/linux-modules-${KVER}/download"
    echo "   https://packages.ubuntu.com/${_UBUNTU_SUITE}/amd64/linux-modules-extra-${KVER}/download"
    echo ""
    echo " === 放置位置 ==="
    echo ""
    echo " 将 3 个 .deb 文件拷贝到本机以下目录："
    echo "   ${WORK_DIR}/"
    echo ""
    echo " 然后重新运行:"
    echo "   $0 ${KVER}"
    echo " 或重新运行 setup.sh（会自动调用本脚本）"
    echo ""
    exit 1
fi

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

# ---- 清理临时解压目录（保留 .deb 便于重复使用）----
cd "$WORK_DIR"
rm -rf extract

echo ""
echo "============================================"
echo " 提取完成"
echo " vmlinuz:  ${OUTPUT_DIR}/vmlinuz"
echo " modules:  ${OUTPUT_DIR}/modules.tar.gz"
echo " 版本:     ${REAL_KVER}"
echo "============================================"
echo ""
echo "下一步: ./scripts/inject-modules.sh ubuntu"
