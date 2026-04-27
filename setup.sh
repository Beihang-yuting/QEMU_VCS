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
  alpine      Alpine Linux — 轻量快速，apk 包管理（推荐）
  debian      Debian 精简版 — 完整工具链，apt 包管理
  skip        跳过 Guest 构建，手动准备镜像

QEMU 源码 (--qemu-src, 仅 local/qemu-only 模式):
  download    从 GitHub 下载 QEMU v9.2.0
  path:<dir>  使用本地已有源码，例: --qemu-src path:/home/user/qemu
  skip        跳过 QEMU 编译（仅编译 Bridge）

其他选项:
  --help      显示此帮助信息

示例:
  ./setup.sh                                          # 交互式菜单
  ./setup.sh --mode local --guest alpine              # 本地全栈 + Alpine（推荐）
  ./setup.sh --mode local --guest debian              # 本地全栈 + Debian 完整工具链
  ./setup.sh --mode qemu-only --guest alpine          # QEMU 侧远程部署
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
        echo "  1) Alpine Linux  — 轻量快速，apk 包管理（推荐）"
        echo "     镜像 ~50MB，启动 ~3 秒"
        echo ""
        echo "  2) Debian 精简版 — 完整工具链，apt 包管理"
        echo "     镜像 ~500MB，启动 ~15 秒"
        echo ""
        echo "  3) 跳过 — 手动准备 rootfs 到 guest/images/"

        while true; do
            read -rp "请选择 [1/2/3]: " choice
            case "$choice" in
                1) GUEST_TYPE="alpine"; break ;;
                2) GUEST_TYPE="debian"; break ;;
                3) GUEST_TYPE="skip"; break ;;
                *) echo "  无效选择，请输入 1、2 或 3" ;;
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
    GUEST_TYPE="${GUEST_TYPE:-alpine}"
    QEMU_SRC_OPT="${QEMU_SRC_OPT:-download}"

    case "$GUEST_TYPE" in
        alpine|debian|skip) ;;
        *)
            fail "无效的 Guest 类型: ${GUEST_TYPE}"
            fail "可选: alpine, debian, skip"
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
# IMAGES_DIR 根据 GUEST_TYPE 指向子目录
if [ "${GUEST_TYPE:-alpine}" = "debian" ]; then
    IMAGES_DIR="${PROJECT_DIR}/guest/images/debian"
else
    IMAGES_DIR="${PROJECT_DIR}/guest/images/alpine"
fi

info "项目目录: ${PROJECT_DIR}"
info "部署模式: ${SETUP_MODE}"

# ---- 全局网络检测 ----
HAS_INTERNET=false
if timeout 5 bash -c 'echo >/dev/tcp/github.com/443' 2>/dev/null || \
   timeout 5 curl -s --head https://github.com >/dev/null 2>&1; then
    HAS_INTERNET=true
fi
if [ "$HAS_INTERNET" = true ]; then
    ok "外网可达"
else
    warn "外网不可达（内网环境），涉及下载的步骤将给出离线准备命令"
fi

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
            cpio gzip wget bc flex bison
            libelf-dev libssl-dev
        )
        if [ "$NEED_QEMU" = true ]; then
            PKGS+=(libglib2.0-dev libpixman-1-dev libslirp-dev zlib1g-dev)
        fi
        if [ "$NEED_GUEST" = true ]; then
            PKGS+=(rsync unzip file)
        fi
        local MISSING=()
        for pkg in "${PKGS[@]}"; do
            if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
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
            cpio gzip wget bc flex bison
            elfutils-libelf-devel openssl-devel
        )
        if [ "$NEED_QEMU" = true ]; then
            PKGS+=(glib2-devel pixman-devel libslirp-devel zlib-devel)
        fi
        if [ "$NEED_GUEST" = true ]; then
            PKGS+=(rsync unzip file)
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

# ---- 无 sudo 时：检查关键依赖是否已预装，缺失则阻止继续 ----
check_deps_no_sudo() {
    local MISSING_CMDS=()
    local MISSING_LIBS=()

    # 关键命令检查
    for cmd in gcc g++ make cmake python3 bc flex bison; do
        command -v "$cmd" &>/dev/null || MISSING_CMDS+=("$cmd")
    done

    # 关键头文件/库检查（通过编译测试）
    local tmpfile
    tmpfile=$(mktemp /tmp/depcheck_XXXXXX.c)

    # libelf (gelf.h) — buildroot/kernel 编译必需
    echo '#include <gelf.h>' > "$tmpfile"
    echo 'int main(){return 0;}' >> "$tmpfile"
    if ! gcc -c "$tmpfile" -o /dev/null 2>/dev/null; then
        MISSING_LIBS+=("libelf-dev")
    fi

    # libssl (openssl/evp.h) — kernel 签名模块需要
    echo '#include <openssl/evp.h>' > "$tmpfile"
    echo 'int main(){return 0;}' >> "$tmpfile"
    if ! gcc -c "$tmpfile" -o /dev/null 2>/dev/null; then
        MISSING_LIBS+=("libssl-dev")
    fi

    if [ "$NEED_QEMU" = true ]; then
        if ! pkg-config --exists pixman-1 2>/dev/null; then
            MISSING_LIBS+=("libpixman-1-dev")
        fi
        if ! pkg-config --exists glib-2.0 2>/dev/null; then
            MISSING_LIBS+=("libglib2.0-dev")
        fi
    fi

    rm -f "$tmpfile" 2>/dev/null

    # 汇总：有缺失则阻止继续
    if [ ${#MISSING_CMDS[@]} -gt 0 ] || [ ${#MISSING_LIBS[@]} -gt 0 ]; then
        echo ""
        fail "=========================================="
        fail "  检测到缺失依赖，无法继续安装"
        fail "=========================================="
        [ ${#MISSING_CMDS[@]} -gt 0 ] && fail "  缺失命令:   ${MISSING_CMDS[*]}"
        [ ${#MISSING_LIBS[@]} -gt 0 ] && fail "  缺失开发库: ${MISSING_LIBS[*]}"
        echo ""
        info "请让管理员先安装依赖，然后重新运行 setup.sh:"
        if [ -f /etc/debian_version ]; then
            local ALL=("${MISSING_CMDS[@]}" "${MISSING_LIBS[@]}")
            info "  sudo apt-get install -y ${ALL[*]}"
        elif [ -f /etc/redhat-release ]; then
            info "  sudo yum install -y ${MISSING_CMDS[*]} elfutils-libelf-devel openssl-devel ..."
        fi
        echo ""
        exit 1
    else
        ok "依赖检查通过（无 sudo 模式）"
    fi
}

if [ "$HAS_SUDO" = true ]; then
    install_deps
else
    info "无 sudo 权限，检查依赖是否已预装..."
    check_deps_no_sudo
fi

# ============================================================
# 依赖版本检查
# ============================================================
echo ""
info "========================================"
info "检查依赖版本"
info "========================================"

DEP_ERRORS=()

# 确保 ~/.local/bin 在 PATH 中（pip3 install --user 安装位置）
if [ -d "$HOME/.local/bin" ] && ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    export PATH="$HOME/.local/bin:$PATH"
    info "已将 ~/.local/bin 加入 PATH（pip --user 安装路径）"
fi

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
                if [ "$HAS_INTERNET" = true ]; then
                    info "下载 glib ${GLIB_BUILD_VER} 源码..."
                    if ! wget -q -O "$GLIB_TARBALL" "$GLIB_URL"; then
                        fail "下载 glib 失败，请手动下载到: ${GLIB_TARBALL}"
                        fail "下载地址: ${GLIB_URL}"
                        exit 1
                    fi
                    ok "glib 源码下载完成"
                else
                    fail "内网环境无法下载 glib 源码"
                    echo ""
                    fail "  请在有网络的机器上执行以下命令，然后将文件拷贝到本机："
                    fail "  ────────────────────────────────────────"
                    fail "  wget ${GLIB_URL}"
                    fail "  scp glib-${GLIB_BUILD_VER}.tar.xz <用户>@<本机IP>:${GLIB_TARBALL}"
                    fail "  ────────────────────────────────────────"
                    fail "  完成后重新运行 ./setup.sh"
                    exit 1
                fi
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
                TARBALL="${PROJECT_DIR}/third_party/qemu-9.2.0.tar.xz"

                # 优先检查本地 tarball（支持离线）
                if [ -f "$TARBALL" ]; then
                    info "从本地 tarball 解压 QEMU..."
                    cd "${PROJECT_DIR}/third_party"
                    tar xf "$TARBALL"
                    [ -d "qemu-9.2.0" ] && [ ! -d "qemu" ] && mv qemu-9.2.0 qemu
                    cd "$PROJECT_DIR"
                    ok "QEMU 源码解压完成"
                    QEMU_FETCHED=true
                elif [ "$HAS_INTERNET" = true ] && command -v git &>/dev/null; then
                    info "从 GitHub 下载 QEMU ${QEMU_VERSION}..."
                    if git clone https://github.com/qemu/qemu.git \
                            --branch "$QEMU_VERSION" --depth 1 "$QEMU_DIR" 2>/dev/null; then
                        ok "QEMU 源码下载完成"
                        QEMU_FETCHED=true
                    else
                        warn "git clone 失败"
                    fi
                fi

                if [ "$QEMU_FETCHED" = false ]; then
                    fail "无法获取 QEMU 源码！"
                    echo ""
                    fail "  请在有网络的机器上执行以下命令，然后将文件拷贝到本机："
                    fail "  ────────────────────────────────────────"
                    fail "  wget https://github.com/qemu/qemu/archive/refs/tags/${QEMU_VERSION}.tar.gz -O qemu-9.2.0.tar.xz"
                    fail "  scp qemu-9.2.0.tar.xz <用户>@<本机IP>:${TARBALL}"
                    fail "  ────────────────────────────────────────"
                    fail "  或直接将 QEMU 源码目录拷贝到: ${QEMU_DIR}"
                    fail "  完成后重新运行 ./setup.sh"
                    exit 1
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

        # 自动探测可用的 C 编译器（优先高版本 gcc）
        QEMU_CC="${CC:-}"
        if [ -z "$QEMU_CC" ]; then
            for cc_candidate in gcc-12 gcc-11 gcc-10 gcc-9 gcc cc; do
                if command -v "$cc_candidate" &>/dev/null; then
                    QEMU_CC="$cc_candidate"
                    break
                fi
            done
        fi

        # 检查编译器能否编译 64 位程序
        if [ -z "$QEMU_CC" ] || ! echo 'int main(){return 0;}' | $QEMU_CC -m64 -x c - -o /dev/null 2>/dev/null; then
            fail "编译器 '${QEMU_CC:-cc} -m64' 无法编译程序"
            fail "请安装开发工具链:"
            fail "  CentOS/RHEL: sudo yum groupinstall 'Development Tools' && sudo yum install glibc-devel glib2-devel"
            fail "  Ubuntu/Debian: sudo apt install build-essential"
            fail "  或指定编译器: CC=/path/to/gcc-9 ./setup.sh"
            QEMU_DEPS_OK=false
        else
            info "QEMU 使用编译器: $QEMU_CC"
            export CC="$QEMU_CC"
        fi

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
                # 复用全局网络检测结果，决定 subproject 和 fdt 策略
                if [ "$HAS_INTERNET" = true ]; then
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
                if [ "$HAS_INTERNET" = false ]; then
                    QEMU_EXTRA_OPTS="--disable-fdt"
                fi

                info "配置 QEMU (--target-list=x86_64-softmmu, CC=$QEMU_CC)..."
                ./configure \
                    --cc="$QEMU_CC" \
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
# [步骤] VCS 编译提示（不在 setup 中编译，由用户单独执行 make vcs-vip）
# ============================================================
if [ "$NEED_VCS" = true ]; then
    next_step "VCS 编译说明"
    info "VCS 编译不在 setup 中执行（需要 Synopsys VCS 工具链）"
    info "请在有 VCS 环境的机器上手动编译:"
    info "  source ~/set-env.sh    # 加载 VCS 环境变量"
    info "  make vcs-vip           # 编译 VIP 模式"
    info "  产出: vcs_sim/simv_vip"
    SKIP_COUNT=$((SKIP_COUNT + 1))
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

    if [ -f "${IMAGES_DIR}/bzImage" ] && [ -f "${IMAGES_DIR}/rootfs.ext4" ]; then
        ok "Guest 镜像已存在:"
        ok "  Kernel: ${IMAGES_DIR}/bzImage"
        ok "  Rootfs: ${IMAGES_DIR}/rootfs.ext4"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$GUEST_TYPE" = "skip" ]; then
        info "跳过 Guest 构建"
        info "  请手动准备:"
        info "    ${IMAGES_DIR}/bzImage      -- Guest 内核"
        info "    ${IMAGES_DIR}/rootfs.ext4   -- Guest 磁盘镜像"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    else
        if ! sudo -n true 2>/dev/null; then
            warn "构建 rootfs 需要 sudo 权限（mount/chroot）"
            echo ""
            fail "当前用户无免密 sudo 权限，无法自动构建 Guest 镜像"
            fail "请以 root 用户手动执行以下命令，然后重新运行 setup.sh："
            echo ""
            if [ "$GUEST_TYPE" = "alpine" ]; then
                fail "  sudo ${PROJECT_DIR}/scripts/build_rootfs_alpine.sh ${IMAGES_DIR}"
            elif [ "$GUEST_TYPE" = "debian" ]; then
                fail "  sudo ${PROJECT_DIR}/scripts/build_rootfs_debian.sh ${IMAGES_DIR}"
            fi
            echo ""
            fail "完成后重新运行 ./setup.sh 即可跳过此步骤"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ "$HAS_INTERNET" = false ]; then
            warn "内网环境无法自动构建 Guest 镜像（需要下载内核和软件包）"
            echo ""
            fail "  请在有网络的机器上构建 Guest 镜像，然后拷贝到本机："
            fail "  ────────────────────────────────────────"
            if [ "$GUEST_TYPE" = "alpine" ]; then
                fail "  # 在有网络的机器上:"
                fail "  sudo ./scripts/build_rootfs_alpine.sh"
                fail "  # 将产物拷贝到本机:"
                fail "  scp guest/images/alpine/{bzImage,initramfs.gz,rootfs.ext4} <用户>@<本机IP>:${IMAGES_DIR}/"
            elif [ "$GUEST_TYPE" = "debian" ]; then
                fail "  # 在有网络的机器上:"
                fail "  sudo ./scripts/build_rootfs_debian.sh"
                fail "  # 将产物拷贝到本机:"
                fail "  scp guest/images/debian/{bzImage,initramfs.gz,rootfs.ext4} <用户>@<本机IP>:${IMAGES_DIR}/"
            fi
            fail "  ────────────────────────────────────────"
            fail "  完成后重新运行 ./setup.sh 即可跳过此步骤"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            info "编译自定义测试工具..."
            "${PROJECT_DIR}/scripts/build_guest_tools.sh" || warn "部分工具编译失败"

            if [ "$GUEST_TYPE" = "alpine" ]; then
                header "构建 Alpine rootfs"
                sudo "${PROJECT_DIR}/scripts/build_rootfs_alpine.sh" "$IMAGES_DIR"
            elif [ "$GUEST_TYPE" = "debian" ]; then
                header "构建 Debian rootfs"
                sudo "${PROJECT_DIR}/scripts/build_rootfs_debian.sh" "$IMAGES_DIR"
            fi
        fi

        if [ -f "${IMAGES_DIR}/rootfs.ext4" ]; then
            ok "Rootfs 构建完成: ${IMAGES_DIR}/rootfs.ext4"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fail "Rootfs 构建失败"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        if [ ! -f "${IMAGES_DIR}/bzImage" ]; then
            warn "bzImage 不存在，请手动准备: ${IMAGES_DIR}/bzImage"
        fi
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
    if [ "$GUEST_TYPE" != "skip" ]; then
        check_artifact "rootfs.ext4" "${IMAGES_DIR}/rootfs.ext4"
    fi
fi

echo ""
echo -e "${BOLD}-------- 使用方法 --------${NC}"
case "$SETUP_MODE" in
    local)
        echo "  单实例手动启动（2 个终端，先 QEMU 再 VCS）:"
        echo "    终端1: make run-qemu"
        echo "    终端2: make run-vcs"
        echo ""
        echo "  TCP 跨机模式:"
        echo "    终端1: make run-qemu TRANSPORT=tcp"
        echo "    终端2: make run-vcs  TRANSPORT=tcp REMOTE_HOST=127.0.0.1"
        echo ""
        echo "  双实例对打:"
        echo "    make run-dual                     # SHM 模式"
        echo "    make run-dual TRANSPORT=tcp        # TCP 模式"
        echo ""
        echo "  TAP 桥接（Guest↔主机网络）:"
        echo "    make tap-check                    # 检查权限"
        echo "    make run-tap                      # 启动 TAP bridge"
        ;;
    qemu-only)
        echo "  启动 QEMU（TCP server，等待 VCS 连接）:"
        echo "    make run-qemu TRANSPORT=tcp"
        echo ""
        echo "  提示:"
        echo "    - QEMU 启动后阻塞等待 VCS 连接"
        echo "    - 确认防火墙放行 TCP 9100-9102"
        echo ""
        echo "  远程 VCS 机器需执行:"
        echo "    make vcs-vip                      # 编译 VCS"
        echo "    make run-vcs TRANSPORT=tcp REMOTE_HOST=<本机IP>"
        ;;
    vcs-only)
        echo "  步骤 1 — 编译 VCS:"
        echo "    source ~/set-env.sh               # 加载 VCS 环境"
        echo "    make vcs-vip"
        echo ""
        echo "  步骤 2 — 运行 VCS（连接远程 QEMU）:"
        echo "    make run-vcs TRANSPORT=tcp REMOTE_HOST=<QEMU机器IP>"
        echo ""
        echo "  远程 QEMU 机器需先启动:"
        echo "    make run-qemu TRANSPORT=tcp"
        ;;
esac
echo ""
echo -e "${BOLD}-------- Guest 登录后操作 --------${NC}"
echo "  登录: root / 123"
echo ""
echo "  配置网络:"
echo "    cosim-start                        # 一键配网（读取 cmdline IP）"
echo "    cosim-start 10.0.0.2               # 指定 IP"
echo ""
echo "  测试命令:"
echo "    ping <对端IP>                      # 连通性测试"
echo "    iperf3 -s / iperf3 -c <对端IP>     # 吞吐量测试"
echo "    lspci -vv                           # PCI 设备列表"
echo "    cfgspace_test                       # Config Space 验证"
echo "    dma_test <BAR_ADDR>                 # DMA 读写测试"
echo ""
echo "  退出仿真:"
echo "    cosim-stop                          # 正常退出（通知 VCS 停止）"
echo "    Ctrl+A X                            # 强制退出 QEMU"
echo ""
echo "  调试模式（显示详细日志）:"
echo "    make run-qemu VERBOSE=1"
echo ""
echo -e "${BOLD}-------- 其他命令 --------${NC}"
echo "  make help               # 完整命令列表"
echo "  make info               # 环境检查"
echo "  make bridge             # 重新编译 Bridge 库"
echo "  make vcs-vip            # 重新编译 VCS"
echo "  make test               # 单元+集成测试"
echo "  详细文档: docs/SETUP-GUIDE.md"
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
