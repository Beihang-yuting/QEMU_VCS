#!/bin/bash
# TCP 模式双实例 iperf 测试
# QEMU1(server,10.0.0.1) + VCS1(RoleA) ←ETH_SHM→ VCS2(RoleB) + QEMU2(client,10.0.0.2)
# 两组 QEMU-VCS 各用独立 TCP 端口 (9100/9200)
set -euo pipefail

export VCS_HOME=/opt/synopsys/vcs/Q-2020.03-SP2-7
export VERDI_HOME=/opt/synopsys/verdi/R-2020.12-SP1
export PATH=$VCS_HOME/bin:$VERDI_HOME/bin:$PATH
export SNPSLMD_LICENSE_FILE=/opt/synopsys/license/license.dat
export LM_LICENSE_FILE=/opt/synopsys/license/license.dat

QEMU=~/workspace/qemu-9.2.0/build/qemu-system-x86_64
KERNEL=~/workspace/alpine-vmlinuz-new
INITRD=~/workspace/custom-initramfs-phase5.gz
SIMV=~/workspace/cosim-platform/vcs_sim/simv_vip
ETH_SHM=/cosim_eth_tcp_iperf
TIMEOUT=${1:-180}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOGDIR="${PROJECT_DIR}/logs/tcp_iperf_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"
echo "[TCP-IPERF] Logs: $LOGDIR/"

PIDS=()
cleanup() {
    echo ""
    echo "[TCP-IPERF] Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -f /dev/shm/"${ETH_SHM#/}" 2>/dev/null || true
    echo "[TCP-IPERF] Cleanup done"
}
trap cleanup EXIT INT TERM

# 清理旧资源
rm -f /dev/shm/"${ETH_SHM#/}" 2>/dev/null || true

# ===== 1. 启动 QEMU1 (Server) =====
echo "[TCP-IPERF] Starting QEMU1 (Server: 10.0.0.1, TCP port 9100)..."
$QEMU -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0 init=/init guest_ip=10.0.0.1 peer_ip=10.0.0.2 role=server wait_sec=60" \
    -device "cosim-pcie-rc,transport=tcp,port_base=9100" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu1_debug.log" \
    > "$LOGDIR/qemu1.log" 2>&1 &
PIDS+=($!)
echo "[TCP-IPERF]   QEMU1 PID: ${PIDS[-1]}"
sleep 2

# ===== 2. 启动 QEMU2 (Client) =====
echo "[TCP-IPERF] Starting QEMU2 (Client: 10.0.0.2, TCP port 9200)..."
$QEMU -M q35 -m 256M -smp 1 \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0 init=/init guest_ip=10.0.0.2 peer_ip=10.0.0.1 role=client wait_sec=60" \
    -device "cosim-pcie-rc,transport=tcp,port_base=9200" \
    -nographic -no-reboot \
    -d unimp -D "$LOGDIR/qemu2_debug.log" \
    > "$LOGDIR/qemu2.log" 2>&1 &
PIDS+=($!)
echo "[TCP-IPERF]   QEMU2 PID: ${PIDS[-1]}"
sleep 2

# ===== 3. 启动 VCS1 (Role A, 连 QEMU1) =====
echo "[TCP-IPERF] Starting VCS1 (RoleA, connect QEMU1:9100)..."
cd ~/workspace/cosim-platform
$SIMV \
    +transport=tcp +REMOTE_HOST=127.0.0.1 +PORT_BASE=9100 +INSTANCE_ID=0 \
    +ETH_SHM=$ETH_SHM +ETH_ROLE=0 +ETH_CREATE=1 \
    +MAC_LAST=1 \
    +SIM_TIMEOUT_MS=$((TIMEOUT * 1000)) \
    +UVM_TESTNAME=cosim_test +NO_WAVE \
    > "$LOGDIR/vcs1.log" 2>&1 &
PIDS+=($!)
echo "[TCP-IPERF]   VCS1 PID: ${PIDS[-1]}"
sleep 3

# ===== 4. 启动 VCS2 (Role B, 连 QEMU2) =====
echo "[TCP-IPERF] Starting VCS2 (RoleB, connect QEMU2:9200)..."
$SIMV \
    +transport=tcp +REMOTE_HOST=127.0.0.1 +PORT_BASE=9200 +INSTANCE_ID=0 \
    +ETH_SHM=$ETH_SHM +ETH_ROLE=1 +ETH_CREATE=0 \
    +MAC_LAST=2 \
    +SIM_TIMEOUT_MS=$((TIMEOUT * 1000)) \
    +UVM_TESTNAME=cosim_test +NO_WAVE \
    > "$LOGDIR/vcs2.log" 2>&1 &
PIDS+=($!)
echo "[TCP-IPERF]   VCS2 PID: ${PIDS[-1]}"

# ===== 5. 等待并监控 =====
echo ""
echo "[TCP-IPERF] ============================================"
echo "[TCP-IPERF]  TCP Mode iperf Test"
echo "[TCP-IPERF]  Server: 10.0.0.1 (QEMU1:9100 + VCS1/RoleA)"
echo "[TCP-IPERF]  Client: 10.0.0.2 (QEMU2:9200 + VCS2/RoleB)"
echo "[TCP-IPERF]  ETH SHM: $ETH_SHM"
echo "[TCP-IPERF]  Timeout: ${TIMEOUT}s"
echo "[TCP-IPERF] ============================================"
echo ""
echo "[TCP-IPERF] Waiting for test to complete..."

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
    sleep 2
done

# ===== 6. 收集结果 =====
echo ""
echo "[TCP-IPERF] ========== Results =========="

echo ""
echo "--- QEMU1 (Server: 10.0.0.1) ---"
grep -E "(eth0|iperf|PASS|FAIL|Received|Server|Mbits|bytes|error|probe|virtio)" "$LOGDIR/qemu1.log" 2>/dev/null | tail -30

echo ""
echo "--- QEMU2 (Client: 10.0.0.2) ---"
grep -E "(eth0|iperf|PASS|FAIL|Sending|Client|Mbits|bytes|error|probe|virtio)" "$LOGDIR/qemu2.log" 2>/dev/null | tail -30

echo ""
echo "--- VCS1 (Role A) ---"
grep -E "(VQ-TX|VQ-RX|ETH|TX notify|RX inject|packets)" "$LOGDIR/vcs1.log" 2>/dev/null | tail -15

echo ""
echo "--- VCS2 (Role B) ---"
grep -E "(VQ-TX|VQ-RX|ETH|TX notify|RX inject|packets)" "$LOGDIR/vcs2.log" 2>/dev/null | tail -15

echo ""
echo "[TCP-IPERF] Full logs: $LOGDIR/"
echo "[TCP-IPERF] Done."
