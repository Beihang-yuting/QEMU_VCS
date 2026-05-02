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
INJECT_ONLY=false
if [ "${2:-}" = "--inject-only" ]; then
    INJECT_ONLY=true
fi
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

# ---- 验证 headers 目录可用于编译（关键 symlinks 不 broken）----
_verify_headers() {
    local hdr_dir="$1"
    [ -f "${hdr_dir}/Makefile" ] || return 1
    # 检查 scripts/ 目录存在且不是 broken symlink
    if [ -L "${hdr_dir}/scripts" ]; then
        [ -d "${hdr_dir}/scripts" ] || return 1
    fi
    # 检查 Makefile.ubsan 是否可达
    if grep -q "Makefile.ubsan" "${hdr_dir}/Makefile" 2>/dev/null; then
        local ubsan_path
        ubsan_path=$(grep "Makefile.ubsan" "${hdr_dir}/Makefile" | head -1 | grep -oP '\S*Makefile\.ubsan' || true)
        if [ -n "$ubsan_path" ] && [ ! -f "${hdr_dir}/${ubsan_path}" ]; then
            return 1
        fi
    fi
    return 0
}

# ---- 修复 broken symlinks（common 包缺失时用 arch 包自身的文件补全）----
_fix_broken_symlinks() {
    local hdr_dir="$1"
    local base_ver="${KVER%-generic}"
    local common_dir
    common_dir="$(dirname "$hdr_dir")/linux-headers-${base_ver}"

    # 如果 scripts 是 broken symlink 且 common 目录不存在
    if [ -L "${hdr_dir}/scripts" ] && [ ! -d "${hdr_dir}/scripts" ]; then
        if [ -d "$common_dir/scripts" ]; then
            info "修复 scripts symlink -> ${common_dir}/scripts"
            rm -f "${hdr_dir}/scripts"
            ln -sf "${common_dir}/scripts" "${hdr_dir}/scripts"
        else
            # common 目录也没有 scripts，无法修复
            return 1
        fi
    fi
    return 0
}

# ---- 下载并提取 kernel headers ----
download_headers() {
    local headers_dir="${PROJECT_DIR}/build/kheaders-${KVER}"

    # 检查缓存：deb 解压后在 usr/src/linux-headers-*/
    local cached_root=""
    cached_root=$(find "$headers_dir" -maxdepth 4 -type d -name "linux-headers-${KVER}" 2>/dev/null | head -1)
    if [ -n "$cached_root" ] && _verify_headers "$cached_root"; then
        info "Kernel headers 已缓存: ${cached_root}"
        KDIR="$cached_root"
        return 0
    fi

    # 检查本机是否有匹配 Guest 内核版本的 headers
    if [ -d "/lib/modules/${KVER}/build" ] && _verify_headers "/lib/modules/${KVER}/build"; then
        KDIR="/lib/modules/${KVER}/build"
        ok "使用本机 kernel headers（精确匹配）: ${KDIR}"
        return 0
    fi

    local download_dir="${PROJECT_DIR}/build/kheaders-download"
    mkdir -p "$download_dir"
    cd "$download_dir"

    case "$GUEST_TYPE" in
        ubuntu)
            # Ubuntu headers 分两个包:
            #   linux-headers-<base_ver>          -- 通用 scripts/Makefile（all 架构）
            #   linux-headers-<KVER>              -- 架构相关配置（amd64）
            local base_ver="${KVER%-generic}"  # e.g. 6.8.0-107
            local hdr_common="linux-headers-${base_ver}"
            local hdr_arch="linux-headers-${KVER}"

            # 推断 Ubuntu suite
            local _kver_major="${KVER%%.*}"
            local _kver_rest="${KVER#*.}"
            local _kver_minor="${_kver_rest%%.*}"
            local _suite="noble"
            case "${_kver_major}.${_kver_minor}" in
                6.8|6.11) _suite="noble" ;;
                6.5) _suite="mantic" ;;
                5.15) _suite="jammy" ;;
                5.4) _suite="focal" ;;
            esac
            local _mirror="http://archive.ubuntu.com/ubuntu"

            mkdir -p "$headers_dir"

            for hdr_pkg in "$hdr_common" "$hdr_arch"; do
                info "下载 Ubuntu kernel headers: ${hdr_pkg}..."
                local deb_file=""

                # 已下载则跳过
                deb_file=$(ls "${hdr_pkg}"_*.deb 2>/dev/null | head -1 || true)
                if [ -n "$deb_file" ] && [ -s "$deb_file" ]; then
                    info "  ${hdr_pkg} 已存在，跳过下载"
                else
                    # 尝试 apt download
                    if command -v apt &>/dev/null; then
                        apt download "$hdr_pkg" 2>/dev/null || true
                    fi
                    deb_file=$(ls "${hdr_pkg}"_*.deb 2>/dev/null | head -1 || true)

                    # fallback: 查询 Packages.gz 索引获取精确 URL
                    if [ -z "$deb_file" ]; then
                        # 通用包是 all 架构，arch 包是 amd64
                        local _pkg_arch="amd64"
                        if [ "$hdr_pkg" = "$hdr_common" ]; then
                            _pkg_arch="all"
                        fi
                        local _pkg_url=""
                        for _component in "${_suite}-updates" "${_suite}"; do
                            local _idx_url="${_mirror}/dists/${_component}/main/binary-${_pkg_arch}/Packages.gz"
                            _pkg_url=$(curl -sf "$_idx_url" 2>/dev/null | gunzip 2>/dev/null | \
                                awk -v pkg="$hdr_pkg" '
                                    /^Package:/ { found = ($2 == pkg) }
                                    found && /^Filename:/ { print $2; exit }
                                ') || true
                            [ -n "$_pkg_url" ] && break
                        done
                        if [ -n "$_pkg_url" ]; then
                            local _filename
                            _filename=$(basename "$_pkg_url")
                            info "  从 ${_suite} 镜像下载: ${_filename}"
                            curl -fSL -o "$_filename" "${_mirror}/${_pkg_url}" 2>/dev/null && \
                                deb_file="$_filename" || true
                        fi
                    fi
                fi

                if [ -n "$deb_file" ] && [ -s "$deb_file" ]; then
                    ar x "$deb_file"
                    tar xf data.tar.* -C "$headers_dir" 2>/dev/null
                    rm -f data.tar.* control.tar.* debian-binary
                    ok "  ${hdr_pkg} 提取完成"
                else
                    warn "  ${hdr_pkg} 下载失败"
                fi
            done
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

    # 清理下载临时文件
    rm -rf "$download_dir"

    # 查找 arch-specific headers 目录（如 linux-headers-6.8.0-107-generic）
    local hdr_root=""
    hdr_root=$(find "$headers_dir" -maxdepth 4 -type d -name "linux-headers-${KVER}" 2>/dev/null | head -1)
    if [ -z "$hdr_root" ]; then
        # fallback: 任意 linux-headers-* 目录
        hdr_root=$(find "$headers_dir" -maxdepth 4 -type d -name "linux-headers-*" 2>/dev/null | head -1)
    fi

    if [ -n "$hdr_root" ] && [ -f "${hdr_root}/Makefile" ]; then
        # 尝试修复 broken symlinks（common 包下载失败时）
        _fix_broken_symlinks "$hdr_root" 2>/dev/null || true

        if _verify_headers "$hdr_root"; then
            KDIR="$hdr_root"
            ok "Kernel build dir: ${KDIR}"
            return 0
        else
            warn "Headers 目录不完整（通用包下载失败）: ${hdr_root}"
        fi
    fi

    # ---- fallback: 使用 host 内核 headers ----
    local host_kver
    host_kver=$(uname -r)
    local host_kdir="/lib/modules/${host_kver}/build"
    if [ -d "$host_kdir" ] && _verify_headers "$host_kdir"; then
        warn "Guest 内核 headers 不可用，回退使用 host 内核 headers"
        warn "  Guest 内核: ${KVER}"
        warn "  Host  内核: ${host_kver}"
        warn "  cosim_nic.ko 将按 host 内核编译，Guest 中需要 insmod --force"
        KDIR="$host_kdir"
        FORCE_INSMOD=true
        return 0
    fi

    fail "未找到可用的 kernel headers"
    fail "  Guest 版本 ${KVER} 的 headers 下载不完整"
    fail "  Host 版本 ${host_kver} 的 headers 也未安装"
    fail "  请安装: sudo apt install linux-headers-${host_kver}"
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

    make $make_args clean 2>/dev/null || true
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
        local work="${PROJECT_DIR}/build/initramfs-inject"
        rm -rf "$work" && mkdir -p "$work/lib/modules" "$work/etc/cosim" "$work/etc/local.d"

        cp "$COSIM_NIC_KO" "$work/lib/modules/cosim_nic.ko"
        local _insmod_opts=""
        [ "$FORCE_INSMOD" = true ] && _insmod_opts="force=true"
        printf "mode=stub\nko_name=cosim_nic.ko\n${_insmod_opts:+${_insmod_opts}\n}" > "$work/etc/cosim/driver.conf"
        cp "${PROJECT_DIR}/guest/overlay/etc/local.d/cosim-driver.start" "$work/etc/local.d/" 2>/dev/null || true
        chmod +x "$work/etc/local.d/cosim-driver.start" 2>/dev/null || true

        cd "$work"
        find . | cpio -o -H newc 2>/dev/null | gzip >> "$initramfs"
        cd "$PROJECT_DIR"
        rm -rf "$work"
        ok "已追加到 initramfs"
    elif [ -f "$rootfs" ]; then
        # Ubuntu: 无 initramfs，注入 rootfs
        if [ "$(id -u)" = "0" ] || sudo -n true 2>/dev/null; then
            local mnt="${PROJECT_DIR}/build/rootfs-mnt"
            mkdir -p "$mnt"
            sudo mount -o loop "$rootfs" "$mnt"
            sudo mkdir -p "$mnt/lib/modules" "$mnt/etc/cosim" "$mnt/etc/local.d"
            sudo cp "$COSIM_NIC_KO" "$mnt/lib/modules/cosim_nic.ko"
            local _insmod_opts=""
            [ "$FORCE_INSMOD" = true ] && _insmod_opts="force=true"
            printf "mode=stub\nko_name=cosim_nic.ko\n${_insmod_opts:+${_insmod_opts}\n}" | sudo tee "$mnt/etc/cosim/driver.conf" > /dev/null
            sudo cp "${PROJECT_DIR}/guest/overlay/etc/local.d/cosim-driver.start" "$mnt/etc/local.d/" 2>/dev/null || true
            sudo chmod +x "$mnt/etc/local.d/cosim-driver.start" 2>/dev/null || true
            sudo umount "$mnt"
            rmdir "$mnt" 2>/dev/null || true
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
FORCE_INSMOD=false

info "=== cosim_nic.ko 自动编译+注入 (${GUEST_TYPE}) ==="

# --inject-only 模式: 跳过编译，直接注入用户指定的 .ko
if [ "$INJECT_ONLY" = true ]; then
    if [ -z "${COSIM_NIC_KO:-}" ] || [ ! -f "${COSIM_NIC_KO:-}" ]; then
        fail "COSIM_NIC_KO 未设置或文件不存在: ${COSIM_NIC_KO:-（未设置）}"
        fail "用法: COSIM_NIC_KO=/path/to/your.ko $0 ${GUEST_TYPE} --inject-only"
        exit 1
    fi
    info "注入自定义驱动: ${COSIM_NIC_KO}"
    inject_driver
    ok "=== 完成（自定义驱动注入）==="
    exit 0
fi

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
    if [ "$FORCE_INSMOD" = true ]; then
        warn "=== 完成（用 host 内核编译，Guest 中需 insmod --force）==="
    else
        ok "=== 完成（新编译 .ko）==="
    fi
    exit 0
fi

fail "=== cosim_nic.ko 自动化失败 ==="
fail "手动步骤:"
fail "  1. 获取 linux-headers-${KVER} 并解压"
fail "  2. cd guest/driver && make KDIR=/path/to/headers"
fail "  3. 将 cosim_nic.ko 复制到 Guest /lib/modules/"
exit 1
