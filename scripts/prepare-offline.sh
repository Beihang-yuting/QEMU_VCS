#!/bin/bash
# ============================================================
# prepare-offline.sh — 在外网机器上打包离线安装包
#
# 用法: ./scripts/prepare-offline.sh [选项]
#   --guest ubuntu|debian   Guest 类型（默认 ubuntu）
#   --output <path>         输出 zip 路径（默认 cosim-offline-<date>.zip）
#   --skip-rootfs           跳过 rootfs 构建（已有镜像时）
#
# 产物: 一个 zip 文件，包含内网 setup.sh 所需的全部素材
# 内网使用: ./setup.sh 交互菜单选择"导入离线包"
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

GUEST_TYPE="ubuntu"
SKIP_ROOTFS=false
OUTPUT=""
KVER="6.8.0-107-generic"
QEMU_VERSION="v9.2.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --guest) GUEST_TYPE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --skip-rootfs) SKIP_ROOTFS=true; shift ;;
        --help|-h)
            echo "用法: $0 [--guest ubuntu|debian] [--output path.zip] [--skip-rootfs]"
            exit 0 ;;
        *) fail "未知参数: $1"; exit 1 ;;
    esac
done

OUTPUT="${OUTPUT:-${PROJECT_DIR}/cosim-offline-$(date +%Y%m%d).zip}"
STAGING="${PROJECT_DIR}/build/offline-staging"

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}       CoSim 离线包打包工具${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
info "Guest 类型: ${GUEST_TYPE}"
info "输出路径:   ${OUTPUT}"
echo ""

# ---- 检查依赖 ----
for cmd in curl zip; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "缺少依赖: $cmd"
        exit 1
    fi
done

# ---- 清理 staging 目录 ----
rm -rf "$STAGING"
mkdir -p "$STAGING"/{qemu-src,guest/debian,guest/ubuntu,kheaders}

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
    info "从 GitHub 下载 QEMU ${QEMU_VERSION}..."
    TARBALL_GZ="${TARBALL%.tar.xz}.tar.gz"
    if curl -fSL -o "$TARBALL_GZ" \
        "https://github.com/qemu/qemu/archive/refs/tags/${QEMU_VERSION}.tar.gz"; then
        ok "QEMU 源码下载完成: $(du -h "$TARBALL_GZ" | cut -f1)"
        PASS=$((PASS + 1))
    else
        fail "QEMU 源码下载失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ============================================================
# [2/5] 构建 Debian rootfs
# ============================================================
echo ""
echo -e "${BOLD}[2/5] Debian rootfs${NC}"

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
if [ -f "$PREBUILT" ]; then
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
# 写入元数据
# ============================================================
cat > "${STAGING}/offline-meta.env" << EOF
# CoSim 离线包元数据（自动生成，请勿修改）
OFFLINE_VERSION=1
OFFLINE_DATE=$(date +%Y-%m-%d)
OFFLINE_GUEST_TYPE=${GUEST_TYPE}
OFFLINE_KVER=${KVER}
OFFLINE_QEMU_VERSION=${QEMU_VERSION}
OFFLINE_HAS_DEBIAN_ROOTFS=$([ -f "${STAGING}/guest/debian/rootfs.ext4" ] && echo true || echo false)
OFFLINE_HAS_UBUNTU_ROOTFS=$([ -f "${STAGING}/guest/ubuntu/rootfs.ext4" ] && echo true || echo false)
OFFLINE_HAS_UBUNTU_KERNEL=$([ -f "${STAGING}/guest/ubuntu/vmlinuz" ] && echo true || echo false)
OFFLINE_HAS_KHEADERS=$_headers_ok
OFFLINE_HAS_COSIM_NIC=$([ -f "${STAGING}/driver/cosim_nic_${KVER}.ko" ] && echo true || echo false)
EOF

# ============================================================
# 打包
# ============================================================
echo ""
echo -e "${BOLD}打包离线安装包...${NC}"

cd "$STAGING"
zip -qr "$OUTPUT" .

cd "$PROJECT_DIR"
rm -rf "$STAGING"

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}       打包完成${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  文件: ${OUTPUT}"
echo "  大小: $(du -h "$OUTPUT" | cut -f1)"
echo "  成功: ${PASS}  失败: ${FAIL_COUNT}"
echo ""

echo -e "${BOLD}  内网使用方法:${NC}"
echo "    1. 将 $(basename "$OUTPUT") 拷贝到内网机器的项目目录"
echo "    2. 运行 ./setup.sh"
echo "    3. 选择「导入离线包」"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    warn "有 ${FAIL_COUNT} 个组件打包失败，部分功能可能需要在内网手动处理"
    exit 1
fi
