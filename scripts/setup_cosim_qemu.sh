#!/bin/bash
# cosim-platform/scripts/setup_cosim_qemu.sh
# 一键搭建 QEMU + CoSim Bridge 环境
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
QEMU_VERSION="v9.2.0"
QEMU_DIR="${PROJECT_DIR}/third_party/qemu"
BUILD_DIR="${PROJECT_DIR}/build"

echo "=== CoSim QEMU Setup ==="
echo "Project: ${PROJECT_DIR}"
echo "QEMU version: ${QEMU_VERSION}"

# ---- Step 1: 安装系统依赖 ----
echo ""
echo "[1/7] Checking system dependencies..."
DEPS="build-essential ninja-build meson pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev python3 python3-pip git cmake"
MISSING=""
for dep in $DEPS; do
    if ! dpkg -l "$dep" &>/dev/null; then
        MISSING="$MISSING $dep"
    fi
done
if [ -n "$MISSING" ]; then
    echo "Installing missing packages:$MISSING"
    sudo apt-get update
    sudo apt-get install -y $MISSING
else
    echo "All dependencies installed."
fi

# ---- Step 2: 下载 QEMU 源码 ----
echo ""
echo "[2/7] Fetching QEMU source..."
mkdir -p "${PROJECT_DIR}/third_party"
if [ -d "$QEMU_DIR" ]; then
    echo "QEMU source already exists, skipping download."
else
    git clone https://github.com/qemu/qemu.git \
        --branch "$QEMU_VERSION" --depth 1 "$QEMU_DIR"
fi

# ---- Step 3: 注入自定义设备代码 ----
echo ""
echo "[3/7] Injecting cosim PCIe RC device into QEMU source tree..."
cp "${PROJECT_DIR}/qemu-plugin/cosim_pcie_rc.c" "${QEMU_DIR}/hw/net/"
cp "${PROJECT_DIR}/qemu-plugin/cosim_pcie_rc.h" "${QEMU_DIR}/include/hw/net/"

# 修改 meson.build（幂等：先检查是否已添加）
MESON_FILE="${QEMU_DIR}/hw/net/meson.build"
if ! grep -q "cosim_pcie_rc" "$MESON_FILE"; then
    echo "" >> "$MESON_FILE"
    echo "# CoSim PCIe RC device" >> "$MESON_FILE"
    echo "system_ss.add(files('cosim_pcie_rc.c'))" >> "$MESON_FILE"
    echo "Patched $MESON_FILE"
else
    echo "meson.build already patched."
fi

# ---- Step 4: 编译 Bridge 库 ----
echo ""
echo "[4/7] Building Bridge library..."
cmake -B "$BUILD_DIR" -S "$PROJECT_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j"$(nproc)" --target cosim_bridge

BRIDGE_LIB_DIR="${BUILD_DIR}/bridge"

echo "Bridge library: ${BRIDGE_LIB_DIR}/libcosim_bridge.so"

# ---- Step 5: 编译 QEMU ----
echo ""
echo "[5/7] Configuring and building QEMU..."
cd "$QEMU_DIR"
if [ ! -f "build/build.ninja" ]; then
    ./configure \
        --target-list=x86_64-softmmu \
        --extra-cflags="-I${PROJECT_DIR}/bridge/common -I${PROJECT_DIR}/bridge/qemu" \
        --extra-ldflags="-L${BRIDGE_LIB_DIR} -lcosim_bridge -Wl,-rpath,${BRIDGE_LIB_DIR}"
fi
cd build && ninja -j"$(nproc)"
cd "$PROJECT_DIR"

echo "QEMU binary: ${QEMU_DIR}/build/qemu-system-x86_64"

# ---- Step 6: 检查 Guest 镜像 ----
echo ""
echo "[6/7] Checking guest image..."
GUEST_DIR="${PROJECT_DIR}/guest"
mkdir -p "$GUEST_DIR"
if [ ! -f "${GUEST_DIR}/bzImage" ]; then
    echo "WARNING: No guest kernel found at ${GUEST_DIR}/bzImage"
    echo "Please provide:"
    echo "  - ${GUEST_DIR}/bzImage  (Linux kernel)"
    echo "  - ${GUEST_DIR}/rootfs.img  (root filesystem, optional)"
else
    echo "Guest kernel found."
fi

# ---- Step 7: 生成启动脚本 ----
echo ""
echo "[7/7] Generating run script..."
cat > "${PROJECT_DIR}/scripts/run_cosim.sh" << 'RUNEOF'
#!/bin/bash
# 启动 CoSim 仿真：QEMU 端
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SHM_NAME="${SHM_NAME:-/cosim0}"
SOCK_PATH="${SOCK_PATH:-/tmp/cosim.sock}"
GUEST_KERNEL="${GUEST_KERNEL:-${PROJECT_DIR}/guest/bzImage}"
GUEST_ROOTFS="${GUEST_ROOTFS:-}"
QEMU="${PROJECT_DIR}/third_party/qemu/build/qemu-system-x86_64"
MEMORY="${MEMORY:-4G}"

QEMU_ARGS=(
    -machine q35
    -m "$MEMORY"
    -nographic
    -device "cosim-pcie-rc,shm_name=${SHM_NAME},sock_path=${SOCK_PATH}"
    -kernel "$GUEST_KERNEL"
    -append "console=ttyS0 nokaslr"
)

# KVM 加速（如果可用）
if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    QEMU_ARGS+=(-cpu host -enable-kvm)
    echo "KVM acceleration enabled"
else
    QEMU_ARGS+=(-cpu max)
    echo "WARNING: KVM not available, using TCG (slower)"
fi

# 根文件系统（可选）
if [ -n "$GUEST_ROOTFS" ] && [ -f "$GUEST_ROOTFS" ]; then
    QEMU_ARGS+=(-drive "file=${GUEST_ROOTFS},format=qcow2,if=virtio")
fi

# GDB 调试端口（可选）
if [ "${GDB:-0}" = "1" ]; then
    QEMU_ARGS+=(-s -S)
    echo "GDB server enabled on :1234 (waiting for connection)"
fi

echo "Starting QEMU with CoSim device..."
echo "  SHM: $SHM_NAME"
echo "  Socket: $SOCK_PATH"
echo ""
exec "$QEMU" "${QEMU_ARGS[@]}"
RUNEOF
chmod +x "${PROJECT_DIR}/scripts/run_cosim.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Usage:"
echo "  1. Start VCS simulation (with matching SHM_NAME and SOCK_PATH)"
echo "  2. Run: ./scripts/run_cosim.sh"
echo "  3. Or with GDB: GDB=1 ./scripts/run_cosim.sh"
echo ""
echo "Environment variables:"
echo "  SHM_NAME    - Shared memory name (default: /cosim0)"
echo "  SOCK_PATH   - Unix socket path (default: /tmp/cosim.sock)"
echo "  GUEST_KERNEL - Path to Linux kernel bzImage"
echo "  MEMORY      - Guest memory size (default: 4G)"
echo "  GDB         - Set to 1 to enable GDB server"
