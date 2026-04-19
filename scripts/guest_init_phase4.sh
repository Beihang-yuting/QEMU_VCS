#!/bin/sh
# Custom init script for QEMU guest - Phase 4: Bidirectional Network Test
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 从 kernel cmdline 读取配置（支持双 VCS 模式）
# 用法: -append "... guest_ip=10.0.0.2 peer_ip=$PEER_IP wait_sec=10"
GUEST_IP="10.0.0.2"
PEER_IP="$PEER_IP"
WAIT_SEC="20"
for param in $(cat /proc/cmdline); do
  case "$param" in
    guest_ip=*) GUEST_IP="${param#guest_ip=}" ;;
    peer_ip=*)  PEER_IP="${param#peer_ip=}" ;;
    wait_sec=*) WAIT_SEC="${param#wait_sec=}" ;;
  esac
done

echo ""
echo "========================================="
echo " QEMU Guest - Phase 4: Full Network Test"
echo " IP=$GUEST_IP  Peer=$PEER_IP"
echo "========================================="
echo ""

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

echo ""
echo "=== PCI Devices ==="
for dev in /sys/bus/pci/devices/*; do
  vendor=$(cat $dev/vendor 2>/dev/null)
  device=$(cat $dev/device 2>/dev/null)
  driver=""
  if [ -L "$dev/driver" ]; then
    driver=$(basename $(readlink $dev/driver))
  fi
  echo "  $(basename $dev): vendor=$vendor device=$device driver=$driver"
done

echo ""
echo "=== Network interfaces ==="
ip link show 2>/dev/null

echo ""
echo "=== Phase 4: Configure Network ==="
if [ -d /sys/class/net/eth0 ]; then
  echo "  Configuring eth0 with $GUEST_IP/24..."
  ip addr add $GUEST_IP/24 dev eth0
  ip link set eth0 up
  sleep 1
  ip addr show eth0
else
  echo "  eth0 not found!"
  echo o > /proc/sysrq-trigger
fi

echo ""
echo "=== Phase 4: Waiting for peer (${WAIT_SEC}s) ==="
sleep $WAIT_SEC

echo ""
echo "=== Phase 4: Pre-ping stats ==="
echo "  rx_packets=$(cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null)"
echo "  tx_packets=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null)"
echo "  rx_errors=$(cat /sys/class/net/eth0/statistics/rx_errors 2>/dev/null)"
echo "  rx_dropped=$(cat /sys/class/net/eth0/statistics/rx_dropped 2>/dev/null)"
echo "  rx_frame_errors=$(cat /sys/class/net/eth0/statistics/rx_frame_errors 2>/dev/null)"
echo "  rx_length_errors=$(cat /sys/class/net/eth0/statistics/rx_length_errors 2>/dev/null)"
echo "  interrupts:"
grep -i virtio /proc/interrupts 2>/dev/null || grep eth /proc/interrupts 2>/dev/null || cat /proc/interrupts 2>/dev/null | head -5

echo ""
echo "=== Phase 4: Pre-ping ARP resolution ==="
# Send ARP request to peer to pre-populate ARP cache on both sides
# This ensures both guests know each other's MAC before ping starts
arping -c 2 -w 5 -I eth0 $PEER_IP 2>&1 || echo "  arping not available, using ping instead"
ping -c 1 -W 5 $PEER_IP 2>&1 || echo "  (pre-ping ARP probe, failure OK)"
sleep 2

echo ""
echo "=== Phase 4: ARP table ==="
cat /proc/net/arp 2>/dev/null

echo ""
echo "=== Phase 4: Ping Test ($PEER_IP) ==="
echo "  Sending 3 pings..."
ping -c 3 -W 5 $PEER_IP 2>&1

echo ""
echo "=== Phase 4: ARP table after ping ==="
cat /proc/net/arp 2>/dev/null

echo ""
echo "=== Phase 4: Post-ping interrupts ==="
grep -i virtio /proc/interrupts 2>/dev/null || grep eth /proc/interrupts 2>/dev/null || echo "  (no virtio/eth interrupts found)"
cat /proc/interrupts 2>/dev/null | head -10

echo ""
echo "=== dmesg (IRQ/interrupt related) ==="
dmesg 2>/dev/null | grep -i -E "irq|interrupt|ioapic|apic|intx|msi" | tail -10

echo ""
echo "=== dmesg (virtio/net related) ==="
dmesg 2>/dev/null | grep -i -E "virtio|1af4|eth0|net" | tail -20

echo ""
echo "=== PCI device IRQ info ==="
for dev in /sys/bus/pci/devices/*; do
  irq=$(cat $dev/irq 2>/dev/null)
  driver=""
  if [ -L "$dev/driver" ]; then
    driver=$(basename $(readlink $dev/driver))
  fi
  if [ -n "$driver" ]; then
    echo "  $(basename $dev): irq=$irq driver=$driver"
  fi
done

echo ""
echo "=== RX/TX stats ==="
cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null && echo " rx_packets"
cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null && echo " tx_packets"
cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null && echo " rx_bytes"
cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null && echo " tx_bytes"
cat /sys/class/net/eth0/statistics/rx_errors 2>/dev/null && echo " rx_errors"
cat /sys/class/net/eth0/statistics/tx_errors 2>/dev/null && echo " tx_errors"

echo ""
echo "=== Phase 4 Test Complete ==="
echo "Waiting 30s for peer to finish tests..."
sleep 30
echo "Shutting down..."
echo o > /proc/sysrq-trigger
