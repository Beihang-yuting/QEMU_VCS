#!/bin/sh
# Guest init script for TAP bridge test
# 单 QEMU guest 通过 VCS + ETH SHM + TAP bridge 与宿主机通信
# Guest IP: 10.0.0.2, TAP bridge IP: 10.0.0.1

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo ""
echo "========================================="
echo " QEMU Guest - TAP Bridge Test"
echo " Guest: 10.0.0.2  TAP: 10.0.0.1"
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

# === 配置网络 ===
echo ""
echo "=== Configure Network ==="
if [ -d /sys/class/net/eth0 ]; then
  ip addr add 10.0.0.2/24 dev eth0
  ip link set eth0 up
  sleep 1
  ip addr show eth0
else
  echo "eth0 not found!"
  echo o > /proc/sysrq-trigger
fi

# === 添加静态 ARP (TAP bridge MAC: de:ad:be:ef:00:02) ===
echo ""
echo "=== Setting static ARP ==="
ip neigh add 10.0.0.1 lladdr de:ad:be:ef:00:02 dev eth0 nud permanent 2>/dev/null || \
  arp -s 10.0.0.1 de:ad:be:ef:00:02 2>/dev/null || \
  echo "  (static ARP failed, will use dynamic)"
echo "  ARP: 10.0.0.1 -> de:ad:be:ef:00:02"

# === 等待 TAP bridge 就绪 ===
echo ""
echo "=== Waiting 15s for TAP bridge to be ready ==="
sleep 15

# === ARP 预解析 ===
echo ""
echo "=== ARP pre-resolution ==="
ping -c 1 -W 5 10.0.0.1 2>&1 || echo "  (pre-ping ARP, failure OK)"
sleep 2

# === Ping 测试: Guest -> TAP ===
echo ""
echo "=== TAP Bridge Ping Test: Guest (10.0.0.2) -> TAP (10.0.0.1) ==="
ping -c 5 -W 3 10.0.0.1 2>&1
PING_RET=$?

if [ $PING_RET -eq 0 ]; then
  echo "  PING Guest->TAP: PASS"
else
  echo "  PING Guest->TAP: FAIL (rc=$PING_RET)"
fi

# === 第二轮 ping (更多包，统计吞吐) ===
echo ""
echo "=== Extended Ping Test (20 packets) ==="
ping -c 20 -W 3 10.0.0.1 2>&1
PING2_RET=$?

if [ $PING2_RET -eq 0 ]; then
  echo "  PING Extended: PASS"
else
  echo "  PING Extended: FAIL (rc=$PING2_RET)"
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
echo "=== TAP Bridge Test Complete ==="
echo "Waiting 60s (host can ping guest during this time)..."
sleep 60
echo "Shutting down..."
echo o > /proc/sysrq-trigger
