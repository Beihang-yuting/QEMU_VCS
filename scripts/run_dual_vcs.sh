#!/bin/bash
# cosim-platform/scripts/run_dual_vcs.sh
# 双 VCS 互联模式：两个 QEMU + 两个 VCS 通过 ETH SHM 互联
#
# 模式说明：
#   Mode 1 (TAP):  单 VCS + TAP bridge（需要 sudo）
#     ./run_cosim.sh                    # 启动 QEMU
#     simv +ETH_ROLE=0 +ETH_CREATE=1   # VCS (Role A, 创建 ETH SHM)
#     sudo eth_tap_bridge               # TAP bridge (Role B)
#
#   Mode 2 (DUAL): 双 VCS 互联（无需 sudo）
#     ./run_dual_vcs.sh                 # 本脚本一键启动全部
#
# 数据流 (Mode 2):
#   Guest1 TX → VCS1(A) → ETH SHM a_to_b → VCS2(B) → Guest2 RX
#   Guest2 TX → VCS2(B) → ETH SHM b_to_a → VCS1(A) → Guest1 RX
#
# 用法：
#   ./run_dual_vcs.sh [选项]
#     -q <path>     QEMU 路径 (默认: ~/workspace/qemu-9.2.0/build/qemu-system-x86_64)
#     -k <path>     Guest kernel (默认: ~/workspace/alpine-vmlinuz-new)
#     -r <path>     Guest initramfs (默认: ~/workspace/custom-initramfs-phase4.gz)
#     -s <path>     VCS simv 路径 (默认: ~/workspace/cosim-platform/vcs-tb/sim_build/simv)
#     -e <name>     ETH SHM 名称 (默认: /cosim_eth0)
#     -t <seconds>  超时时间 (默认: 60)
#     -h            帮助

set -euo pipefail

# ========== 默认配置 ==========
QEMU="${QEMU:-$HOME/workspace/qemu-9.2.0/build/qemu-system-x86_64}"
KERNEL="${KERNEL:-$HOME/workspace/alpine-vmlinuz-new}"
INITRD="${INITRD:-$HOME/workspace/custom-initramfs-phase4.gz}"
SIMV="${SIMV:-$HOME/workspace/cosim-platform/vcs-tb/sim_build/simv}"
ETH_SHM="${ETH_SHM:-/cosim_eth0}"
TIMEOUT="${TIMEOUT:-120}"

# PCIe SHM / socket 配置（两个实例各自独立）
SHM1="/cosim0"
SHM2="/cosim1"
SOCK1="/tmp/cosim0.sock"
SOCK2="/tmp/cosim1.sock"

# Guest IP 配置
GUEST1_IP="10.0.0.2"
GUEST2_IP="10.0.0.1"

# VCS license
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-/opt/synopsys/license/license.dat}"

# ========== 参数解析 ==========
while getopts "q:k:r:s:e:t:h" opt; do
    case $opt in
        q) QEMU="$OPTARG" ;;
        k) KERNEL="$OPTARG" ;;
        r) INITRD="$OPTARG" ;;
        s) SIMV="$OPTARG" ;;
        e) ETH_SHM="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        h) sed -n '2,/^$/p' "$0" | sed 's/^# //'; exit 0 ;;
        *) exit 1 ;;
    esac
done

# ========== 前置检查 ==========
for f in "$QEMU" "$KERNEL" "$INITRD" "$SIMV"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: File not found: $f"
        exit 1
    fi
done

# ========== 清理函数 ==========
PIDS=()
cleanup() {
    echo ""
    echo "[DUAL] Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/"${ETH_SHM#/}"
    rm -f "$SOCK1" "$SOCK2"
    echo "[DUAL] Cleanup done"
}
trap cleanup EXIT INT TERM

# ========== 清理旧资源 ==========
echo "[DUAL] Cleaning up old resources..."
rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/"${ETH_SHM#/}"
rm -f "$SOCK1" "$SOCK2"

# ========== 日志目录 ==========
LOGDIR="/tmp/cosim_dual_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"
echo "[DUAL] Logs: $LOGDIR/"

# ========== 1. 启动 QEMU1 (Guest1) ==========
echo "[DUAL] Starting QEMU1 (Guest1: $GUEST1_IP)..."
"$QEMU" \
    -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 init=/init guest_ip=$GUEST1_IP peer_ip=$GUEST2_IP wait_sec=25" \
    -device "cosim-pcie-rc,shm_name=$SHM1,sock_path=$SOCK1" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu1_debug.log" \
    > "$LOGDIR/qemu1.log" 2>&1 &
PIDS+=($!)
echo "[DUAL]   QEMU1 PID: ${PIDS[-1]}"
sleep 2

# ========== 2. 启动 QEMU2 (Guest2) ==========
echo "[DUAL] Starting QEMU2 (Guest2: $GUEST2_IP)..."
"$QEMU" \
    -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 init=/init guest_ip=$GUEST2_IP peer_ip=$GUEST1_IP wait_sec=25" \
    -device "cosim-pcie-rc,shm_name=$SHM2,sock_path=$SOCK2" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu2_debug.log" \
    > "$LOGDIR/qemu2.log" 2>&1 &
PIDS+=($!)
echo "[DUAL]   QEMU2 PID: ${PIDS[-1]}"
sleep 2

# ========== 3. 检查 SHM 创建 ==========
echo "[DUAL] Checking SHM..."
ls -la /dev/shm/cosim0 /dev/shm/cosim1 2>/dev/null || {
    echo "ERROR: PCIe SHM not created. QEMU may have failed."
    cat "$LOGDIR/qemu1.log"
    exit 1
}

# ========== 4. 启动 VCS1 (Role A, 创建 ETH SHM) ==========
SIMV_DIR="$(dirname "$SIMV")"
echo "[DUAL] Starting VCS1 (Role A, MAC=01, create ETH SHM)..."
cd "$SIMV_DIR"
./simv +SHM_NAME="$SHM1" +SOCK_PATH="$SOCK1" \
       +ETH_SHM="$ETH_SHM" +ETH_ROLE=0 +ETH_CREATE=1 \
       +SIM_TIMEOUT_MS=60000 +MAC_LAST=1 \
       > "$LOGDIR/vcs1.log" 2>&1 &
PIDS+=($!)
echo "[DUAL]   VCS1 PID: ${PIDS[-1]}"
sleep 3

# ========== 5. 启动 VCS2 (Role B, 打开 ETH SHM) ==========
echo "[DUAL] Starting VCS2 (Role B, MAC=02, open ETH SHM)..."
./simv +SHM_NAME="$SHM2" +SOCK_PATH="$SOCK2" \
       +ETH_SHM="$ETH_SHM" +ETH_ROLE=1 +ETH_CREATE=0 \
       +SIM_TIMEOUT_MS=60000 +MAC_LAST=2 \
       > "$LOGDIR/vcs2.log" 2>&1 &
PIDS+=($!)
echo "[DUAL]   VCS2 PID: ${PIDS[-1]}"

# ========== 6. 等待并监控 ==========
echo ""
echo "[DUAL] ============================================"
echo "[DUAL]  All components started"
echo "[DUAL]  Guest1: $GUEST1_IP  (QEMU1 + VCS1/RoleA)"
echo "[DUAL]  Guest2: $GUEST2_IP  (QEMU2 + VCS2/RoleB)"
echo "[DUAL]  ETH SHM: $ETH_SHM"
echo "[DUAL]  Timeout: ${TIMEOUT}s"
echo "[DUAL] ============================================"
echo ""
echo "[DUAL] Waiting for test to complete..."

# 等待所有进程结束或超时
DEADLINE=$((SECONDS + TIMEOUT))
while [ $SECONDS -lt $DEADLINE ]; do
    ALL_DONE=true
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            ALL_DONE=false
        fi
    done
    if $ALL_DONE; then
        break
    fi
    sleep 1
done

# ========== 7. 收集结果 ==========
echo ""
echo "[DUAL] ========== Test Results =========="

echo ""
echo "--- QEMU1 (Guest1) ---"
grep -E "(Phase 4|ping|Sending|packets|rx_|tx_|PASS|FAIL|error)" "$LOGDIR/qemu1.log" 2>/dev/null | tail -20

echo ""
echo "--- QEMU2 (Guest2) ---"
grep -E "(Phase 4|ping|Sending|packets|rx_|tx_|PASS|FAIL|error)" "$LOGDIR/qemu2.log" 2>/dev/null | tail -20

echo ""
echo "--- VCS1 (Role A) ---"
grep -E "(VQ-TX|VQ-RX|ETH|NOTIFY|ISR|Forwarded|Injected)" "$LOGDIR/vcs1.log" 2>/dev/null | tail -15

echo ""
echo "--- VCS2 (Role B) ---"
grep -E "(VQ-TX|VQ-RX|ETH|NOTIFY|ISR|Forwarded|Injected)" "$LOGDIR/vcs2.log" 2>/dev/null | tail -15

echo ""
echo "--- QEMU1 Debug (MSI/DMA callbacks) ---"
grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu1_debug.log" 2>/dev/null | tail -20

echo ""
echo "--- QEMU2 Debug (MSI/DMA callbacks) ---"
grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu2_debug.log" 2>/dev/null | tail -20

echo ""
echo "[DUAL] Full logs: $LOGDIR/"
echo "[DUAL] Done."
