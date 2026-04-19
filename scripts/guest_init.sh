#!/bin/sh
# Custom init script for QEMU guest - Phase 2b: Virtio driver probe test
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo ""
echo "========================================="
echo " QEMU Guest - Virtio Driver Probe Test"
echo "========================================="
echo ""

echo "=== PCI Devices (from /sys) ==="
for dev in /sys/bus/pci/devices/*; do
  vendor=$(cat $dev/vendor 2>/dev/null)
  device=$(cat $dev/device 2>/dev/null)
  class=$(cat $dev/class 2>/dev/null)
  driver=""
  if [ -L "$dev/driver" ]; then
    driver=$(basename $(readlink $dev/driver))
  fi
  echo "  $(basename $dev): vendor=$vendor device=$device class=$class driver=$driver"
done

echo ""
echo "=== Looking for CoSim virtio-net device (1AF4:1041) ==="
FOUND=0
DEV_PATH=""
for dev in /sys/bus/pci/devices/*; do
  vendor=$(cat $dev/vendor 2>/dev/null)
  device=$(cat $dev/device 2>/dev/null)
  if [ "$vendor" = "0x1af4" ] && [ "$device" = "0x1041" ]; then
    echo "  FOUND at $(basename $dev)"
    echo "  Vendor: $vendor"
    echo "  Device: $device"
    echo "  Class:  $(cat $dev/class 2>/dev/null)"
    echo "  IRQ:    $(cat $dev/irq 2>/dev/null)"
    if [ -L "$dev/driver" ]; then
      echo "  Driver: $(basename $(readlink $dev/driver))"
    else
      echo "  Driver: (none bound)"
    fi
    DEV_PATH=$dev
    FOUND=1
    break
  fi
done

if [ $FOUND -eq 0 ]; then
  echo "  NOT FOUND"
fi

echo ""
echo "=== Kernel virtio messages (dmesg) ==="
dmesg 2>/dev/null | grep -i -E "virtio|1af4" | tail -30

echo ""
echo "=== Network interfaces ==="
ip link show 2>/dev/null || ls /sys/class/net/ 2>/dev/null

echo ""
echo "=== Virtio devices in /sys ==="
if [ -d /sys/bus/virtio/devices ]; then
  for vdev in /sys/bus/virtio/devices/*; do
    if [ -d "$vdev" ]; then
      echo "  $(basename $vdev):"
      [ -f "$vdev/vendor" ] && echo "    vendor=$(cat $vdev/vendor)"
      [ -f "$vdev/device" ] && echo "    device=$(cat $vdev/device)"
      [ -f "$vdev/status" ] && echo "    status=$(cat $vdev/status)"
      if [ -L "$vdev/driver" ]; then
        echo "    driver=$(basename $(readlink $vdev/driver))"
      fi
    fi
  done
else
  echo "  (no /sys/bus/virtio/devices)"
fi

echo ""
echo "=== PCI Config Space Test ==="
if [ -x /cfgspace_test ]; then
  /cfgspace_test 2>&1
else
  echo "  Skipped (/cfgspace_test not found)"
fi

echo ""
echo "=== Phase 3: Virtqueue TX Test ==="
# Bring up eth0 with an IP address to trigger TX traffic
if [ -d /sys/class/net/eth0 ]; then
  echo "  Configuring eth0..."
  ip addr add 10.0.0.2/24 dev eth0
  ip link set eth0 up
  sleep 1

  echo "  eth0 status:"
  ip addr show eth0

  echo ""
  echo "  Sending ARP probes (triggers TX virtqueue)..."
  # arping sends ARP requests which go through virtio-net TX path
  # Use raw socket approach since arping may not be available
  # Simply bringing up the interface + assigning IP triggers gratuitous ARP

  # Try ping to trigger TX (will timeout but packet should be sent)
  echo "  Sending 3 pings to 10.0.0.1 (expect no reply, testing TX path)..."
  ping -c 3 -W 1 10.0.0.1 2>&1 || true

  echo ""
  echo "  TX test done. Checking dmesg for virtio errors..."
  dmesg 2>/dev/null | grep -i -E "virtio|error|fail" | tail -10
else
  echo "  eth0 not found, skipping TX test"
fi

echo ""
echo "=== Test Complete ==="
echo "Shutting down..."
echo o > /proc/sysrq-trigger
