#!/bin/bash
# setup_tap_61.sh — 在 10.11.10.61 上一次性建 TAP + 启 dnsmasq
#
# 需要 sudo。只需跑一次；之后 eth_tap_bridge 和 simv_vip 都能以普通 ryan 身份
# 使用 TAP cosim0（设备所有权传给 `user ryan`）。
#
# 拓扑（跨机联调）：
#   [53 QEMU]  Guest eth0 10.0.0.2  ── virtio-net
#                                       │
#                 QEMU cosim-pcie-rc ↔  TCP 9100 ↔  simv_vip (61)
#                                                     │
#                                                     ▼
#                                          ETH SHM /cosim_eth0
#                                                     │
#                                                     ▼
#                                           eth_tap_bridge (Role B)
#                                                     │
#                                                     ▼
#                                             TAP cosim0 10.0.0.1
#                                                     │
#                                                     ▼
#                                             dnsmasq (DHCP)
#
# 用法：
#   sudo bash ./scripts/setup_tap_61.sh [owner_user]
#
# owner_user 默认 = ryan

set -euo pipefail

OWNER="${1:-ryan}"
TAP_DEV="cosim0"
TAP_IP="10.0.0.1/24"
DHCP_RANGE="10.0.0.10,10.0.0.50,12h"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (sudo bash $0)"
    exit 1
fi

# --- TAP device ---
if ip link show "$TAP_DEV" &>/dev/null; then
    echo "[setup] $TAP_DEV already exists — reusing"
else
    echo "[setup] creating TAP $TAP_DEV owned by $OWNER"
    ip tuntap add dev "$TAP_DEV" mode tap user "$OWNER"
fi

ip addr flush dev "$TAP_DEV" 2>/dev/null || true
ip addr add "$TAP_IP" dev "$TAP_DEV"
ip link set "$TAP_DEV" up
echo "[setup] $TAP_DEV up with $TAP_IP"

# --- dnsmasq (DHCP server) ---
if pgrep -f "dnsmasq.*$TAP_DEV" >/dev/null; then
    echo "[setup] dnsmasq already bound to $TAP_DEV — reusing"
else
    # --bind-interfaces + --interface=$TAP_DEV 把 DHCP 限定在 cosim0，
    #   避免与宿主 eth0 DHCP 冲突。
    # --except-interface=lo 防止 localhost 泄露。
    # --leasefile-ro 避免 /var/lib/dnsmasq 写权限问题。
    echo "[setup] starting dnsmasq DHCP on $TAP_DEV range=$DHCP_RANGE"
    dnsmasq \
        --interface="$TAP_DEV" --bind-interfaces \
        --except-interface=lo \
        --dhcp-range="$DHCP_RANGE" \
        --dhcp-authoritative \
        --log-dhcp \
        --leasefile-ro \
        --pid-file=/tmp/dnsmasq_cosim0.pid \
        --log-facility=/tmp/dnsmasq_cosim0.log
fi

echo ""
echo "[setup] done. Summary:"
ip -br a show "$TAP_DEV"
echo "  DHCP log:    tail -f /tmp/dnsmasq_cosim0.log"
echo "  dnsmasq pid: $(cat /tmp/dnsmasq_cosim0.pid 2>/dev/null || echo n/a)"
echo ""
echo "Next steps (as user $OWNER):"
echo "  cd ~/cosim-platform"
echo "  ./tools/eth_tap_bridge -s /cosim_eth0 -t cosim0 &"
echo "  # then start simv_vip on 61 and QEMU on 53 as usual"
