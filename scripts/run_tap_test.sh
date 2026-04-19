#!/bin/bash
# cosim-platform/scripts/run_tap_test.sh
# TAP Bridge 集成测试：单 QEMU guest 通过 VCS + ETH SHM + TAP bridge 与宿主机通信
#
# 架构：
#   QEMU (cosim-pcie-rc) <--PCIe SHM--> VCS (Role A) <--ETH SHM--> eth_tap_bridge (Role B)
#   Guest eth0 (10.0.0.2) <-------------------------------> TAP cosim0 (10.0.0.1)
#
# 用法：
#   ./run_tap_test.sh [选项]
#     -q <path>     QEMU 路径
#     -k <path>     Guest kernel
#     -r <path>     Guest initramfs
#     -s <path>     VCS simv 路径
#     -b <path>     eth_tap_bridge 路径
#     -e <name>     ETH SHM 名称 (默认: /cosim_eth0)
#     -t <seconds>  超时时间 (默认: 120)
#     -h            帮助

set -euo pipefail

# ========== 默认配置 ==========
QEMU="${QEMU:-$HOME/workspace/qemu-9.2.0/build/qemu-system-x86_64}"
KERNEL="${KERNEL:-$HOME/workspace/alpine-vmlinuz-new}"
INITRD="${INITRD:-$HOME/workspace/custom-initramfs-tap.gz}"
SIMV="${SIMV:-$HOME/workspace/cosim-platform/vcs-tb/sim_build/simv}"
TAP_BRIDGE="${TAP_BRIDGE:-$HOME/workspace/cosim-platform/tools/eth_tap_bridge}"
ETH_SHM="${ETH_SHM:-/cosim_eth0}"
TIMEOUT="${TIMEOUT:-120}"

# PCIe SHM / socket 配置（只需一组）
SHM="/cosim0"
SOCK="/tmp/cosim0.sock"

# 网络配置
GUEST_IP="10.0.0.2"
TAP_IP="10.0.0.1"
TAP_DEV="cosim0"

# VCS license
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-/opt/synopsys/license/license.dat}"

# ========== 参数解析 ==========
while getopts "q:k:r:s:b:e:t:h" opt; do
    case $opt in
        q) QEMU="$OPTARG" ;;
        k) KERNEL="$OPTARG" ;;
        r) INITRD="$OPTARG" ;;
        s) SIMV="$OPTARG" ;;
        b) TAP_BRIDGE="$OPTARG" ;;
        e) ETH_SHM="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        h) sed -n '2,/^$/p' "$0" | sed 's/^# //'; exit 0 ;;
        *) exit 1 ;;
    esac
done

# ========== 前置检查 ==========
for f in "$QEMU" "$KERNEL" "$INITRD" "$SIMV" "$TAP_BRIDGE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: File not found: $f"
        exit 1
    fi
done

if [ ! -x "$TAP_BRIDGE" ]; then
    echo "ERROR: eth_tap_bridge is not executable: $TAP_BRIDGE"
    exit 1
fi

# ========== 清理函数 ==========
PIDS=()
cleanup() {
    echo ""
    echo "[TAP] Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    # 删除 TAP 设备（如果存在）
    if /sbin/ip link show "$TAP_DEV" >/dev/null 2>&1; then
        /sbin/ip link set "$TAP_DEV" down 2>/dev/null || true
        /sbin/ip tuntap del dev "$TAP_DEV" mode tap 2>/dev/null || true
    fi
    rm -f /dev/shm/"${SHM#/}" /dev/shm/"${ETH_SHM#/}"
    rm -f "$SOCK"
    echo "[TAP] Cleanup done"
}
trap cleanup EXIT INT TERM

# ========== 清理旧资源 ==========
echo "[TAP] Cleaning up old resources..."
rm -f /dev/shm/"${SHM#/}" /dev/shm/"${ETH_SHM#/}"
rm -f "$SOCK"
# 清理旧 TAP 设备
if ip link show "$TAP_DEV" >/dev/null 2>&1; then
    ip link set "$TAP_DEV" down 2>/dev/null || true
    ip tuntap del dev "$TAP_DEV" mode tap 2>/dev/null || true
fi

# ========== 日志目录 ==========
LOGDIR="/tmp/cosim_tap_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"
echo "[TAP] Logs: $LOGDIR/"

# ========== 1. 启动 QEMU (创建 PCIe SHM) ==========
echo "[TAP] Starting QEMU (Guest: $GUEST_IP)..."
"$QEMU" \
    -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0 init=/init" \
    -device "cosim-pcie-rc,shm_name=$SHM,sock_path=$SOCK" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu_debug.log" \
    > "$LOGDIR/qemu.log" 2>&1 &
PIDS+=($!)
echo "[TAP]   QEMU PID: ${PIDS[-1]}"
sleep 2

# ========== 2. 检查 PCIe SHM ==========
echo "[TAP] Checking PCIe SHM..."
ls -la /dev/shm/"${SHM#/}" 2>/dev/null || {
    echo "ERROR: PCIe SHM not created. QEMU may have failed."
    echo "--- QEMU log ---"
    cat "$LOGDIR/qemu.log"
    exit 1
}

# ========== 3. 启动 VCS (Role A, 创建 ETH SHM) ==========
SIMV_DIR="$(dirname "$SIMV")"
echo "[TAP] Starting VCS (Role A, creates ETH SHM)..."
cd "$SIMV_DIR"
./simv +SHM_NAME="$SHM" +SOCK_PATH="$SOCK" \
       +ETH_SHM="$ETH_SHM" +ETH_ROLE=0 +ETH_CREATE=1 \
       +SIM_TIMEOUT_MS=200000 +MAC_LAST=1 \
       > "$LOGDIR/vcs.log" 2>&1 &
PIDS+=($!)
echo "[TAP]   VCS PID: ${PIDS[-1]}"
sleep 3

# ========== 4. 检查 ETH SHM ==========
echo "[TAP] Checking ETH SHM..."
ls -la /dev/shm/"${ETH_SHM#/}" 2>/dev/null || {
    echo "ERROR: ETH SHM not created. VCS may have failed."
    echo "--- VCS log ---"
    tail -20 "$LOGDIR/vcs.log"
    exit 1
}

# ========== 5. 启动 eth_tap_bridge (Role B on ETH SHM) ==========
echo "[TAP] Starting eth_tap_bridge..."
echo "[TAP]   ETH SHM: $ETH_SHM"
echo "[TAP]   TAP dev: $TAP_DEV"
echo "[TAP]   TAP IP:  $TAP_IP/24"

# eth_tap_bridge 使用 -s/-t/-i 选项
# 它内部使用 system() 调用 /sbin/ip 来配置 TAP 设备
PATH=/sbin:/usr/sbin:$PATH "$TAP_BRIDGE" -s "$ETH_SHM" -t "$TAP_DEV" -i "$TAP_IP/24" \
    > "$LOGDIR/tap_bridge.log" 2>&1 &
PIDS+=($!)
echo "[TAP]   TAP bridge PID: ${PIDS[-1]}"
sleep 2

# 设置 TAP MAC 为 de:ad:be:ef:00:02（与 Guest 静态 ARP 匹配）
sleep 1
/sbin/ip link set "$TAP_DEV" down 2>/dev/null
/sbin/ip link set "$TAP_DEV" address de:ad:be:ef:00:02 2>/dev/null
/sbin/ip link set "$TAP_DEV" up 2>/dev/null
echo "[TAP]   TAP MAC set to de:ad:be:ef:00:02"

# 同时添加反向静态 ARP（Host -> Guest）
arp -s "$GUEST_IP" de:ad:be:ef:00:01 -i "$TAP_DEV" 2>/dev/null || \
  /sbin/ip neigh add "$GUEST_IP" lladdr de:ad:be:ef:00:01 dev "$TAP_DEV" nud permanent 2>/dev/null || \
  echo "[TAP]   (Host ARP setup failed, will use dynamic)"
echo "[TAP]   Host ARP: $GUEST_IP -> de:ad:be:ef:00:01"

# 验证 TAP 设备已创建
if /sbin/ip link show "$TAP_DEV" >/dev/null 2>&1; then
    echo "[TAP]   TAP device created OK"
    /sbin/ip addr show "$TAP_DEV" 2>/dev/null | head -5
else
    echo "WARNING: TAP device not yet visible, bridge may still be initializing..."
fi

# ========== 6. 等待并监控 ==========
echo ""
echo "[TAP] ============================================"
echo "[TAP]  TAP Bridge Integration Test"
echo "[TAP]  Guest: $GUEST_IP (QEMU + VCS/RoleA)"
echo "[TAP]  TAP:   $TAP_IP ($TAP_DEV, eth_tap_bridge/RoleB)"
echo "[TAP]  ETH SHM: $ETH_SHM"
echo "[TAP]  Timeout: ${TIMEOUT}s"
echo "[TAP] ============================================"
echo ""

# 等待 guest 完成 boot + ping 测试，同时尝试从 host ping guest
echo "[TAP] Waiting for guest to boot and run tests..."
sleep 30

# === Host -> Guest ping 测试 ===
echo ""
echo "[TAP] === Host -> Guest Ping Test ==="
echo "[TAP] Pinging $GUEST_IP from host (via TAP $TAP_DEV)..."
ping -c 5 -W 3 -I "$TAP_DEV" "$GUEST_IP" 2>&1 | tee "$LOGDIR/host_ping.log"
HOST_PING_RET=${PIPESTATUS[0]}

if [ $HOST_PING_RET -eq 0 ]; then
    echo "[TAP] HOST->GUEST Ping: PASS"
else
    echo "[TAP] HOST->GUEST Ping: FAIL (rc=$HOST_PING_RET)"
fi

# === 等待所有进程结束或超时 ===
echo ""
echo "[TAP] Waiting for all processes to finish (timeout: ${TIMEOUT}s)..."

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

if [ $SECONDS -ge $DEADLINE ]; then
    echo "[TAP] TIMEOUT reached (${TIMEOUT}s), stopping..."
fi

# ========== 7. 收集结果 ==========
echo ""
echo "[TAP] ========== TAP Bridge Test Results =========="

echo ""
echo "--- QEMU Guest ---"
grep -E "(TAP|Ping|PASS|FAIL|rx_|tx_|Configure|ARP|Loading|eth0|10\.0\.0)" "$LOGDIR/qemu.log" 2>/dev/null | tail -40

echo ""
echo "--- VCS (Role A) ---"
grep -E "(VQ-TX|VQ-RX|ETH|Forwarded|Injected|MAC)" "$LOGDIR/vcs.log" 2>/dev/null | tail -15

echo ""
echo "--- TAP Bridge ---"
cat "$LOGDIR/tap_bridge.log" 2>/dev/null | tail -20

echo ""
echo "--- Host Ping ---"
cat "$LOGDIR/host_ping.log" 2>/dev/null

echo ""
echo "--- QEMU Debug (MSI/DMA) ---"
grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu_debug.log" 2>/dev/null | tail -10

echo ""
echo "[TAP] Full logs: $LOGDIR/"
echo "[TAP] Done."
