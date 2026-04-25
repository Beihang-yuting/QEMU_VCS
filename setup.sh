#!/bin/bash
# ============================================================
# CoSim Platform 安装脚本
# 用法：
#   ./setup.sh                          # 交互式菜单
#   ./setup.sh --mode local --guest minimal --qemu-src download
#   ./setup.sh --mode vcs-only          # 仅编译 VCS 侧
#   ./setup.sh --help
# ============================================================
set -euo pipefail

# ---- 全局变量 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
WARN_MSGS=()

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; WARN_MSGS+=("$*"); }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
header() {
    echo ""
    echo "========================================================"
    echo -e "${CYAN}$*${NC}"
    echo "========================================================"
}

# 版本比较函数
version_ge() {
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

# ---- PATH 增强 ----
for extra_path in "$HOME/miniconda3/bin" "$HOME/.local/bin" "/usr/local/bin"; do
    if [ -d "$extra_path" ] && [[ ":$PATH:" != *":$extra_path:"* ]]; then
        export PATH="$extra_path:$PATH"
    fi
done

# ============================================================
# 用法帮助
# ============================================================
usage() {
    cat <<'USAGE'
CoSim Platform 安装脚本

用法: ./setup.sh [选项]

部署模式 (--mode):
  local       本地全栈仿真 — QEMU + VCS 在同一台机器（SHM 通信）
  qemu-only   仅 QEMU 侧 — 编译 QEMU + Bridge，VCS 在远程机器（TCP 通信）
  vcs-only    仅 VCS 侧  — 编译 VCS + Bridge，QEMU 在远程机器（TCP 通信）

Guest 环境 (--guest, 仅 local/qemu-only 模式):
  minimal     轻量 initramfs — virtio 驱动 + ping/iperf/netcat（基础测试）
  full        完整磁盘镜像  — 可安装自定义驱动、扩展业务测试

QEMU 源码 (--qemu-src, 仅 local/qemu-only 模式):
  download    从 GitHub 下载 QEMU v9.2.0
  path:<dir>  使用本地已有源码，例: --qemu-src path:/home/user/qemu
  skip        跳过 QEMU 编译（仅编译 Bridge）

其他选项:
  --help      显示此帮助信息

示例:
  ./setup.sh                                          # 交互式菜单
  ./setup.sh --mode local --guest minimal             # 本地全栈 + 轻量测试
  ./setup.sh --mode local --guest full                # 本地全栈 + 完整镜像
  ./setup.sh --mode qemu-only --guest minimal         # QEMU 侧远程部署
  ./setup.sh --mode vcs-only                          # VCS 侧远程部署
USAGE
    exit 0
}

# ============================================================
# 解析命令行参数
# ============================================================
SETUP_MODE=""
GUEST_TYPE=""
QEMU_SRC_OPT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            SETUP_MODE="$2"; shift 2 ;;
        --guest)
            GUEST_TYPE="$2"; shift 2 ;;
        --qemu-src)
            QEMU_SRC_OPT="$2"; shift 2 ;;
        --help|-h)
            usage ;;
        *)
            fail "未知参数: $1"
            usage ;;
    esac
done

# ============================================================
# 交互式菜单（无参数时）
# ============================================================
interactive_menu() {
    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}       CoSim Platform 安装向导${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo ""

    # ---- 选择部署模式 ----
    echo -e "${BOLD}[1] 选择部署模式${NC}"
    echo ""
    echo "  1) local      — 本地全栈仿真"
    echo "                   QEMU + VCS 在同一台机器，通过 SHM 通信"
    echo "                   适用于: 开发调试、功能验证"
    echo ""
    echo "  2) qemu-only  — 仅 QEMU 侧（远程模式）"
    echo "                   编译 QEMU + Bridge，VCS 在另一台机器"
    echo "                   通过 TCP 与远程 VCS 通信"
    echo ""
    echo "  3) vcs-only   — 仅 VCS 侧（远程模式）"
    echo "                   编译 VCS + Bridge，QEMU 在另一台机器"
    echo "                   通过 TCP 与远程 QEMU 通信"
    echo ""

    while true; do
        read -rp "请选择 [1/2/3]: " choice
        case "$choice" in
            1) SETUP_MODE="local"; break ;;
            2) SETUP_MODE="qemu-only"; break ;;
            3) SETUP_MODE="vcs-only"; break ;;
            *) echo "  无效选择，请输入 1、2 或 3" ;;
        esac
    done
    ok "部署模式: ${SETUP_MODE}"
    echo ""

    # ---- 选择 Guest 环境（仅 QEMU 相关模式）----
    if [ "$SETUP_MODE" != "vcs-only" ]; then
        echo -e "${BOLD}[2] 选择 Guest 环境${NC}"
        echo ""
        echo "  1) minimal  — 轻量 initramfs"
        echo "                 包含: virtio 驱动、ping、iperf3、netcat、arping"
        echo "                 适用于: 基础网络功能测试、打流测试"
        echo ""
        echo "  2) full     — 完整 Linux 磁盘镜像 (qcow2)"
        echo "                 包含: 完整包管理器，可安装自定义驱动"
        echo "                 适用于: 全能力测试、驱动开发、业务扩展"
        echo ""

        while true; do
            read -rp "请选择 [1/2]: " choice
            case "$choice" in
                1) GUEST_TYPE="minimal"; break ;;
                2) GUEST_TYPE="full"; break ;;
                *) echo "  无效选择，请输入 1 或 2" ;;
            esac
        done
        ok "Guest 环境: ${GUEST_TYPE}"
        echo ""

        # ---- 选择 QEMU 源码来源 ----
        echo -e "${BOLD}[3] 选择 QEMU 源码来源${NC}"
        echo ""
        echo "  1) download  — 从 GitHub 下载 QEMU v9.2.0（需要网络）"
        echo "  2) local     — 指定本地已有的 QEMU 源码路径"
        echo "  3) skip      — 跳过 QEMU 编译（仅编译 Bridge 库）"
        echo ""

        while true; do
            read -rp "请选择 [1/2/3]: " choice
            case "$choice" in
                1) QEMU_SRC_OPT="download"; break ;;
                2)
                    read -rp "  请输入 QEMU 源码路径: " qemu_path
                    if [ -d "$qemu_path" ] && [ -f "$qemu_path/configure" ]; then
                        QEMU_SRC_OPT="path:${qemu_path}"
                        break
                    else
                        echo "  路径无效或不包含 QEMU 源码（未找到 configure 文件）"
                    fi
                    ;;
                3) QEMU_SRC_OPT="skip"; break ;;
                *) echo "  无效选择，请输入 1、2 或 3" ;;
            esac
        done
        ok "QEMU 源码: ${QEMU_SRC_OPT}"
    fi
}

# 如果未通过命令行指定模式，进入交互式菜单
if [ -z "$SETUP_MODE" ]; then
    interactive_menu
fi

# ---- 参数验证 ----
case "$SETUP_MODE" in
    local|qemu-only|vcs-only) ;;
    *)
        fail "无效的部署模式: ${SETUP_MODE}"
        fail "可选: local, qemu-only, vcs-only"
        exit 1
        ;;
esac

# QEMU 相关模式需要 guest 类型
if [ "$SETUP_MODE" != "vcs-only" ]; then
    GUEST_TYPE="${GUEST_TYPE:-minimal}"
    QEMU_SRC_OPT="${QEMU_SRC_OPT:-download}"

    case "$GUEST_TYPE" in
        minimal|full) ;;
        *)
            fail "无效的 Guest 类型: ${GUEST_TYPE}"
            fail "可选: minimal, full"
            exit 1
            ;;
    esac
fi

# 确定各模块是否需要编译
NEED_BRIDGE=true
NEED_QEMU=false
NEED_VCS=false
NEED_GUEST=false
NEED_TAP_BRIDGE=false

case "$SETUP_MODE" in
    local)
        NEED_QEMU=true
        NEED_VCS=true
        NEED_GUEST=true
        NEED_TAP_BRIDGE=true
        ;;
    qemu-only)
        NEED_QEMU=true
        NEED_GUEST=true
        ;;
    vcs-only)
        NEED_VCS=true
        NEED_TAP_BRIDGE=true
        ;;
esac

if [ "${QEMU_SRC_OPT:-}" = "skip" ]; then
    NEED_QEMU=false
    NEED_GUEST=false
    NEED_TAP_BRIDGE=false
fi

# ============================================================
# 显示配置摘要
# ============================================================
echo ""
echo -e "${BOLD}-------- 安装配置 --------${NC}"
echo -e "  部署模式:   ${CYAN}${SETUP_MODE}${NC}"
if [ "$SETUP_MODE" != "vcs-only" ]; then
    echo -e "  Guest 环境: ${CYAN}${GUEST_TYPE}${NC}"
    echo -e "  QEMU 源码:  ${CYAN}${QEMU_SRC_OPT}${NC}"
fi
echo -e "  编译组件:   Bridge$([ "$NEED_QEMU" = true ] && echo " + QEMU")$([ "$NEED_VCS" = true ] && echo " + VCS")$([ "$NEED_GUEST" = true ] && echo " + Guest")$([ "$NEED_TAP_BRIDGE" = true ] && echo " + TAP Bridge")"
echo ""

# ============================================================
# 动态步骤计数
# ============================================================
TOTAL_STEPS=5  # 配置 + 依赖 + Bridge + 测试 + 摘要
[ "$NEED_QEMU" = true ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$NEED_VCS" = true ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$NEED_TAP_BRIDGE" = true ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$NEED_GUEST" = true ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

CURRENT_STEP=0
next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    header "[${CURRENT_STEP}/${TOTAL_STEPS}] $*"
}

# ============================================================
# [步骤] 加载配置文件
# ============================================================
next_step "加载配置文件"

CONFIG_FILE="${PROJECT_DIR}/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=config.env
    source "$CONFIG_FILE"
    ok "已加载 ${CONFIG_FILE}"
else
    warn "未找到 config.env，使用默认值"
fi

QEMU_VERSION="${QEMU_VERSION:-v9.2.0}"
VCS_HOME="${VCS_HOME:-}"
SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
LM_LICENSE_FILE="${LM_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
export SNPSLMD_LICENSE_FILE LM_LICENSE_FILE

QEMU_DIR="${PROJECT_DIR}/third_party/qemu"
BUILD_DIR="${PROJECT_DIR}/build"
BRIDGE_LIB_DIR="${BUILD_DIR}/bridge"
VCS_SIM_DIR="${PROJECT_DIR}/vcs-tb/sim_build"
IMAGES_DIR="${PROJECT_DIR}/guest/images"

info "项目目录: ${PROJECT_DIR}"
info "部署模式: ${SETUP_MODE}"

# ============================================================
# [步骤] 检测操作系统并安装系统依赖
# ============================================================
next_step "检测操作系统并安装系统依赖"

HAS_SUDO=false
if command -v sudo &>/dev/null; then
    if sudo -n true 2>/dev/null; then
        HAS_SUDO=true
        ok "sudo 可用（免密码）"
    else
        warn "sudo 需要密码，非交互环境下跳过包安装（请确认依赖已预装）"
        info "  提示: 如需安装依赖，请以 root 身份运行或配置 NOPASSWD sudo"
    fi
else
    warn "未找到 sudo，跳过包安装（请确认依赖已预装）"
fi

install_deps() {
    if [ -f /etc/debian_version ]; then
        info "检测到 Debian/Ubuntu 系统"
        local PKGS=(
            gcc g++ make cmake git
            meson ninja-build pkg-config
            python3 python3-pip python3-venv
            cpio gzip wget
        )
        if [ "$NEED_QEMU" = true ]; then
            PKGS+=(libglib2.0-dev libpixman-1-dev libslirp-dev)
        fi
        local MISSING=()
        for pkg in "${PKGS[@]}"; do
            if ! dpkg -l "$pkg" &>/dev/null; then
                MISSING+=("$pkg")
            fi
        done
        if [ ${#MISSING[@]} -gt 0 ]; then
            info "安装缺失包: ${MISSING[*]}"
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${MISSING[@]}"
        else
            ok "所有系统依赖已安装"
        fi
    elif [ -f /etc/redhat-release ]; then
        info "检测到 CentOS/RHEL 系统"
        local PKGS=(
            gcc gcc-c++ make cmake git
            meson ninja-build pkgconfig
            python3 python3-pip
            cpio gzip wget
        )
        if [ "$NEED_QEMU" = true ]; then
            PKGS+=(glib2-devel pixman-devel libslirp-devel)
        fi
        local MISSING=()
        for pkg in "${PKGS[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
                MISSING+=("$pkg")
            fi
        done
        if [ ${#MISSING[@]} -gt 0 ]; then
            info "安装缺失包: ${MISSING[*]}"
            if command -v dnf &>/dev/null; then
                sudo dnf install -y "${MISSING[@]}"
            else
                sudo yum install -y "${MISSING[@]}"
            fi
        else
            ok "所有系统依赖已安装"
        fi
    else
        warn "未知操作系统，跳过包安装（请手动安装依赖）"
    fi
}

if [ "$HAS_SUDO" = true ]; then
    install_deps
else
    info "跳过系统包安装（无 sudo 权限）"
    info "如果编译失败，请检查以下开发库是否已安装:"
    if [ "$NEED_QEMU" = true ]; then
        info "  - glib2-devel / libglib2.0-dev (>= 2.66.0)"
        info "  - pixman-devel / libpixman-1-dev (>= 0.21.8)"
    fi
    info "  - python3 (>= 3.8), meson, ninja, cmake (>= 3.16)"
fi

# ============================================================
# 依赖版本检查
# ============================================================
echo ""
info "========================================"
info "检查依赖版本"
info "========================================"

DEP_ERRORS=()

# ---- 关键编译工具 ----
info "检查编译工具链..."
MISSING_CRITICAL=()
for tool in gcc g++ make cmake python3; do
    if command -v "$tool" &>/dev/null; then
        ver=$("$tool" --version 2>&1 | head -1 || true)
        info "  ✓ ${tool}: ${ver}"
    else
        fail "  ✗ 缺少必要工具: ${tool}"
        MISSING_CRITICAL+=("$tool")
    fi
done

if [ ${#MISSING_CRITICAL[@]} -gt 0 ]; then
    fail "缺少关键编译工具: ${MISSING_CRITICAL[*]}"
    if [ "$HAS_SUDO" = true ]; then
        fail "请运行: sudo apt-get install -y ${MISSING_CRITICAL[*]}"
    fi
    fail "安装后重新运行 setup.sh"
    exit 1
fi

# git（可选）
if command -v git &>/dev/null; then
    info "  ✓ git: $(git --version 2>&1)"
else
    warn "  ✗ git 未安装（仅影响 QEMU 源码下载）"
fi

# meson / ninja
for tool in meson ninja; do
    if command -v "$tool" &>/dev/null; then
        info "  ✓ ${tool}: $(${tool} --version 2>&1 | head -1 || true)"
    else
        warn "  ✗ ${tool} 未找到"
        warn "    安装方法: pip3 install --user ${tool}"
        DEP_ERRORS+=("${tool} 未安装")
    fi
done

# pkg-config
if ! command -v pkg-config &>/dev/null; then
    fail "  ✗ pkg-config 未安装"
    fail "    安装方法: sudo apt-get install -y pkg-config"
    DEP_ERRORS+=("pkg-config 未安装")
fi

# cmake >= 3.16
CMAKE_MIN_VER="3.16"
CMAKE_VER=$(cmake --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
if [ -n "$CMAKE_VER" ] && version_ge "$CMAKE_VER" "$CMAKE_MIN_VER"; then
    ok "cmake ${CMAKE_VER} >= ${CMAKE_MIN_VER}"
else
    fail "cmake 版本过低: ${CMAKE_VER:-未知}（需要 >= ${CMAKE_MIN_VER}）"
    fail "  Ubuntu: sudo apt-get install -y cmake"
    DEP_ERRORS+=("cmake < ${CMAKE_MIN_VER}")
fi

# Python >= 3.8 + tomli
PYTHON_MIN_VER="3.8"
PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || echo "")
if [ -n "$PYTHON_VER" ] && version_ge "$PYTHON_VER" "$PYTHON_MIN_VER"; then
    ok "Python ${PYTHON_VER} >= ${PYTHON_MIN_VER}"
    if [ "$NEED_QEMU" = true ]; then
        if ! python3 -c "import sys; exit(0 if sys.version_info >= (3,11) else 1)" 2>/dev/null; then
            if python3 -c "import tomli" 2>/dev/null; then
                ok "Python tomli 模块可用（Python < 3.11 需要）"
            else
                warn "Python < 3.11 且 tomli 未安装（QEMU configure 需要）"
                info "  自动安装 tomli..."
                if pip3 install --user tomli 2>/dev/null; then
                    ok "tomli 安装成功"
                else
                    fail "tomli 安装失败，请手动运行: pip3 install --user tomli"
                    DEP_ERRORS+=("Python tomli 模块缺失")
                fi
            fi
        fi
    fi
else
    fail "Python 版本过低: ${PYTHON_VER:-未安装}（需要 >= ${PYTHON_MIN_VER}）"
    DEP_ERRORS+=("Python < ${PYTHON_MIN_VER}")
fi

# ---- QEMU 相关依赖（仅在需要时检查）----
if [ "$NEED_QEMU" = true ]; then
    info "检查 QEMU 编译依赖..."

    # pixman >= 0.21.8
    PIXMAN_MIN_VER="0.21.8"
    PIXMAN_VER=$(pkg-config --modversion pixman-1 2>/dev/null || echo "")
    if [ -n "$PIXMAN_VER" ] && version_ge "$PIXMAN_VER" "$PIXMAN_MIN_VER"; then
        ok "pixman ${PIXMAN_VER} >= ${PIXMAN_MIN_VER}"
    else
        fail "pixman 版本不满足: ${PIXMAN_VER:-未安装}（需要 >= ${PIXMAN_MIN_VER}）"
        fail "  Ubuntu: sudo apt-get install -y libpixman-1-dev"
        DEP_ERRORS+=("pixman < ${PIXMAN_MIN_VER}")
    fi

    # zlib
    ZLIB_VER=$(pkg-config --modversion zlib 2>/dev/null || echo "")
    if [ -n "$ZLIB_VER" ]; then
        ok "zlib ${ZLIB_VER}"
    else
        fail "zlib 开发库未安装"
        fail "  Ubuntu: sudo apt-get install -y zlib1g-dev"
        DEP_ERRORS+=("zlib 未安装")
    fi

    # libslirp（可选）
    SLIRP_VER=$(pkg-config --modversion slirp 2>/dev/null || echo "")
    if [ -n "$SLIRP_VER" ]; then
        ok "libslirp ${SLIRP_VER}"
    else
        warn "libslirp 未安装（QEMU 用户网络模式需要，非必须）"
        warn "  Ubuntu: sudo apt-get install -y libslirp-dev"
    fi

    # glib >= 2.66.0（Ubuntu 20.04 核心问题）
    GLIB_MIN_VER="2.66.0"
    GLIB_BUILD_VER="2.66.8"
    GLIB_CURRENT_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "")

    NEED_GLIB_BUILD=false
    if [ -n "$GLIB_CURRENT_VER" ]; then
        if version_ge "$GLIB_CURRENT_VER" "$GLIB_MIN_VER"; then
            ok "glib ${GLIB_CURRENT_VER} >= ${GLIB_MIN_VER}"
        else
            warn "glib ${GLIB_CURRENT_VER} < ${GLIB_MIN_VER}（QEMU 9.2 要求 >= ${GLIB_MIN_VER}）"
            NEED_GLIB_BUILD=true
        fi
    else
        warn "glib 开发库未安装"
        NEED_GLIB_BUILD=true
    fi

    # 检查 /usr/local 是否已有源码安装的新版 glib
    if [ "$NEED_GLIB_BUILD" = true ]; then
        GLIB_PREFIX="/usr/local"
        for pc_dir in "${GLIB_PREFIX}/lib/pkgconfig" "${GLIB_PREFIX}/lib/x86_64-linux-gnu/pkgconfig"; do
            if [ -f "${pc_dir}/glib-2.0.pc" ]; then
                GLIB_LOCAL_VER=$(PKG_CONFIG_PATH="${pc_dir}" pkg-config --modversion glib-2.0 2>/dev/null || echo "")
                if [ -n "$GLIB_LOCAL_VER" ] && version_ge "$GLIB_LOCAL_VER" "$GLIB_MIN_VER"; then
                    info "已存在源码安装的 glib ${GLIB_LOCAL_VER}，跳过编译"
                    NEED_GLIB_BUILD=false
                    export PKG_CONFIG_PATH="${pc_dir}:${PKG_CONFIG_PATH:-}"
                    export LD_LIBRARY_PATH="$(dirname "${pc_dir}"):${LD_LIBRARY_PATH:-}"
                    ok "glib ${GLIB_LOCAL_VER} >= ${GLIB_MIN_VER}（来自 ${GLIB_PREFIX}）"
                    break
                fi
            fi
        done
    fi

    if [ "$NEED_GLIB_BUILD" = true ]; then
        echo ""
        info "================================================"
        info "glib 版本不满足 QEMU 9.2 要求，需要从源码编译"
        info "  当前版本: ${GLIB_CURRENT_VER:-未安装}"
        info "  需要版本: >= ${GLIB_MIN_VER}"
        info "  将安装:   glib ${GLIB_BUILD_VER} 到 /usr/local"
        info "  需要 sudo 执行: ninja install, ldconfig"
        info "================================================"

        if [ "$HAS_SUDO" != true ]; then
            fail "从源码安装 glib 需要 sudo 权限，但当前无法使用 sudo"
            fail "请以 root 身份运行，或手动安装 glib >= ${GLIB_MIN_VER}"
            fail "手动编译步骤:"
            fail "  wget https://download.gnome.org/sources/glib/2.66/glib-${GLIB_BUILD_VER}.tar.xz"
            fail "  tar xf glib-${GLIB_BUILD_VER}.tar.xz && cd glib-${GLIB_BUILD_VER}"
            fail "  meson setup _build --prefix=/usr/local && ninja -C _build"
            fail "  sudo ninja -C _build install && sudo ldconfig"
            exit 1
        fi

        info "安装 glib 编译依赖..."
        sudo apt-get install -y -qq libmount-dev libffi-dev zlib1g-dev 2>/dev/null || true

        GLIB_BUILD_DIR="${PROJECT_DIR}/third_party/glib-${GLIB_BUILD_VER}"
        GLIB_TARBALL="${PROJECT_DIR}/third_party/glib-${GLIB_BUILD_VER}.tar.xz"
        GLIB_URL="https://download.gnome.org/sources/glib/2.66/glib-${GLIB_BUILD_VER}.tar.xz"

        mkdir -p "${PROJECT_DIR}/third_party"

        if [ ! -d "$GLIB_BUILD_DIR" ]; then
            if [ ! -f "$GLIB_TARBALL" ]; then
                info "下载 glib ${GLIB_BUILD_VER} 源码..."
                if ! wget -q -O "$GLIB_TARBALL" "$GLIB_URL"; then
                    fail "下载 glib 失败，请手动下载到: ${GLIB_TARBALL}"
                    fail "下载地址: ${GLIB_URL}"
                    exit 1
                fi
                ok "glib 源码下载完成"
            fi
            info "解压 glib 源码..."
            tar xf "$GLIB_TARBALL" -C "${PROJECT_DIR}/third_party/"
        fi

        info "编译 glib ${GLIB_BUILD_VER}..."
        cd "$GLIB_BUILD_DIR"
        if [ ! -f "_build/build.ninja" ]; then
            # 清理损坏的旧构建目录（避免 meson 报 "Neither source directory nor build directory" 错误）
            if [ -d "_build" ]; then
                warn "清理旧 glib 构建目录 _build/..."
                rm -rf _build
            fi
            # 自动检测高版本 gcc（meson 需要可用的 C 编译器）
            GLIB_CC="${CC:-}"
            if [ -z "$GLIB_CC" ]; then
                for cc_candidate in gcc-12 gcc-11 gcc-9 gcc; do
                    if command -v "$cc_candidate" &>/dev/null; then
                        GLIB_CC="$cc_candidate"
                        break
                    fi
                done
            fi
            info "使用编译器: ${GLIB_CC:-cc}"
            info "提示: 如果 meson 报 'Compiler cc can not compile programs'，请设置 CC 环境变量:"
            info "  CC=/path/to/gcc-9 ./setup.sh"
            if [ -n "$GLIB_CC" ]; then
                CC="$GLIB_CC" meson setup _build --prefix=/usr/local
            else
                meson setup _build --prefix=/usr/local
            fi
        fi
        ninja -C _build

        info "安装 glib 到 /usr/local（需要 sudo）..."
        # sudo -E 保留用户 PATH/PYTHONPATH，避免 sudo 下找不到 meson 模块
        sudo -E env "PATH=$PATH" ninja -C _build install
        sudo ldconfig
        cd "$PROJECT_DIR"

        export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
        export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

        NEW_GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "unknown")
        if version_ge "$NEW_GLIB_VER" "$GLIB_MIN_VER"; then
            ok "glib ${NEW_GLIB_VER} 安装成功"
        else
            fail "glib 安装后版本检测异常: ${NEW_GLIB_VER}"
            fail "请检查 PKG_CONFIG_PATH 是否包含 /usr/local/lib/pkgconfig"
            exit 1
        fi
    fi
fi

# ---- 依赖检查汇总 ----
if [ ${#DEP_ERRORS[@]} -gt 0 ]; then
    echo ""
    fail "================================================"
    fail "以下依赖不满足，后续编译将失败:"
    for err in "${DEP_ERRORS[@]}"; do
        fail "  ✗ ${err}"
    done
    fail "================================================"
    fail "请按以上提示安装缺失依赖后重新运行 setup.sh"
    exit 1
fi

echo ""
ok "所有依赖检查通过"

# ============================================================
# [步骤] 编译 Bridge 库
# ============================================================
next_step "编译 Bridge 库"

mkdir -p "$BUILD_DIR"
COSIM_CC="${COSIM_CC:-$(command -v gcc-9 || command -v gcc)}"
# Release 优化但保留 assert（单元测试依赖 assert 做错误检查）
cmake -B "$BUILD_DIR" -S "$PROJECT_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$COSIM_CC" \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -g"
cmake --build "$BUILD_DIR" -j"$(nproc)"

if [ -f "${BRIDGE_LIB_DIR}/libcosim_bridge.so" ]; then
    ok "libcosim_bridge.so 编译成功: ${BRIDGE_LIB_DIR}/libcosim_bridge.so"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fail "libcosim_bridge.so 未生成"
    exit 1
fi

# ============================================================
# [步骤] 编译 QEMU（含 CoSim PCIe RC 设备）
# ============================================================
if [ "$NEED_QEMU" = true ]; then
    next_step "编译 QEMU（含 CoSim PCIe RC 设备）"

    mkdir -p "${PROJECT_DIR}/third_party"

    # ---- 获取 QEMU 源码 ----
    if [ -d "$QEMU_DIR" ]; then
        info "QEMU 源码已存在于 ${QEMU_DIR}，跳过下载"
    else
        case "${QEMU_SRC_OPT}" in
            download)
                QEMU_FETCHED=false
                if command -v git &>/dev/null; then
                    info "从 GitHub 下载 QEMU ${QEMU_VERSION}..."
                    if git clone https://github.com/qemu/qemu.git \
                            --branch "$QEMU_VERSION" --depth 1 "$QEMU_DIR" 2>/dev/null; then
                        ok "QEMU 源码下载完成"
                        QEMU_FETCHED=true
                    else
                        warn "git clone 失败，检查本地备份..."
                    fi
                else
                    info "git 不可用，检查本地 tarball..."
                fi
                if [ "$QEMU_FETCHED" = false ]; then
                    TARBALL="${PROJECT_DIR}/third_party/qemu-9.2.0.tar.xz"
                    if [ -f "$TARBALL" ]; then
                        info "从本地 tarball 解压 QEMU..."
                        cd "${PROJECT_DIR}/third_party"
                        tar xf "$TARBALL"
                        [ -d "qemu-9.2.0" ] && [ ! -d "qemu" ] && mv qemu-9.2.0 qemu
                        cd "$PROJECT_DIR"
                        ok "QEMU 源码解压完成"
                    else
                        fail "无法获取 QEMU 源码！"
                        fail "  解决方法:"
                        fail "    1. 重新运行，选择本地路径模式: --qemu-src path:<目录>"
                        fail "    2. 将 QEMU 源码放到 ${QEMU_DIR}"
                        fail "    3. 将 tarball 放到 ${TARBALL}"
                        exit 1
                    fi
                fi
                ;;
            path:*)
                QEMU_LOCAL_PATH="${QEMU_SRC_OPT#path:}"
                if [ -d "$QEMU_LOCAL_PATH" ] && [ -f "$QEMU_LOCAL_PATH/configure" ]; then
                    info "使用本地 QEMU 源码: ${QEMU_LOCAL_PATH}"
                    ln -sfn "$QEMU_LOCAL_PATH" "$QEMU_DIR"
                    ok "已链接: ${QEMU_LOCAL_PATH} -> ${QEMU_DIR}"
                else
                    fail "QEMU 源码路径无效: ${QEMU_LOCAL_PATH}"
                    fail "  路径不存在或未找到 configure 文件"
                    exit 1
                fi
                ;;
            skip)
                info "跳过 QEMU 编译（用户选择）"
                NEED_QEMU=false
                ;;
            *)
                fail "无效的 QEMU 源码选项: ${QEMU_SRC_OPT}"
                exit 1
                ;;
        esac
    fi

    if [ "$NEED_QEMU" = true ] && [ -d "$QEMU_DIR" ]; then
        # ---- 注入自定义设备代码 ----
        info "注入 cosim_pcie_rc 设备到 QEMU 源码树..."
        cp "${PROJECT_DIR}/qemu-plugin/cosim_pcie_rc.c" "${QEMU_DIR}/hw/net/"
        cp "${PROJECT_DIR}/qemu-plugin/cosim_pcie_rc.h" "${QEMU_DIR}/include/hw/net/"

        MESON_FILE="${QEMU_DIR}/hw/net/meson.build"
        if ! grep -q "cosim_pcie_rc" "$MESON_FILE"; then
            {
                echo ""
                echo "# CoSim PCIe RC device"
                echo "system_ss.add(files('cosim_pcie_rc.c'))"
            } >> "$MESON_FILE"
            ok "已修补 meson.build"
        else
            info "meson.build 已包含 cosim_pcie_rc，无需修改"
        fi

        # ---- 配置 + 编译 QEMU ----
        cd "$QEMU_DIR"

        QEMU_DEPS_OK=true
        for dep in meson ninja pkg-config; do
            if ! command -v "$dep" &>/dev/null; then
                fail "QEMU 编译需要 ${dep}，但未找到"
                QEMU_DEPS_OK=false
            fi
        done

        if [ "$QEMU_DEPS_OK" = false ]; then
            warn "QEMU 编译依赖不满足，跳过 QEMU 编译"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            cd "$PROJECT_DIR"
        else
            if [ ! -f "build/build.ninja" ]; then
                # 清理非 QEMU configure 创建的 build 目录（避免冲突）
                if [ -d "build" ] && [ ! -f "build/config-host.mak" ]; then
                    warn "build/ 目录已存在但非 QEMU configure 创建，清理..."
                    rm -rf build
                fi
                # 检测网络连通性，决定 subproject 和 fdt 策略
                HAS_NETWORK=false
                if timeout 5 git ls-remote https://gitlab.com/qemu-project/dtc.git HEAD &>/dev/null; then
                    HAS_NETWORK=true
                    ok "外网可达，保留 subproject .wrap 文件（meson 可自动下载依赖）"
                else
                    warn "外网不可达（内网环境），清理 subproject 防止下载超时"
                    if [ -d "subprojects" ]; then
                        # 删除空 subproject 目录
                        for _sp_dir in subprojects/*/; do
                            if [ -d "$_sp_dir" ] && [ ! -f "$_sp_dir/meson.build" ]; then
                                info "  删除空 subproject: $_sp_dir"
                                rm -rf "$_sp_dir"
                            fi
                        done
                        # 删除 .wrap 文件防止 meson 尝试网络下载
                        wrap_count=$(find subprojects -name "*.wrap" 2>/dev/null | wc -l)
                        if [ "$wrap_count" -gt 0 ]; then
                            info "  删除 ${wrap_count} 个 .wrap 文件"
                            find subprojects -name "*.wrap" -delete
                        fi
                    fi
                fi

                # configure 参数：内网禁用 fdt（避免下载 dtc），外网保留全部功能
                QEMU_EXTRA_OPTS=""
                if [ "$HAS_NETWORK" = false ]; then
                    QEMU_EXTRA_OPTS="--disable-fdt"
                fi

                info "配置 QEMU (--target-list=x86_64-softmmu)..."
                ./configure \
                    --target-list=x86_64-softmmu \
                    $QEMU_EXTRA_OPTS \
                    --extra-cflags="-I${PROJECT_DIR}/bridge/common -I${PROJECT_DIR}/bridge/qemu" \
                    --extra-ldflags="-L${BRIDGE_LIB_DIR} -lcosim_bridge -Wl,-rpath,${BRIDGE_LIB_DIR}"
            else
                info "QEMU 已配置，跳过 configure"
            fi

            info "编译 QEMU（可能需要几分钟）..."
            cd build && ninja -j"$(nproc)"
            cd "$PROJECT_DIR"
        fi

        QEMU_BIN="${QEMU_DIR}/build/qemu-system-x86_64"
        if [ -f "$QEMU_BIN" ]; then
            ok "QEMU 编译成功: ${QEMU_BIN}"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            warn "qemu-system-x86_64 未生成"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
fi

# ============================================================
# [步骤] 编译 VCS simv（vcs-tb + pcie_tl_vip）
# ============================================================
if [ "$NEED_VCS" = true ]; then
    next_step "编译 VCS simv（vcs-tb + pcie_tl_vip）"

    VCS_BIN=""

    if command -v vcs &>/dev/null; then
        VCS_BIN="$(command -v vcs)"
    elif [ -n "$VCS_HOME" ] && [ -x "${VCS_HOME}/bin/vcs" ]; then
        VCS_BIN="${VCS_HOME}/bin/vcs"
    else
        for pattern in /opt/synopsys/vcs/*/bin/vcs /eda/synopsys/vcs/*/bin/vcs /eda/*/vcs/*/bin/vcs; do
            for p in $pattern; do
                if [ -x "$p" ]; then
                    VCS_BIN="$p"
                    break 2
                fi
            done
        done
    fi

    if [ -z "$VCS_BIN" ]; then
        warn "未找到 VCS 编译器"
        warn "  VCS 未安装或不在 PATH 中"
        warn "  请设置 VCS_HOME 环境变量或将 VCS 加入 PATH"
        warn "  跳过 VCS 编译，其他组件继续..."
        SKIP_COUNT=$((SKIP_COUNT + 1))
    else
        info "使用 VCS: ${VCS_BIN}"

        if [ -z "${VCS_HOME:-}" ]; then
            VCS_HOME="$(cd "$(dirname "$VCS_BIN")/.." && pwd)"
            export VCS_HOME
            info "自动设置 VCS_HOME=${VCS_HOME}"
        fi
        export PATH="${VCS_HOME}/bin:$PATH"

        for envfile in "$HOME/set-env.sh" "$HOME/.set-env.sh"; do
            if [ -f "$envfile" ]; then
                info "加载 EDA 环境: ${envfile}"
                set +eu
                source "$envfile" 2>/dev/null
                set -eu
                break
            fi
        done

        # 使用 Makefile 的 vcs-vip 目标编译（VIP 模式，含 UVM + pcie_tl_vip）
        info "编译 VCS VIP 模式 (make vcs-vip)..."
        set +e
        make -C "$PROJECT_DIR" vcs-vip 2>&1
        VCS_RET=$?
        set -e

        if [ "$VCS_RET" -ne 0 ]; then
            fail "VCS 编译失败 (exit code: $VCS_RET)"
            fail "  请检查 VCS 许可证和环境设置"
            fail "  手动重试: make vcs-vip"
        fi

        VCS_VIP_BIN="${PROJECT_DIR}/vcs_sim/simv_vip"
        if [ -f "$VCS_VIP_BIN" ]; then
            ok "simv_vip 编译成功: ${VCS_VIP_BIN}"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fail "simv_vip 未生成"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
fi

# ============================================================
# [步骤] 编译 eth_tap_bridge
# ============================================================
if [ "$NEED_TAP_BRIDGE" = true ]; then
    next_step "编译 eth_tap_bridge"

    cd "${PROJECT_DIR}/tools"
    make clean 2>/dev/null || true
    make
    cd "$PROJECT_DIR"

    TAP_BIN="${PROJECT_DIR}/tools/eth_tap_bridge"
    if [ -f "$TAP_BIN" ]; then
        ok "eth_tap_bridge 编译成功: ${TAP_BIN}"
        PASS_COUNT=$((PASS_COUNT + 1))
        echo ""
        warn "eth_tap_bridge 需要 CAP_NET_ADMIN 才能创建 TAP 设备"
        info "  请在编译后运行（每次重新编译后都需要）:"
        info "    sudo setcap cap_net_admin+ep ${TAP_BIN}"
        # 自动尝试 setcap（有 sudo 权限时）
        if [ "$HAS_SUDO" = true ]; then
            if sudo setcap cap_net_admin+ep "$TAP_BIN" 2>/dev/null; then
                ok "setcap 已自动设置"
            else
                warn "setcap 自动设置失败，请手动执行上述命令"
            fi
        fi
    else
        fail "eth_tap_bridge 未生成"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ============================================================
# [步骤] 准备 Guest 环境
# ============================================================
if [ "$NEED_GUEST" = true ]; then
    next_step "准备 Guest 环境"

    mkdir -p "$IMAGES_DIR"

    # 检查是否已有镜像
    if [ -f "${IMAGES_DIR}/bzImage" ] && [ -f "${IMAGES_DIR}/rootfs.ext4" ]; then
        ok "Guest 镜像已存在:"
        ok "  Kernel: ${IMAGES_DIR}/bzImage"
        ok "  Rootfs: ${IMAGES_DIR}/rootfs.ext4"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo ""
        echo -e "${BOLD}选择 Guest 构建方式:${NC}"
        echo ""
        echo "  1) 快速构建 — buildroot 默认配置 (qemu_x86_64_defconfig)"
        echo "     完整 Linux + 常用工具，编译约 30-60 分钟"
        echo ""
        echo "  2) 精简构建 — 自定义配置，仅 virtio + 测试工具（推荐）"
        echo "     含 virtio_net, iperf3, netcat, arping，编译约 10-20 分钟"
        echo ""
        echo "  3) 跳过 — 手动准备镜像到 ${IMAGES_DIR}/"
        echo ""

        GUEST_BUILD_CHOICE=""
        if [ -z "$GUEST_BUILD_CHOICE" ]; then
            read -rp "请选择 [1/2/3]: " GUEST_BUILD_CHOICE
        fi

        case "$GUEST_BUILD_CHOICE" in
            1|2)
                # ---- 获取 buildroot 源码 ----
                BUILDROOT_VER="2024.02.1"
                BUILDROOT_DIR="${PROJECT_DIR}/third_party/buildroot-${BUILDROOT_VER}"
                BUILDROOT_TARBALL="${PROJECT_DIR}/third_party/buildroot-${BUILDROOT_VER}.tar.gz"
                BUILDROOT_URL="https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.gz"

                if [ -d "$BUILDROOT_DIR" ] && [ -f "$BUILDROOT_DIR/Makefile" ]; then
                    info "Buildroot 源码已存在: ${BUILDROOT_DIR}"
                else
                    mkdir -p "${PROJECT_DIR}/third_party"

                    if [ -f "$BUILDROOT_TARBALL" ]; then
                        info "使用本地 tarball: ${BUILDROOT_TARBALL}"
                    else
                        # 检测网络
                        HAS_NETWORK_BR=false
                        if timeout 5 wget -q --spider "$BUILDROOT_URL" 2>/dev/null; then
                            HAS_NETWORK_BR=true
                        fi

                        if [ "$HAS_NETWORK_BR" = true ]; then
                            info "下载 buildroot ${BUILDROOT_VER}..."
                            if ! wget -q --show-progress -O "$BUILDROOT_TARBALL" "$BUILDROOT_URL"; then
                                fail "下载失败"
                                fail "  请手动下载: ${BUILDROOT_URL}"
                                fail "  放置到: ${BUILDROOT_TARBALL}"
                                SKIP_COUNT=$((SKIP_COUNT + 1))
                                GUEST_BUILD_CHOICE="skip"
                            fi
                        else
                            fail "无法下载 buildroot（内网环境）"
                            fail "  请手动下载: ${BUILDROOT_URL}"
                            fail "  放置到: ${BUILDROOT_TARBALL}"
                            fail "  然后重新运行 setup.sh"
                            SKIP_COUNT=$((SKIP_COUNT + 1))
                            GUEST_BUILD_CHOICE="skip"
                        fi
                    fi

                    if [ -f "$BUILDROOT_TARBALL" ] && [ "$GUEST_BUILD_CHOICE" != "skip" ]; then
                        info "解压 buildroot..."
                        tar xf "$BUILDROOT_TARBALL" -C "${PROJECT_DIR}/third_party/"
                    fi
                fi

                # ---- 编译 buildroot ----
                if [ -d "$BUILDROOT_DIR" ] && [ "$GUEST_BUILD_CHOICE" != "skip" ]; then
                    cd "$BUILDROOT_DIR"

                    if [ "$GUEST_BUILD_CHOICE" = "1" ]; then
                        info "使用 buildroot 默认配置 (qemu_x86_64_defconfig)..."
                        make qemu_x86_64_defconfig
                    else
                        if [ -f "${PROJECT_DIR}/guest/buildroot_defconfig" ]; then
                            info "使用精简自定义配置..."
                            make BR2_DEFCONFIG="${PROJECT_DIR}/guest/buildroot_defconfig" defconfig
                        else
                            info "自定义 defconfig 不存在，使用默认配置..."
                            make qemu_x86_64_defconfig
                        fi
                    fi

                    info "编译 buildroot（可能需要 10-60 分钟）..."
                    if make -j"$(nproc)" 2>&1 | tail -5; then
                        # 拷贝产出到统一位置
                        if [ -f "output/images/bzImage" ]; then
                            cp output/images/bzImage "${IMAGES_DIR}/"
                            ok "Kernel 拷贝到: ${IMAGES_DIR}/bzImage"
                        fi
                        if [ -f "output/images/rootfs.ext4" ]; then
                            cp output/images/rootfs.ext4 "${IMAGES_DIR}/"
                            ok "Rootfs 拷贝到: ${IMAGES_DIR}/rootfs.ext4"
                        elif [ -f "output/images/rootfs.ext2" ]; then
                            cp output/images/rootfs.ext2 "${IMAGES_DIR}/rootfs.ext4"
                            ok "Rootfs 拷贝到: ${IMAGES_DIR}/rootfs.ext4"
                        fi
                        PASS_COUNT=$((PASS_COUNT + 1))
                    else
                        fail "Buildroot 编译失败"
                        fail "  手动重试: cd ${BUILDROOT_DIR} && make -j\$(nproc)"
                        FAIL_COUNT=$((FAIL_COUNT + 1))
                    fi

                    cd "$PROJECT_DIR"
                fi
                ;;
            3|*)
                info "跳过 Guest 构建"
                info "  请手动准备以下文件:"
                info "    ${IMAGES_DIR}/bzImage      — Guest 内核"
                info "    ${IMAGES_DIR}/rootfs.ext4   — Guest 磁盘镜像"
                info ""
                info "  方式 A: 从其他机器拷贝 buildroot 产出"
                info "    scp <源机>:~/workspace/buildroot/output/images/bzImage ${IMAGES_DIR}/"
                info "    scp <源机>:~/workspace/buildroot/output/images/rootfs.ext4 ${IMAGES_DIR}/"
                info ""
                info "  方式 B: 本地构建 buildroot"
                info "    wget https://buildroot.org/downloads/buildroot-2024.02.1.tar.gz"
                info "    tar xf buildroot-2024.02.1.tar.gz && cd buildroot-2024.02.1"
                info "    make qemu_x86_64_defconfig && make -j\$(nproc)"
                info "    cp output/images/bzImage output/images/rootfs.ext4 ${IMAGES_DIR}/"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                ;;
        esac
    fi
fi

# ============================================================
# [步骤] 运行单元测试
# ============================================================
if [ "$SETUP_MODE" = "local" ]; then
    next_step "运行单元测试"

    UNIT_TEST_DIR="${BUILD_DIR}/tests/unit"
    if [ -d "$UNIT_TEST_DIR" ]; then
        info "执行单元测试..."
        set +e
        cd "$BUILD_DIR"
        # 只运行 unit 测试（test_ring_buffer ~ test_link_model），排除集成测试
        TEST_OUTPUT=$(ctest --test-dir tests/unit -R "^test_(ring_buffer|shm_layout|dma_manager|trace_log|eth_shm|link_model|transport_tcp)$" --output-on-failure 2>&1)
        TEST_EXIT=$?
        set -e
        cd "$PROJECT_DIR"

        echo "$TEST_OUTPUT"

        TESTS_PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ tests passed' | grep -oE '[0-9]+' || echo "0")
        TESTS_FAILED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ tests failed' | grep -oE '[0-9]+' || echo "0")

        if [ "$TEST_EXIT" -eq 0 ]; then
            ok "单元测试全部通过 (${TESTS_PASSED} passed)"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            warn "部分单元测试失败 (passed: ${TESTS_PASSED}, failed: ${TESTS_FAILED})"
        fi
    else
        warn "单元测试目录不存在，跳过 (${UNIT_TEST_DIR})"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
else
    info "跳过单元测试（${SETUP_MODE} 模式）"
    info "  如需运行: make test-unit"
fi

# ============================================================
# [步骤] 安装摘要
# ============================================================
next_step "安装摘要"

echo ""
echo -e "${BOLD}-------- 安装配置 --------${NC}"
echo -e "  部署模式:   ${SETUP_MODE}"
if [ "$SETUP_MODE" != "vcs-only" ]; then
    echo -e "  Guest 环境: ${GUEST_TYPE}"
fi
echo ""

echo -e "${BOLD}-------- 构建产物 --------${NC}"

check_artifact() {
    local name="$1"
    local path="$2"
    if [ -f "$path" ]; then
        echo -e "  ${GREEN}[OK]${NC}  ${name}"
        echo "        ${path}"
    else
        echo -e "  ${RED}[--]${NC}  ${name} (未生成)"
    fi
}

check_artifact "libcosim_bridge.so" "${BRIDGE_LIB_DIR}/libcosim_bridge.so"

if [ "$NEED_QEMU" = true ]; then
    check_artifact "qemu-system-x86_64" "${QEMU_DIR}/build/qemu-system-x86_64"
fi
if [ "$NEED_VCS" = true ]; then
    check_artifact "simv_vip (VCS)" "${PROJECT_DIR}/vcs_sim/simv_vip"
fi
if [ "$NEED_TAP_BRIDGE" = true ]; then
    check_artifact "eth_tap_bridge" "${PROJECT_DIR}/tools/eth_tap_bridge"
fi
if [ "$NEED_GUEST" = true ]; then
    if [ "$GUEST_TYPE" = "minimal" ]; then
        for img in "${IMAGES_DIR}"/*.cpio.gz; do
            [ -f "$img" ] && check_artifact "initramfs" "$img"
        done
    elif [ "$GUEST_TYPE" = "full" ]; then
        check_artifact "cosim-guest.qcow2" "${IMAGES_DIR}/cosim-guest.qcow2"
    fi
fi

echo ""
echo -e "${BOLD}-------- 使用方法 --------${NC}"
case "$SETUP_MODE" in
    local)
        echo "  运行仿真（自动编排 QEMU + VCS）:"
        echo "    ./cosim.sh test phase4     # Phase 4: 双向 Ping 测试"
        echo "    ./cosim.sh test phase5     # Phase 5: iperf 吞吐测试"
        echo "    ./cosim.sh test tap        # TAP 桥接测试"
        echo ""
        echo "  手动启动单个组件:"
        echo "    ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock"
        echo "    ./cosim.sh start vcs  --shm /cosim0 --sock /tmp/cosim0.sock --role A"
        echo ""
        echo "  手动启动 + 串口交互（可在 Guest 中执行 ping/iperf 等测试）:"
        echo "    ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock \\"
        echo "        --serial-sock /tmp/qemu-serial.sock --drive guest/images/rootfs.ext4"
        echo "    # 然后用 python/socat 连接串口:"
        echo "    python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('/tmp/qemu-serial.sock'); ...\""
        ;;
    qemu-only)
        echo "  启动 QEMU 侧（TCP server，监听等待 VCS 连接）:"
        if [ "$GUEST_TYPE" = "minimal" ]; then
            echo "    ./cosim.sh start qemu --transport tcp --port-base 9100"
        else
            echo "    ./cosim.sh start qemu --transport tcp --port-base 9100 \\"
            echo "        --drive guest/images/rootfs.ext4"
        fi
        echo ""
        echo "  提示:"
        echo "    - QEMU 启动后阻塞等待 VCS 连接（端口 9100-9102），终端无输出是正常的"
        echo "    - 确认防火墙已放行 TCP 9100-9102"
        echo "    - 本机 TCP 测试: VCS 用 --remote-host 127.0.0.1"
        echo ""
        echo "  远程 VCS 机器需运行:"
        echo "    ./setup.sh --mode vcs-only"
        echo "    ./cosim.sh start vcs --transport tcp --remote-host <本机IP> --port-base 9100"
        ;;
    vcs-only)
        echo "  步骤 1 — 启动 VCS 仿真（TCP client，连接远程 QEMU）:"
        echo "    ./cosim.sh start vcs --transport tcp --remote-host <QEMU机器IP> --port-base 9100"
        echo ""
        echo "  步骤 2 — 启动 TAP 桥接（VCS 侧，将 ETH SHM 桥接到主机网络）:"
        echo "    ./cosim.sh start tap --eth-shm /cosim_eth0"
        echo ""
        echo "  远程 QEMU 机器需先启动:"
        echo "    ./setup.sh --mode qemu-only --guest minimal"
        echo "    ./cosim.sh start qemu --transport tcp --port-base 9100"
        echo ""
        echo "  提示:"
        echo "    - 启动顺序: 先 QEMU（listen）→ 再 VCS（connect）→ 再 TAP bridge"
        echo "    - VCS 侧 connect 会自动重试 15 秒，请确保 QEMU 已在监听"
        echo "    - eth_tap_bridge 需要 CAP_NET_ADMIN: sudo setcap cap_net_admin+ep tools/eth_tap_bridge"
        ;;
esac
echo ""
echo "  功能测试（启动后执行）:"
echo "    ./cosim.sh test-guide   # 交互式测试向导（ping/iperf/arping/压力测试）"
echo ""
echo "  重新编译:"
echo "    make bridge             # 仅重编译 bridge 库"
echo "    make test-unit          # 运行单元测试"
echo "    ./setup.sh              # 重新运行安装向导"
echo ""

# 警告汇总
if [ ${#WARN_MSGS[@]} -gt 0 ]; then
    echo -e "${BOLD}-------- 警告汇总 --------${NC}"
    for i in "${!WARN_MSGS[@]}"; do
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${WARN_MSGS[$i]}"
    done
    echo ""
fi

# 最终状态
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}安装完成，但有 ${FAIL_COUNT} 个失败项${NC}"
    echo "  请查看以上输出，修复失败项后重新运行 setup.sh"
    exit 1
elif [ "$SKIP_COUNT" -gt 0 ]; then
    echo -e "${GREEN}安装完成${NC}（${SKIP_COUNT} 个可选组件已跳过）"
else
    echo -e "${GREEN}安装完成，所有组件编译成功！${NC}"
fi
