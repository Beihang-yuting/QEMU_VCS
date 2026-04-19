#!/bin/bash
# cosim-platform/scripts/run_phase5_test.sh
# Phase 5: TCP/iperf 吞吐量测试（双 VCS 互联模式）
#
# Guest1 (10.0.0.1) = server (iperf3 -s, nc -l)
# Guest2 (10.0.0.2) = client (iperf3 -c, nc send)
#
# 用法：
#   ./run_phase5_test.sh [选项]
#     -q <path>     QEMU 路径
#     -k <path>     Guest kernel
#     -r <path>     Guest initramfs
#     -s <path>     VCS simv 路径
#     -e <name>     ETH SHM 名称 (默认: /cosim_eth0)
#     -t <seconds>  超时时间 (默认: 180)
#     -h            帮助

set -euo pipefail

# ========== 默认配置 ==========
QEMU="${QEMU:-$HOME/workspace/qemu-9.2.0/build/qemu-system-x86_64}"
KERNEL="${KERNEL:-$HOME/workspace/alpine-vmlinuz-new}"
INITRD="${INITRD:-$HOME/workspace/custom-initramfs-phase5.gz}"
SIMV="${SIMV:-$HOME/workspace/cosim-platform/vcs-tb/sim_build/simv}"
ETH_SHM="${ETH_SHM:-/cosim_eth0}"
TIMEOUT="${TIMEOUT:-300}"

# PCIe SHM / socket 配置
SHM1="/cosim0"
SHM2="/cosim1"
SOCK1="/tmp/cosim0.sock"
SOCK2="/tmp/cosim1.sock"

# Guest 配置
# Server = Guest1 (10.0.0.1), Client = Guest2 (10.0.0.2)
SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"

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
    echo "[P5] Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/"${ETH_SHM#/}"
    rm -f "$SOCK1" "$SOCK2"
    echo "[P5] Cleanup done"
}
trap cleanup EXIT INT TERM

# ========== 清理旧资源 ==========
echo "[P5] Cleaning up old resources..."
rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/"${ETH_SHM#/}"
rm -f "$SOCK1" "$SOCK2"

# ========== 日志目录 ==========
LOGDIR="/tmp/cosim_phase5_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"
echo "[P5] Logs: $LOGDIR/"

# ========== 1. 启动 QEMU1 (Server: 10.0.0.1) ==========
echo "[P5] Starting QEMU1 (Server: $SERVER_IP)..."
"$QEMU" \
    -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 init=/init guest_ip=$SERVER_IP peer_ip=$CLIENT_IP role=server wait_sec=25" \
    -device "cosim-pcie-rc,shm_name=$SHM1,sock_path=$SOCK1" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu1_debug.log" \
    > "$LOGDIR/qemu1.log" 2>&1 &
PIDS+=($!)
echo "[P5]   QEMU1 PID: ${PIDS[-1]}"
sleep 2

# ========== 2. 启动 QEMU2 (Client: 10.0.0.2) ==========
echo "[P5] Starting QEMU2 (Client: $CLIENT_IP)..."
"$QEMU" \
    -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 init=/init guest_ip=$CLIENT_IP peer_ip=$SERVER_IP role=client wait_sec=25" \
    -device "cosim-pcie-rc,shm_name=$SHM2,sock_path=$SOCK2" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu2_debug.log" \
    > "$LOGDIR/qemu2.log" 2>&1 &
PIDS+=($!)
echo "[P5]   QEMU2 PID: ${PIDS[-1]}"
sleep 2

# ========== 3. 检查 SHM ==========
echo "[P5] Checking SHM..."
ls -la /dev/shm/cosim0 /dev/shm/cosim1 2>/dev/null || {
    echo "ERROR: PCIe SHM not created. QEMU may have failed."
    cat "$LOGDIR/qemu1.log"
    exit 1
}

# ========== 4. 启动 VCS1 (Role A) ==========
SIMV_DIR="$(dirname "$SIMV")"
echo "[P5] Starting VCS1 (Role A, MAC=01)..."
cd "$SIMV_DIR"
./simv +SHM_NAME="$SHM1" +SOCK_PATH="$SOCK1" \
       +ETH_SHM="$ETH_SHM" +ETH_ROLE=0 +ETH_CREATE=1 \
       +SIM_TIMEOUT_MS=300000 +MAC_LAST=1 \
       > "$LOGDIR/vcs1.log" 2>&1 &
PIDS+=($!)
echo "[P5]   VCS1 PID: ${PIDS[-1]}"
sleep 3

# ========== 5. 启动 VCS2 (Role B) ==========
echo "[P5] Starting VCS2 (Role B, MAC=02)..."
./simv +SHM_NAME="$SHM2" +SOCK_PATH="$SOCK2" \
       +ETH_SHM="$ETH_SHM" +ETH_ROLE=1 +ETH_CREATE=0 \
       +SIM_TIMEOUT_MS=300000 +MAC_LAST=2 \
       > "$LOGDIR/vcs2.log" 2>&1 &
PIDS+=($!)
echo "[P5]   VCS2 PID: ${PIDS[-1]}"

# ========== 6. 等待并监控 ==========
echo ""
echo "[P5] ============================================"
echo "[P5]  Phase 5: TCP/iperf Test"
echo "[P5]  Server: $SERVER_IP  (QEMU1 + VCS1/RoleA)"
echo "[P5]  Client: $CLIENT_IP  (QEMU2 + VCS2/RoleB)"
echo "[P5]  ETH SHM: $ETH_SHM"
echo "[P5]  Timeout: ${TIMEOUT}s"
echo "[P5] ============================================"
echo ""
echo "[P5] Waiting for test to complete..."

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
echo "[P5] ========== Phase 5 Test Results =========="

echo ""
echo "--- QEMU1 (Server: $SERVER_IP) ---"
grep -E "(Phase 5|TCP|nc|iperf|PASS|FAIL|Received|Server|rx_|tx_|bytes)" "$LOGDIR/qemu1.log" 2>/dev/null | tail -30

echo ""
echo "--- QEMU2 (Client: $CLIENT_IP) ---"
grep -E "(Phase 5|TCP|nc|iperf|PASS|FAIL|Sending|Client|rx_|tx_|bytes)" "$LOGDIR/qemu2.log" 2>/dev/null | tail -30

echo ""
echo "--- VCS1 (Role A) ---"
grep -E "(VQ-TX|VQ-RX|ETH|Forwarded|Injected)" "$LOGDIR/vcs1.log" 2>/dev/null | tail -15

echo ""
echo "--- VCS2 (Role B) ---"
grep -E "(VQ-TX|VQ-RX|ETH|Forwarded|Injected)" "$LOGDIR/vcs2.log" 2>/dev/null | tail -15

echo ""
echo "--- QEMU1 Debug (MSI/DMA) ---"
grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu1_debug.log" 2>/dev/null | tail -10

echo ""
echo "--- QEMU2 Debug (MSI/DMA) ---"
grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu2_debug.log" 2>/dev/null | tail -10

echo ""
echo "[P5] Full logs: $LOGDIR/"
echo "[P5] Done."
