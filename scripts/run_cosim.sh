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

if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    QEMU_ARGS+=(-cpu host -enable-kvm)
    echo "KVM acceleration enabled"
else
    QEMU_ARGS+=(-cpu max)
    echo "WARNING: KVM not available, using TCG (slower)"
fi

if [ -n "$GUEST_ROOTFS" ] && [ -f "$GUEST_ROOTFS" ]; then
    QEMU_ARGS+=(-drive "file=${GUEST_ROOTFS},format=qcow2,if=virtio")
fi

if [ "${GDB:-0}" = "1" ]; then
    QEMU_ARGS+=(-s -S)
    echo "GDB server enabled on :1234 (waiting for connection)"
fi

echo "Starting QEMU with CoSim device..."
echo "  SHM: $SHM_NAME"
echo "  Socket: $SOCK_PATH"
echo ""
exec "$QEMU" "${QEMU_ARGS[@]}"
