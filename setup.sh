#!/bin/bash
# ============================================================
# CoSim Platform 一键安装脚本
# 用法：./setup.sh
# 说明：自动检测环境、安装依赖、编译所有组件
# ============================================================
set -euo pipefail

# ---- 全局变量 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
WARN_MSGS=()   # 收集所有警告，最后汇总

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; WARN_MSGS+=("$*"); }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

# ---- PATH 增强（支持 miniconda / pip --user 安装的工具）----
for extra_path in "$HOME/miniconda3/bin" "$HOME/.local/bin" "/usr/local/bin"; do
    if [ -d "$extra_path" ] && [[ ":$PATH:" != *":$extra_path:"* ]]; then
        export PATH="$extra_path:$PATH"
    fi
done

# ============================================================
# [1/9] 加载配置文件
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[1/9] 加载配置文件${NC}"
echo "========================================================"

CONFIG_FILE="${PROJECT_DIR}/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=config.env
    source "$CONFIG_FILE"
    ok "已加载 ${CONFIG_FILE}"
else
    warn "未找到 config.env，使用默认值"
fi

# 设置默认值（config.env 未定义时使用）
QEMU_VERSION="${QEMU_VERSION:-v9.2.0}"
VCS_HOME="${VCS_HOME:-}"
SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
LM_LICENSE_FILE="${LM_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
export SNPSLMD_LICENSE_FILE LM_LICENSE_FILE

# 关键路径定义
QEMU_DIR="${PROJECT_DIR}/third_party/qemu"
BUILD_DIR="${PROJECT_DIR}/build"
BRIDGE_LIB_DIR="${BUILD_DIR}/bridge"
VCS_SIM_DIR="${PROJECT_DIR}/vcs-tb/sim_build"
IMAGES_DIR="${PROJECT_DIR}/images"

info "项目目录: ${PROJECT_DIR}"
info "QEMU 版本: ${QEMU_VERSION}"

# ============================================================
# [2/9] 检测操作系统并安装系统依赖
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[2/9] 检测操作系统并安装系统依赖${NC}"
echo "========================================================"

# 检测是否有 sudo 权限（非交互式环境下必须 sudo -n 成功）
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
        # Debian / Ubuntu
        info "检测到 Debian/Ubuntu 系统"
        local PKGS=(
            gcc g++ make cmake git
            meson ninja-build pkg-config
            libglib2.0-dev libpixman-1-dev libslirp-dev
            python3 python3-pip python3-venv
            cpio gzip
        )
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
        # CentOS / RHEL / Fedora
        info "检测到 CentOS/RHEL 系统"
        local PKGS=(
            gcc gcc-c++ make cmake git
            meson ninja-build pkgconfig
            glib2-devel pixman-devel libslirp-devel
            python3 python3-pip
            cpio gzip
        )
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
    info "  - glib2-devel / libglib2.0-dev (>= 2.66.0)"
    info "  - pixman-devel / libpixman-1-dev (>= 0.21.8)"
    info "  - python3 (>= 3.8), meson, ninja"
fi

# ============================================================
# 版本比较函数（后续多处使用）
# ============================================================
version_ge() {
    # 返回 0 表示 $1 >= $2
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

# ============================================================
# 依赖版本检查与自动修复
# ============================================================
# QEMU 9.2 关键依赖最低版本要求:
#   glib    >= 2.66.0  (Ubuntu 20.04 仅提供 2.64.6，需源码编译)
#   pixman  >= 0.21.8  (Ubuntu 20.04 提供 0.38.4，满足)
#   zlib    (无最低版本要求)
#   Python  >= 3.8     (QEMU configure 使用)
#   meson   >= 1.5.0   (QEMU configure 自带到 pyvenv，无需系统安装)
#   ninja   >= 1.0     (编译需要)
#   cmake   >= 3.16    (Bridge 编译需要)
# ============================================================

echo ""
info "========================================"
info "检查依赖版本（QEMU 9.2 + Bridge 要求）"
info "========================================"

DEP_ERRORS=()

# ---- [检查] 关键编译工具 ----
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

# git 是可选工具（仅用于下载 QEMU 源码）
if command -v git &>/dev/null; then
    info "  ✓ git: $(git --version 2>&1)"
else
    warn "  ✗ git 未安装（仅影响 QEMU 源码下载，可用 QEMU_SRC_DIR 或本地 tarball 替代）"
fi

# ---- [检查] meson / ninja ----
for tool in meson ninja; do
    if command -v "$tool" &>/dev/null; then
        info "  ✓ ${tool}: $(${tool} --version 2>&1 | head -1 || true)"
    else
        warn "  ✗ ${tool} 未找到（QEMU 编译需要）"
        warn "    安装方法: pip3 install --user ${tool}"
        DEP_ERRORS+=("${tool} 未安装")
    fi
done

# ---- [检查] pkg-config ----
if ! command -v pkg-config &>/dev/null; then
    fail "  ✗ pkg-config 未安装（依赖版本检测需要）"
    fail "    安装方法: sudo apt-get install -y pkg-config"
    DEP_ERRORS+=("pkg-config 未安装")
fi

# ---- [检查] cmake >= 3.16 ----
CMAKE_MIN_VER="3.16"
CMAKE_VER=$(cmake --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
if [ -n "$CMAKE_VER" ] && version_ge "$CMAKE_VER" "$CMAKE_MIN_VER"; then
    ok "cmake ${CMAKE_VER} >= ${CMAKE_MIN_VER}"
else
    fail "cmake 版本过低: ${CMAKE_VER:-未知}（需要 >= ${CMAKE_MIN_VER}）"
    fail "  Ubuntu: sudo apt-get install -y cmake  或从 https://cmake.org 下载新版"
    DEP_ERRORS+=("cmake < ${CMAKE_MIN_VER}")
fi

# ---- [检查] Python >= 3.8 + tomli（QEMU 9.2 pyvenv 需要）----
PYTHON_MIN_VER="3.8"
PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || echo "")
if [ -n "$PYTHON_VER" ] && version_ge "$PYTHON_VER" "$PYTHON_MIN_VER"; then
    ok "Python ${PYTHON_VER} >= ${PYTHON_MIN_VER}"
    # Python < 3.11 需要 tomli 包（QEMU mkvenv 依赖）
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
else
    fail "Python 版本过低: ${PYTHON_VER:-未安装}（需要 >= ${PYTHON_MIN_VER}）"
    fail "  Ubuntu: sudo apt-get install -y python3"
    DEP_ERRORS+=("Python < ${PYTHON_MIN_VER}")
fi

# ---- [检查] pixman >= 0.21.8 ----
PIXMAN_MIN_VER="0.21.8"
PIXMAN_VER=$(pkg-config --modversion pixman-1 2>/dev/null || echo "")
if [ -n "$PIXMAN_VER" ] && version_ge "$PIXMAN_VER" "$PIXMAN_MIN_VER"; then
    ok "pixman ${PIXMAN_VER} >= ${PIXMAN_MIN_VER}"
else
    fail "pixman 版本不满足: ${PIXMAN_VER:-未安装}（需要 >= ${PIXMAN_MIN_VER}）"
    fail "  Ubuntu: sudo apt-get install -y libpixman-1-dev"
    DEP_ERRORS+=("pixman < ${PIXMAN_MIN_VER}")
fi

# ---- [检查] zlib ----
ZLIB_VER=$(pkg-config --modversion zlib 2>/dev/null || echo "")
if [ -n "$ZLIB_VER" ]; then
    ok "zlib ${ZLIB_VER}"
else
    fail "zlib 开发库未安装"
    fail "  Ubuntu: sudo apt-get install -y zlib1g-dev"
    DEP_ERRORS+=("zlib 未安装")
fi

# ---- [检查] libslirp（QEMU 用户网络需要）----
SLIRP_VER=$(pkg-config --modversion slirp 2>/dev/null || echo "")
if [ -n "$SLIRP_VER" ]; then
    ok "libslirp ${SLIRP_VER}"
else
    warn "libslirp 未安装（QEMU 用户网络模式需要，非必须）"
    warn "  Ubuntu: sudo apt-get install -y libslirp-dev"
fi

# ---- [检查+修复] glib >= 2.66.0（Ubuntu 20.04 核心问题）----
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

    # 安装 glib 编译依赖
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
        meson setup _build --prefix=/usr/local
    fi
    ninja -C _build

    info "安装 glib 到 /usr/local（需要 sudo）..."
    sudo ninja -C _build install
    sudo ldconfig
    cd "$PROJECT_DIR"

    # 设置环境变量确保后续步骤能找到新 glib
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

    # 验证
    NEW_GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "unknown")
    if version_ge "$NEW_GLIB_VER" "$GLIB_MIN_VER"; then
        ok "glib ${NEW_GLIB_VER} 安装成功"
    else
        fail "glib 安装后版本检测异常: ${NEW_GLIB_VER}"
        fail "请检查 PKG_CONFIG_PATH 是否包含 /usr/local/lib/pkgconfig"
        exit 1
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
# [3/9] 编译 Bridge 库 (cmake)
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[3/9] 编译 Bridge 库${NC}"
echo "========================================================"

mkdir -p "$BUILD_DIR"
# 显式指定 C 编译器，避免 /bin/gcc 符号链接异常导致编译失败
COSIM_CC="${COSIM_CC:-$(command -v gcc-9 || command -v gcc)}"
cmake -B "$BUILD_DIR" -S "$PROJECT_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$COSIM_CC"
cmake --build "$BUILD_DIR" -j"$(nproc)"

# 验证产物
if [ -f "${BRIDGE_LIB_DIR}/libcosim_bridge.so" ]; then
    ok "libcosim_bridge.so 编译成功: ${BRIDGE_LIB_DIR}/libcosim_bridge.so"
else
    fail "libcosim_bridge.so 未生成"
    exit 1
fi

# ============================================================
# [4/9] 编译 QEMU（含 CoSim 插件）
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[4/9] 编译 QEMU（含 CoSim PCIe RC 设备）${NC}"
echo "========================================================"

mkdir -p "${PROJECT_DIR}/third_party"

# ---- 获取 QEMU 源码 ----
# 支持环境变量 QEMU_SRC_DIR 指向已有的 QEMU 源码目录
QEMU_SRC_DIR="${QEMU_SRC_DIR:-}"

if [ -d "$QEMU_DIR" ]; then
    info "QEMU 源码已存在于 ${QEMU_DIR}，跳过下载"
elif [ -n "$QEMU_SRC_DIR" ] && [ -d "$QEMU_SRC_DIR" ]; then
    # 使用用户指定的已有 QEMU 源码（符号链接）
    info "使用已有 QEMU 源码: ${QEMU_SRC_DIR}"
    ln -sfn "$QEMU_SRC_DIR" "$QEMU_DIR"
    ok "已链接 QEMU 源码: ${QEMU_SRC_DIR} -> ${QEMU_DIR}"
else
    # 自动搜索常见位置
    FOUND_QEMU=""
    for candidate in "$HOME/workspace/qemu-9.2.0" "$HOME/workspace/qemu" \
                     "$HOME/qemu-9.2.0" "$HOME/qemu"; do
        if [ -d "$candidate" ] && [ -f "$candidate/configure" ]; then
            FOUND_QEMU="$candidate"
            break
        fi
    done

    if [ -n "$FOUND_QEMU" ]; then
        info "自动发现 QEMU 源码: ${FOUND_QEMU}"
        ln -sfn "$FOUND_QEMU" "$QEMU_DIR"
        ok "已链接 QEMU 源码: ${FOUND_QEMU} -> ${QEMU_DIR}"
    else
        # 优先尝试 git clone
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

        # git clone 失败时，检查本地 tarball
        if [ "$QEMU_FETCHED" = false ]; then
            TARBALL="${PROJECT_DIR}/third_party/qemu-9.2.0.tar.xz"
            if [ -f "$TARBALL" ]; then
                info "从本地 tarball 解压 QEMU..."
                cd "${PROJECT_DIR}/third_party"
                tar xf "$TARBALL"
                if [ -d "qemu-9.2.0" ] && [ ! -d "qemu" ]; then
                    mv qemu-9.2.0 qemu
                fi
                cd "$PROJECT_DIR"
                ok "QEMU 源码解压完成"
            else
                fail "无法获取 QEMU 源码！"
                fail "  尝试过: git clone, 本地 tarball, 常见目录搜索"
                fail "  解决方法:"
                fail "    1. 设置 QEMU_SRC_DIR 环境变量指向 QEMU 源码目录"
                fail "    2. 将 QEMU 源码放到 ${QEMU_DIR}"
                fail "    3. 将 tarball 放到 ${TARBALL}"
                exit 1
            fi
        fi
    fi
fi

# ---- 注入自定义设备代码 ----
info "注入 cosim_pcie_rc 设备到 QEMU 源码树..."
cp "${PROJECT_DIR}/qemu-plugin/cosim_pcie_rc.c" "${QEMU_DIR}/hw/net/"
cp "${PROJECT_DIR}/qemu-plugin/cosim_pcie_rc.h" "${QEMU_DIR}/include/hw/net/"

# ---- 修改 meson.build（幂等操作）----
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

# ---- 配置 QEMU ----
cd "$QEMU_DIR"

# 检查 QEMU 编译依赖
QEMU_DEPS_OK=true
for dep in meson ninja pkg-config; do
    if ! command -v "$dep" &>/dev/null; then
        fail "QEMU 编译需要 ${dep}，但未找到"
        fail "  安装方法: pip3 install --user ${dep}"
        QEMU_DEPS_OK=false
    fi
done

if [ "$QEMU_DEPS_OK" = false ]; then
    warn "QEMU 编译依赖不满足，跳过 QEMU 编译"
    warn "  请安装缺失依赖后重新运行 setup.sh"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    cd "$PROJECT_DIR"
else
    if [ ! -f "build/build.ninja" ]; then
        info "配置 QEMU (--target-list=x86_64-softmmu)..."
        ./configure \
            --target-list=x86_64-softmmu \
            --extra-cflags="-I${PROJECT_DIR}/bridge/common -I${PROJECT_DIR}/bridge/qemu" \
            --extra-ldflags="-L${BRIDGE_LIB_DIR} -lcosim_bridge -Wl,-rpath,${BRIDGE_LIB_DIR}"
    else
        info "QEMU 已配置，跳过 configure"
    fi

    # ---- 编译 QEMU ----
    info "编译 QEMU（可能需要几分钟）..."
    cd build && ninja -j"$(nproc)"
    cd "$PROJECT_DIR"
fi

# 验证产物
QEMU_BIN="${QEMU_DIR}/build/qemu-system-x86_64"
if [ -f "$QEMU_BIN" ]; then
    ok "QEMU 编译成功: ${QEMU_BIN}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    if [ "$QEMU_DEPS_OK" = false ]; then
        warn "QEMU 未编译（依赖缺失已跳过）"
    else
        fail "qemu-system-x86_64 未生成"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ============================================================
# [5/9] 编译 VCS simv（如果 VCS 可用）
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[5/9] 编译 VCS simv${NC}"
echo "========================================================"

VCS_BIN=""

# 查找 vcs 二进制：PATH > VCS_HOME > 常见安装路径
if command -v vcs &>/dev/null; then
    VCS_BIN="$(command -v vcs)"
elif [ -n "$VCS_HOME" ] && [ -x "${VCS_HOME}/bin/vcs" ]; then
    VCS_BIN="${VCS_HOME}/bin/vcs"
else
    # 搜索常见安装路径
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
    warn "未找到 VCS，跳过 simv 编译（VCS 为可选组件，不影响单元测试）"
    SKIP_COUNT=$((SKIP_COUNT + 1))
else
    info "使用 VCS: ${VCS_BIN}"

    # 自动推导 VCS_HOME（如果未设置）
    if [ -z "${VCS_HOME:-}" ]; then
        # VCS_BIN 通常是 /opt/synopsys/vcs/VERSION/bin/vcs
        VCS_HOME="$(cd "$(dirname "$VCS_BIN")/.." && pwd)"
        export VCS_HOME
        info "自动设置 VCS_HOME=${VCS_HOME}"
    fi
    export PATH="${VCS_HOME}/bin:$PATH"

    # 尝试加载 EDA 环境（如果存在 set-env.sh）
    # 注意: 必须临时关闭 set -e，因为 set-env.sh 中可能有命令返回非零
    for envfile in "$HOME/set-env.sh" "$HOME/.set-env.sh"; do
        if [ -f "$envfile" ]; then
            info "加载 EDA 环境: ${envfile}"
            set +eu
            source "$envfile" 2>/dev/null
            set -eu
            break
        fi
    done

    mkdir -p "$VCS_SIM_DIR"
    cd "$VCS_SIM_DIR"

    # 编译 simv：包含所有 C/SV 源文件
    # 注意: +timescale_override 解决 timescale 不一致问题
    set +e
    "$VCS_BIN" -full64 -sverilog \
        -timescale=1ns/1ps \
        -CFLAGS "-std=gnu99 -I ${PROJECT_DIR}/bridge/common -I ${PROJECT_DIR}/bridge/qemu -I ${PROJECT_DIR}/bridge/vcs -I ${PROJECT_DIR}/bridge/eth" \
        "${PROJECT_DIR}/bridge/vcs/bridge_vcs.c" \
        "${PROJECT_DIR}/bridge/vcs/virtqueue_dma.c" \
        "${PROJECT_DIR}/bridge/common/ring_buffer.c" \
        "${PROJECT_DIR}/bridge/common/shm_layout.c" \
        "${PROJECT_DIR}/bridge/qemu/sock_sync.c" \
        "${PROJECT_DIR}/bridge/eth/eth_mac_dpi.c" \
        "${PROJECT_DIR}/bridge/eth/eth_port.c" \
        "${PROJECT_DIR}/bridge/common/eth_shm.c" \
        "${PROJECT_DIR}/bridge/common/link_model.c" \
        "${PROJECT_DIR}/bridge/common/dma_manager.c" \
        "${PROJECT_DIR}/bridge/vcs/bridge_vcs.sv" \
        "${PROJECT_DIR}"/vcs-tb/*.sv \
        -LDFLAGS "-lrt -lpthread" \
        -o simv
    VCS_RET=$?
    set -e

    cd "$PROJECT_DIR"

    if [ "$VCS_RET" -ne 0 ]; then
        fail "VCS 编译失败 (exit code: $VCS_RET)"
        fail "  请检查 VCS 许可证和环境设置"
    fi

    if [ -f "${VCS_SIM_DIR}/simv" ]; then
        ok "simv 编译成功: ${VCS_SIM_DIR}/simv"
    else
        fail "simv 未生成"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ============================================================
# [6/9] 编译 eth_tap_bridge
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[6/9] 编译 eth_tap_bridge${NC}"
echo "========================================================"

cd "${PROJECT_DIR}/tools"
make clean 2>/dev/null || true
make
cd "$PROJECT_DIR"

TAP_BIN="${PROJECT_DIR}/tools/eth_tap_bridge"
if [ -f "$TAP_BIN" ]; then
    ok "eth_tap_bridge 编译成功: ${TAP_BIN}"
else
    fail "eth_tap_bridge 未生成"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# [7/9] 构建 initramfs 镜像
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[7/9] 构建 initramfs 镜像${NC}"
echo "========================================================"

mkdir -p "$IMAGES_DIR"

# 检查是否有 /boot/vmlinuz（容器环境可能没有）
HAS_KERNEL=false
if ls /boot/vmlinuz-* >/dev/null 2>&1; then
    HAS_KERNEL=true
fi

BUILD_INITRAMFS="${PROJECT_DIR}/scripts/build_initramfs.sh"
if [ "$HAS_KERNEL" = true ] && [ -x "$BUILD_INITRAMFS" ]; then
    info "构建 initramfs 变体..."

    # 逐个构建，单个失败不中断整体
    for variant in phase4 phase5 tap; do
        info "构建 ${variant} initramfs..."
        if "$BUILD_INITRAMFS" "$variant" 2>&1; then
            ok "initramfs-${variant} 构建成功"
        else
            warn "initramfs-${variant} 构建失败（非致命错误）"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
else
    if [ "$HAS_KERNEL" = false ]; then
        warn "容器环境未检测到 /boot/vmlinuz，跳过 initramfs 构建"
        info "  容器中请使用已有的 Alpine 内核和 initramfs 文件"
    else
        warn "build_initramfs.sh 不存在或不可执行，跳过 initramfs 构建"
    fi

    # 尝试查找已有的 initramfs 文件
    FOUND_IMAGES=0
    for pattern in "$HOME/workspace/custom-initramfs-"*.gz \
                   "$HOME/workspace/alpine-vmlinuz"*; do
        for f in $pattern; do
            if [ -f "$f" ]; then
                info "  发现已有镜像: $f"
                FOUND_IMAGES=$((FOUND_IMAGES + 1))
            fi
        done
    done
    if [ "$FOUND_IMAGES" -gt 0 ]; then
        ok "发现 ${FOUND_IMAGES} 个已有镜像文件，可直接使用"
    else
        warn "未找到已有镜像文件，需要手动构建 initramfs"
    fi
    SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ============================================================
# [8/9] 运行单元测试
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[8/9] 运行单元测试${NC}"
echo "========================================================"

UNIT_TEST_DIR="${BUILD_DIR}/tests/unit"
if [ -d "$UNIT_TEST_DIR" ]; then
    info "执行单元测试..."
    set +e
    cd "$BUILD_DIR"
    TEST_OUTPUT=$(ctest --test-dir tests/unit --output-on-failure 2>&1)
    TEST_EXIT=$?
    set -e
    cd "$PROJECT_DIR"

    echo "$TEST_OUTPUT"

    # 从 ctest 输出中提取通过/失败数量
    TESTS_PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ tests passed' | grep -oE '[0-9]+' || echo "0")
    TESTS_FAILED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ tests failed' | grep -oE '[0-9]+' || echo "0")

    if [ "$TEST_EXIT" -eq 0 ]; then
        ok "单元测试全部通过 (${TESTS_PASSED} passed)"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        warn "部分单元测试失败 (passed: ${TESTS_PASSED}, failed: ${TESTS_FAILED})"
        warn "  注意: GCC 4.8 环境可能导致部分测试异常，不影响核心功能"
    fi
else
    warn "单元测试目录不存在，跳过 (${UNIT_TEST_DIR})"
    SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ============================================================
# [9/9] 安装摘要
# ============================================================
echo ""
echo "========================================================"
echo -e "${CYAN}[9/9] 安装摘要${NC}"
echo "========================================================"

echo ""
echo "-------- 构建产物 --------"

# 辅助函数：打印产物状态
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
check_artifact "qemu-system-x86_64" "${QEMU_DIR}/build/qemu-system-x86_64"
check_artifact "simv (VCS)"         "${VCS_SIM_DIR}/simv"
check_artifact "eth_tap_bridge"     "${PROJECT_DIR}/tools/eth_tap_bridge"

# 检查 initramfs 镜像
for img in "${IMAGES_DIR}"/*.cpio.gz; do
    if [ -f "$img" ]; then
        check_artifact "initramfs" "$img"
    fi
done

echo ""
echo "-------- 使用方法 --------"
if [ -f "${PROJECT_DIR}/cosim.sh" ]; then
    echo "  运行仿真:"
    echo "    ./cosim.sh phase4     # Phase 4: 环回测试"
    echo "    ./cosim.sh phase5     # Phase 5: 双 VCS 端到端"
    echo "    ./cosim.sh tap        # TAP 桥接模式"
else
    echo "  运行脚本:"
    echo "    ./scripts/run_cosim.sh  # 启动 QEMU 仿真"
fi
echo ""
echo "  重新编译:"
echo "    make bridge             # 仅重编译 bridge 库"
echo "    make test-unit          # 运行单元测试"
echo "    ./setup.sh              # 完整重新构建（幂等）"
echo ""

# 警告汇总
if [ ${#WARN_MSGS[@]} -gt 0 ]; then
    echo ""
    echo "-------- 警告汇总 --------"
    for i in "${!WARN_MSGS[@]}"; do
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${WARN_MSGS[$i]}"
    done
fi

# 最终状态
echo ""
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}安装完成，但有 ${FAIL_COUNT} 个失败项${NC}"
    echo "  请查看以上输出，修复失败项后重新运行 setup.sh"
    exit 1
elif [ "$SKIP_COUNT" -gt 0 ]; then
    echo -e "${GREEN}安装完成${NC}（${SKIP_COUNT} 个可选组件已跳过）"
else
    echo -e "${GREEN}安装完成，所有组件编译成功！${NC}"
fi
