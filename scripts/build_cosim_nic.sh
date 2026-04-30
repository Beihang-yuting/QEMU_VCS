#!/bin/bash
# ============================================================
# build_cosim_nic.sh — 编译 cosim_nic.ko 并注入 Guest 镜像
#
# 用法:
#   ./scripts/build_cosim_nic.sh [GUEST_TYPE]
#
# 支持的 Guest 类型: ubuntu, debian
# 自动检测内核版本，下载 headers，编译，注入到 initramfs/rootfs
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRIVER_DIR="${PROJECT_DIR}/guest/driver"
PREBUILT_DIR="${DRIVER_DIR}/prebuilt"

GUEST_TYPE="${1:-ubuntu}"
IMAGES_DIR="${PROJECT_DIR}/guest/images/${GUEST_TYPE}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

# ---- 检测 Guest 内核版本 ----
detect_kernel_version() {
    local kernel_file=""
    for f in "${IMAGES_DIR}/vmlinuz" "${IMAGES_DIR}/bzImage"; do
        [ -f "$f" ] && kernel_file="$f" && break
    done
    if [ -z "$kernel_file" ]; then
        fail "未找到内核文件: ${IMAGES_DIR}/vmlinuz 或 bzImage"
        exit 1
    fi

    KVER=$(file "$kernel_file" | grep -oP 'version \K[^ ]+' || true)
    if [ -z "$KVER" ]; then
        fail "无法检测内核版本: $kernel_file"
        exit 1
    fi
    info "Guest 内核版本: $KVER (${GUEST_TYPE})"
}

# ---- 检查预编译 .ko 是否可用 ----
check_prebuilt() {
    local ko="${PREBUILT_DIR}/cosim_nic_${KVER}.ko"
    if [ -f "$ko" ]; then
        ok "找到预编译 .ko: $ko"
        COSIM_NIC_KO="$ko"
        return 0
    fi
    return 1
}

# ---- 下载并提取 kernel headers ----
download_headers() {
    local headers_dir="/tmp/cosim-kheaders-${KVER}"

    if [ -d "${headers_dir}" ] && [ -f "${headers_dir}/Makefile" ]; then
        info "Kernel headers 已缓存: ${headers_dir}"
        KDIR="$headers_dir"
        return 0
    fi

    # 检查本机是否有匹配的 headers
    if [ -d "/lib/modules/${KVER}/build" ] && [ -f "/lib/modules/${KVER}/build/Makefile" ]; then
        KDIR="/lib/modules/${KVER}/build"
        ok "使用本机 kernel headers: ${KDIR}"
        return 0
    fi

    mkdir -p /tmp/cosim-kheaders-download
    cd /tmp/cosim-kheaders-download

    case "$GUEST_TYPE" in
        ubuntu)
            local hdr_pkg="linux-headers-${KVER}"
            info "下载 Ubuntu kernel headers: ${hdr_pkg}..."

            # 尝试 apt download（最可靠）
            if command -v apt &>/dev/null; then
                apt download "$hdr_pkg" 2>/dev/null || true
            fi

            local deb_file=$(ls ${hdr_pkg}*.deb 2>/dev/null | head -1)

            # fallback: 从镜像下载
            if [ -z "$deb_file" ]; then
                local base_ver="${KVER%-generic}"
                for mirror in \
                    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/l/linux" \
                    "http://archive.ubuntu.com/ubuntu/pool/main/l/linux"; do
                    wget -q --timeout=60 -O "${hdr_pkg}.deb" \
                        "${mirror}/${hdr_pkg}_${base_ver}.${base_ver##*-}_amd64.deb" 2>/dev/null && \
                        deb_file="${hdr_pkg}.deb" && break || true
                done
            fi

            if [ -n "$deb_file" ] && [ -s "$deb_file" ]; then
                mkdir -p "$headers_dir"
                ar x "$deb_file"
                tar xf data.tar.* -C "$headers_dir" 2>/dev/null
                ok "Headers 提取完成"
            fi
            ;;

        debian)
            local hdr_pkg="linux-headers-${KVER}"
            info "下载 Debian kernel headers: ${hdr_pkg}..."

            if command -v apt &>/dev/null; then
                apt download "$hdr_pkg" 2>/dev/null || true
            fi

            local deb_file=$(ls ${hdr_pkg}*.deb 2>/dev/null | head -1)

            if [ -z "$deb_file" ]; then
                for mirror in \
                    "https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/l/linux" \
                    "http://deb.debian.org/debian/pool/main/l/linux"; do
                    wget -q --timeout=60 -O "${hdr_pkg}.deb" \
                        "${mirror}/${hdr_pkg}_*_amd64.deb" 2>/dev/null && \
                        deb_file="${hdr_pkg}.deb" && break || true
                done
            fi

            if [ -n "$deb_file" ] && [ -s "$deb_file" ]; then
                mkdir -p "$headers_dir"
                ar x "$deb_file"
                tar xf data.tar.* -C "$headers_dir" 2>/dev/null
                ok "Headers 提取完成"
            fi
            ;;
    esac

    # 查找 Makefile 位置
    local makefile_path=$(find "$headers_dir" -maxdepth 5 -name "Makefile" \
        -path "*/linux-headers-*/Makefile" 2>/dev/null | head -1)
    if [ -z "$makefile_path" ]; then
        makefile_path=$(find "$headers_dir" -maxdepth 3 -name "Makefile" 2>/dev/null | head -1)
    fi

    if [ -n "$makefile_path" ]; then
        KDIR="$(dirname "$makefile_path")"
        ok "Kernel build dir: ${KDIR}"
        return 0
    fi

    fail "未找到 kernel headers Makefile"
    return 1
}

# ---- 编译 cosim_nic.ko ----
compile_driver() {
    info "编译 cosim_nic.ko (KDIR=${KDIR})..."
    cd "$DRIVER_DIR"

    local cc=""
    for candidate in gcc x86_64-conda-linux-gnu-gcc x86_64-linux-gnu-gcc; do
        if command -v "$candidate" &>/dev/null; then
            cc="$candidate"
            break
        fi
    done

    if [ -z "$cc" ]; then
        fail "未找到 C 编译器 (gcc)"
        return 1
    fi

    local make_args="KDIR=${KDIR}"
    if [ "$cc" != "gcc" ]; then
        make_args="$make_args CC=$cc"
        local ld="${cc/gcc/ld}"
        command -v "$ld" &>/dev/null && make_args="$make_args LD=$ld"
    fi

    make clean 2>/dev/null || true
    if make $make_args 2>&1 | tail -5; then
        if [ -f "${DRIVER_DIR}/cosim_nic.ko" ]; then
            ok "cosim_nic.ko 编译成功"
            COSIM_NIC_KO="${DRIVER_DIR}/cosim_nic.ko"

            mkdir -p "$PREBUILT_DIR"
            cp "$COSIM_NIC_KO" "${PREBUILT_DIR}/cosim_nic_${KVER}.ko"
            ok "已缓存: ${PREBUILT_DIR}/cosim_nic_${KVER}.ko"
            return 0
        fi
    fi

    fail "cosim_nic.ko 编译失败"
    return 1
}

# ---- 注入 .ko 到 Guest 镜像 ----
inject_driver() {
    info "注入 cosim_nic.ko 到 ${GUEST_TYPE} Guest..."

    local initramfs="${IMAGES_DIR}/initramfs.gz"
    local rootfs="${IMAGES_DIR}/rootfs.ext4"

    if [ -f "$initramfs" ]; then
        # Debian: 有 initramfs，追加 .ko
        info "注入到 initramfs..."
        local work="/tmp/cosim-initramfs-inject"
        rm -rf "$work" && mkdir -p "$work/lib/modules" "$work/etc/cosim" "$work/etc/local.d"

        cp "$COSIM_NIC_KO" "$work/lib/modules/cosim_nic.ko"
        printf "mode=stub\nko_name=cosim_nic.ko\n" > "$work/etc/cosim/driver.conf"
        cp "${PROJECT_DIR}/guest/overlay/etc/local.d/cosim-driver.start" "$work/etc/local.d/" 2>/dev/null || true
        chmod +x "$work/etc/local.d/cosim-driver.start" 2>/dev/null || true

        cd "$work"
        find . | cpio -o -H newc 2>/dev/null | gzip >> "$initramfs"
        ok "已追加到 initramfs"
    elif [ -f "$rootfs" ]; then
        # Ubuntu: 无 initramfs，注入 rootfs
        if [ "$(id -u)" = "0" ] || sudo -n true 2>/dev/null; then
            local mnt="/tmp/cosim-rootfs-mnt"
            mkdir -p "$mnt"
            sudo mount -o loop "$rootfs" "$mnt"
            sudo mkdir -p "$mnt/lib/modules" "$mnt/etc/cosim" "$mnt/etc/local.d"
            sudo cp "$COSIM_NIC_KO" "$mnt/lib/modules/cosim_nic.ko"
            printf "mode=stub\nko_name=cosim_nic.ko\n" | sudo tee "$mnt/etc/cosim/driver.conf" > /dev/null
            sudo cp "${PROJECT_DIR}/guest/overlay/etc/local.d/cosim-driver.start" "$mnt/etc/local.d/" 2>/dev/null || true
            sudo chmod +x "$mnt/etc/local.d/cosim-driver.start" 2>/dev/null || true
            sudo umount "$mnt"
            ok "已写入 rootfs"
        else
            warn "注入 rootfs 需要 sudo 权限"
            warn "请手动执行:"
            warn "  sudo mount -o loop ${rootfs} /mnt"
            warn "  sudo cp ${COSIM_NIC_KO} /mnt/lib/modules/"
            warn "  sudo umount /mnt"
            return 1
        fi
    else
        fail "未找到 initramfs 或 rootfs"
        return 1
    fi
}

# ============================================================
# 主流程
# ============================================================
info "=== cosim_nic.ko 自动编译+注入 (${GUEST_TYPE}) ==="

detect_kernel_version

# 步骤 1: 检查预编译
if check_prebuilt; then
    inject_driver
    ok "=== 完成（使用预编译 .ko）==="
    exit 0
fi

# 步骤 2: 下载 headers + 编译
if download_headers && compile_driver; then
    inject_driver
    ok "=== 完成（新编译 .ko）==="
    exit 0
fi

fail "=== cosim_nic.ko 自动化失败 ==="
fail "手动步骤:"
fail "  1. 获取 linux-headers-${KVER} 并解压"
fail "  2. cd guest/driver && make KDIR=/path/to/headers"
fail "  3. 将 cosim_nic.ko 复制到 Guest /lib/modules/"
exit 1
