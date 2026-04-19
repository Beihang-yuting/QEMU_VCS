#!/bin/sh
# Custom init script for QEMU guest - Phase 5: TCP/iperf Throughput Test
# Dual VCS mode: two guests connected via ETH SHM
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 从 kernel cmdline 读取配置
GUEST_IP="10.0.0.2"
PEER_IP=""
WAIT_SEC="25"
ROLE="client"   # server 或 client
for param in $(cat /proc/cmdline); do
  case "$param" in
    guest_ip=*) GUEST_IP="${param#guest_ip=}" ;;
    peer_ip=*)  PEER_IP="${param#peer_ip=}" ;;
    wait_sec=*) WAIT_SEC="${param#wait_sec=}" ;;
    role=*)     ROLE="${param#role=}" ;;
  esac
done

echo ""
echo "========================================="
echo " QEMU Guest - Phase 5: TCP/iperf Test"
echo " IP=$GUEST_IP  Peer=$PEER_IP  Role=$ROLE"
echo "========================================="
echo ""

# === 加载 virtio_net ===
echo "=== Loading virtio_net module ==="
KVER=$(uname -r)
KMOD="/lib/modules/$KVER/kernel"
FAILOVER="$KMOD/net/core/failover.ko"
NET_FAILOVER="$KMOD/drivers/net/net_failover.ko"
VIRTIO_NET="$KMOD/drivers/net/virtio_net.ko"

if [ -f "$VIRTIO_NET" ]; then
  [ -f "$FAILOVER" ] && insmod "$FAILOVER" 2>/dev/null
  [ -f "$NET_FAILOVER" ] && insmod "$NET_FAILOVER" 2>/dev/null
  insmod "$VIRTIO_NET" 2>/dev/null
  echo "Module load done (kernel $KVER)"
else
  echo "virtio_net.ko not found, may be built-in"
fi

# === 调整 TCP 内核参数（降低超时敏感度）===
echo "=== Tuning TCP parameters ==="
echo 3  > /proc/sys/net/ipv4/tcp_syn_retries       2>/dev/null
echo 5  > /proc/sys/net/ipv4/tcp_synack_retries     2>/dev/null
echo 15 > /proc/sys/net/ipv4/tcp_retries2            2>/dev/null
echo 0  > /proc/sys/net/ipv4/tcp_timestamps          2>/dev/null
echo 0  > /proc/sys/net/ipv4/tcp_sack                2>/dev/null
echo 1  > /proc/sys/net/ipv4/tcp_no_metrics_save     2>/dev/null
echo 30 > /proc/sys/net/ipv4/tcp_fin_timeout         2>/dev/null
echo 60 > /proc/sys/net/ipv4/tcp_keepalive_time      2>/dev/null
echo 10 > /proc/sys/net/ipv4/tcp_keepalive_intvl     2>/dev/null
echo 5  > /proc/sys/net/ipv4/tcp_keepalive_probes    2>/dev/null
echo "  TCP params tuned"

# === 配置网络 ===
echo ""
echo "=== Configure Network ==="
if [ -d /sys/class/net/eth0 ]; then
  ip addr add $GUEST_IP/24 dev eth0
  ip link set eth0 up
  sleep 1
  ip addr show eth0
else
  echo "eth0 not found!"
  echo o > /proc/sysrq-trigger
fi

# === 添加静态 ARP 条目（防止 ARP 过期导致连接失败）===
echo ""
echo "=== Setting static ARP ==="
if [ "$ROLE" = "server" ]; then
  # Server (10.0.0.1) -> peer is Client (10.0.0.2, MAC 02)
  PEER_MAC="de:ad:be:ef:00:02"
else
  # Client (10.0.0.2) -> peer is Server (10.0.0.1, MAC 01)
  PEER_MAC="de:ad:be:ef:00:01"
fi
ip neigh add $PEER_IP lladdr $PEER_MAC dev eth0 nud permanent 2>/dev/null || \
  arp -s $PEER_IP $PEER_MAC 2>/dev/null || \
  echo "  (static ARP failed, will use dynamic)"
echo "  ARP: $PEER_IP -> $PEER_MAC"

# === 等待对端就绪 ===
echo ""
echo "=== Waiting for peer (${WAIT_SEC}s) ==="
sleep $WAIT_SEC

# === ARP 预解析 ===
echo ""
echo "=== ARP pre-resolution ==="
ping -c 1 -W 5 $PEER_IP 2>&1 || echo "  (pre-ping ARP, failure OK)"
sleep 2

# === Ping 验证 ===
echo ""
echo "=== Quick Ping Check ==="
ping -c 2 -W 3 $PEER_IP 2>&1
PING_OK=$?

if [ $PING_OK -ne 0 ]; then
  echo "ERROR: Ping failed, skipping TCP/iperf tests"
  echo "=== RX/TX stats ==="
  echo "  rx_packets=$(cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null)"
  echo "  tx_packets=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null)"
  sleep 30
  echo o > /proc/sysrq-trigger
fi

echo ""
echo "=== Phase 5: TCP Test (nc) ==="

if [ "$ROLE" = "server" ]; then
  # ---- Server side ----
  echo "  [Server] Starting nc listener on port 5000..."
  nc -l -p 5000 > /tmp/received 2>&1 &
  NC_PID=$!
  echo "  [Server] nc PID=$NC_PID, waiting for client..."

  # Wait for client to send data (max 15s)
  for i in $(seq 1 15); do
    if ! kill -0 $NC_PID 2>/dev/null; then
      break
    fi
    sleep 1
  done
  kill $NC_PID 2>/dev/null
  wait $NC_PID 2>/dev/null

  RECV_SIZE=$(wc -c < /tmp/received 2>/dev/null || echo 0)
  echo "  [Server] Received: $RECV_SIZE bytes"
  if [ "$RECV_SIZE" -gt 0 ]; then
    echo "  [Server] TCP receive: PASS"
    echo "  [Server] First 32 bytes (hex):"
    dd if=/tmp/received bs=1 count=32 2>/dev/null | od -A x -t x1 | head -3
  else
    echo "  [Server] TCP receive: FAIL (0 bytes)"
  fi

else
  # ---- Client side ----
  echo "  [Client] Waiting 5s for server to start..."
  sleep 5

  echo "  [Client] Generating 1KB test data..."
  dd if=/dev/urandom of=/tmp/testdata bs=1024 count=1 2>/dev/null

  echo "  [Client] Sending via nc to $PEER_IP:5000..."
  T_START=$(cat /proc/uptime | cut -d' ' -f1)
  nc -w 3 $PEER_IP 5000 < /tmp/testdata 2>&1
  NC_RET=$?
  T_END=$(cat /proc/uptime | cut -d' ' -f1)

  if [ $NC_RET -eq 0 ]; then
    echo "  [Client] TCP send: PASS"
    echo "  [Client] Transfer time: ${T_START}s -> ${T_END}s"
  else
    echo "  [Client] TCP send: FAIL (rc=$NC_RET)"
  fi
fi

# === nc 多轮递增数据传输测试 ===
# 先做 nc 批量测试（可靠），再做 iperf3（实验性）
echo ""
echo "=== Phase 5: nc Multi-round Transfer Test ==="

# 刷新 ARP
echo "  Refreshing ARP..."
ping -c 1 -W 3 $PEER_IP 2>&1 || echo "  (ARP refresh, failure OK)"
sleep 3

# 测试不同大小: 512B, 1KB, 2KB, 4KB
SIZES="512 1024 2048 4096"

if [ "$ROLE" = "server" ]; then
  PORT=5010
  for SZ in $SIZES; do
    echo "  [Server] Listening port $PORT for ${SZ}B transfer..."
    nc -l -p $PORT > /tmp/recv_${SZ} 2>&1 &
    NC_PID=$!
    # 等待客户端 (max 40s per round)
    for i in $(seq 1 40); do
      if ! kill -0 $NC_PID 2>/dev/null; then break; fi
      sleep 1
    done
    kill $NC_PID 2>/dev/null
    wait $NC_PID 2>/dev/null

    RECV_SZ=$(wc -c < /tmp/recv_${SZ} 2>/dev/null || echo 0)
    if [ "$RECV_SZ" -eq "$SZ" ]; then
      echo "  [Server] ${SZ}B: PASS (received $RECV_SZ bytes)"
    elif [ "$RECV_SZ" -gt 0 ]; then
      echo "  [Server] ${SZ}B: PARTIAL (received $RECV_SZ / $SZ bytes)"
    else
      echo "  [Server] ${SZ}B: FAIL (received 0 bytes)"
    fi
    PORT=$((PORT + 1))
    # ARP 刷新
    ping -c 1 -W 3 $PEER_IP 2>&1 > /dev/null || true
    sleep 2
  done

else
  PORT=5010
  for SZ in $SIZES; do
    # 等待服务端启动 listener
    echo "  [Client] Waiting 5s for server on port $PORT..."
    sleep 5

    # ARP 刷新
    ping -c 1 -W 3 $PEER_IP 2>&1 > /dev/null || true
    sleep 2

    dd if=/dev/urandom of=/tmp/send_${SZ} bs=$SZ count=1 2>/dev/null
    echo "  [Client] Sending ${SZ}B to $PEER_IP:$PORT..."
    T_START=$(cat /proc/uptime | cut -d' ' -f1)
    nc -w 15 $PEER_IP $PORT < /tmp/send_${SZ} 2>&1
    NC_RET=$?
    T_END=$(cat /proc/uptime | cut -d' ' -f1)

    if [ $NC_RET -eq 0 ]; then
      echo "  [Client] ${SZ}B send: PASS (time: ${T_START}s -> ${T_END}s)"
    else
      echo "  [Client] ${SZ}B send: FAIL (rc=$NC_RET)"
    fi
    PORT=$((PORT + 1))
    sleep 2
  done
fi

# === iperf3 测试 (带超时调优) ===
echo ""
echo "=== Phase 5: iperf3 Test (with timeout tuning) ==="

# 刷新 ARP
echo "  Refreshing ARP before iperf3..."
ping -c 1 -W 3 $PEER_IP 2>&1 || echo "  (ARP refresh, failure OK)"
sleep 3

if [ -x /usr/bin/iperf3 ]; then
  if [ "$ROLE" = "server" ]; then
    echo "  [Server] Starting iperf3 server (rcv-timeout=30s, idle-timeout=60s)..."
    iperf3 -s -1 -4 -p 5201 \
      --idle-timeout 60 \
      --rcv-timeout 30000 \
      2>&1 &
    IPERF_PID=$!
    echo "  [Server] iperf3 PID=$IPERF_PID"

    # Wait for iperf to finish (max 45s)
    for i in $(seq 1 45); do
      if ! kill -0 $IPERF_PID 2>/dev/null; then break; fi
      sleep 1
    done
    kill $IPERF_PID 2>/dev/null
    echo "  [Server] iperf3 done"

  else
    # Client 等待 5s
    echo "  [Client] Waiting 5s for iperf3 server..."
    sleep 5

    echo "  [Client] Pre-iperf3 connectivity check..."
    ping -c 1 -W 5 $PEER_IP 2>&1 || echo "  (pre-iperf3 ping failed)"

    echo "  [Client] Running iperf3 to $PEER_IP..."
    iperf3 -c $PEER_IP -4 -p 5201 -t 3 -i 1 \
      --connect-timeout 30000 \
      --snd-timeout 30000 \
      2>&1
    IPERF_RET=$?

    if [ $IPERF_RET -eq 0 ]; then
      echo "  [Client] iperf3: PASS"
    else
      echo "  [Client] iperf3: FAIL (rc=$IPERF_RET)"
    fi
  fi
else
  echo "  iperf3 not found, skipping"
fi

# === 最终统计 ===
echo ""
echo "=== Final RX/TX stats ==="
echo "  rx_packets=$(cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null)"
echo "  tx_packets=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null)"
echo "  rx_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null)"
echo "  tx_bytes=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null)"
echo "  rx_errors=$(cat /sys/class/net/eth0/statistics/rx_errors 2>/dev/null)"
echo "  tx_errors=$(cat /sys/class/net/eth0/statistics/tx_errors 2>/dev/null)"
echo "  rx_dropped=$(cat /sys/class/net/eth0/statistics/rx_dropped 2>/dev/null)"
echo "  tx_dropped=$(cat /sys/class/net/eth0/statistics/tx_dropped 2>/dev/null)"

echo ""
echo "=== Phase 5 Test Complete ==="
echo "Waiting 90s for peer to finish tests..."
sleep 90
echo "Shutting down..."
echo o > /proc/sysrq-trigger
