#!/bin/bash
# run_e2e_virtio.sh — 跨机 QEMU+VCS virtio 端到端测试
#
# 用法 (在 53 QEMU 机器上执行):
#   ./scripts/run_e2e_virtio.sh
#
# 环境变量:
#   VCS_HOST     VCS 机器地址 (默认 10.11.10.61)
#   VCS_PORT     VCS SSH 端口 (默认 2222)
#   VCS_USER     VCS SSH 用户 (默认 ryan)
#   VCS_PASS     VCS SSH 密码 (默认 Ryan@2025)
#   TCP_PORT     cosim TCP 端口 (默认 9100)
#   QEMU_BIN     QEMU 可执行文件路径
#   BUILDROOT    Buildroot output 路径

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 默认参数
VCS_HOST="${VCS_HOST:-10.11.10.61}"
VCS_PORT="${VCS_PORT:-2222}"
VCS_USER="${VCS_USER:-ryan}"
VCS_PASS="${VCS_PASS:-Ryan@2025}"
TCP_PORT="${TCP_PORT:-9100}"
QEMU_BIN="${QEMU_BIN:-${HOME}/workspace/qemu/build/qemu-system-x86_64}"
BUILDROOT="${BUILDROOT:-${HOME}/workspace/buildroot/output/images}"

GUEST_KERNEL="${BUILDROOT}/bzImage"
GUEST_ROOTFS="${BUILDROOT}/rootfs.ext4"

echo "=== CoSim E2E Virtio Test ==="
echo "QEMU machine:  $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "VCS machine:   ${VCS_USER}@${VCS_HOST}:${VCS_PORT}"
echo "TCP port base: ${TCP_PORT}"
echo "Kernel:        ${GUEST_KERNEL}"
echo "Rootfs:        ${GUEST_ROOTFS}"
echo ""

# 检查文件
for f in "$QEMU_BIN" "$GUEST_KERNEL" "$GUEST_ROOTFS"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing file: $f"
        exit 1
    fi
done

# Step 1: 在 VCS 机器上启动仿真 (后台)
echo "[Step 1] Starting VCS simulation on ${VCS_HOST}..."
QEMU_IP=$(hostname -I | awk '{print $1}')
sshpass -p "${VCS_PASS}" ssh -o StrictHostKeyChecking=no -p "${VCS_PORT}" \
    "${VCS_USER}@${VCS_HOST}" "
    source ~/set-env.sh 2>/dev/null
    cd ~/cosim-platform
    killall simv_vip 2>/dev/null || true
    sleep 1
    nohup timeout 120 build/simv_vip \
        +transport=tcp \
        +REMOTE_HOST=${QEMU_IP} \
        +PORT_BASE=${TCP_PORT} \
        +INSTANCE_ID=0 \
        +UVM_TESTNAME=cosim_test \
        > /tmp/vcs_e2e.log 2>&1 &
    echo VCS_PID=\$!
" &
VCS_SSH_PID=$!

echo "[Step 1] Waiting for VCS to connect..."
sleep 5

# Step 2: 启动 QEMU + Guest
echo "[Step 2] Starting QEMU with Guest VM..."

QEMU_ARGS=(
    -machine q35
    -m 512
    -nographic
    -device "cosim-pcie-rc,transport=tcp,port_base=${TCP_PORT},instance_id=0"
    -kernel "$GUEST_KERNEL"
    -append "root=/dev/vda console=ttyS0 nokaslr"
    -drive "file=${GUEST_ROOTFS},format=raw,if=virtio"
    -no-reboot
)

if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    QEMU_ARGS+=(-cpu host -enable-kvm)
    echo "  KVM acceleration enabled"
else
    QEMU_ARGS+=(-cpu max)
    echo "  WARNING: KVM not available, using TCG"
fi

timeout 120 "$QEMU_BIN" "${QEMU_ARGS[@]}" 2>&1 | tee /tmp/qemu_e2e.log &
QEMU_PID=$!

echo "  QEMU PID=${QEMU_PID}"
echo ""

wait $QEMU_PID 2>/dev/null || true

echo ""
echo "=== QEMU exited ==="

# Step 3: 获取 VCS 日志
echo ""
echo "[Step 3] Fetching VCS log..."
sshpass -p "${VCS_PASS}" ssh -o StrictHostKeyChecking=no -p "${VCS_PORT}" \
    "${VCS_USER}@${VCS_HOST}" 'cat /tmp/vcs_e2e.log 2>/dev/null | tail -30' 2>/dev/null || true

wait $VCS_SSH_PID 2>/dev/null || true

echo ""
echo "=== E2E test complete ==="
echo "QEMU log: /tmp/qemu_e2e.log"
echo "VCS log:  ${VCS_USER}@${VCS_HOST}:/tmp/vcs_e2e.log"
