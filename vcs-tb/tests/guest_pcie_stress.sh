#!/bin/bash
# guest_pcie_stress.sh - QEMU Guest 内 PCIe 事务覆盖测试
# 在 Guest 内运行，系统性触发所有 PCIe 事务类型
set -euo pipefail

echo "=== CoSim PCIe VIP 集成测试 ==="
echo "Phase 1: 枚举 (CfgRd/CfgWr)"
echo "==============================="

# 1. PCIe 枚举
lspci -vvv 2>/dev/null || echo "lspci not available"
setpci -s 00:04.0 COMMAND 2>/dev/null || echo "setpci not available"
setpci -s 00:04.0 COMMAND=0x0006 2>/dev/null || true

echo ""
echo "Phase 2: MMIO 读写 (MRd/MWr)"
echo "==============================="

# 2. MMIO 读写 (不同大小)
if command -v devmem2 &>/dev/null; then
    devmem2 0xfe000000 b 2>/dev/null || true
    devmem2 0xfe000000 h 2>/dev/null || true
    devmem2 0xfe000000 w 2>/dev/null || true
    devmem2 0xfe000004 w 0xdeadbeef 2>/dev/null || true
    devmem2 0xfe000004 w 2>/dev/null || true
else
    echo "devmem2 not available, using /dev/mem directly"
fi

echo ""
echo "Phase 3: BAR 空间遍历"
echo "======================"

# 3. BAR 遍历
if command -v devmem2 &>/dev/null; then
    for offset in $(seq 0 4 60); do
        devmem2 $((0xfe000000 + offset)) w 2>/dev/null || true
    done
fi

echo ""
echo "Phase 4: DMA 传输"
echo "=================="

# 4. DMA
if modprobe cosim_nic 2>/dev/null; then
    ip link set eth1 up 2>/dev/null || true
    ping -c 3 -s 64 10.0.0.2 2>/dev/null || echo "ping small failed"
    ping -c 3 -s 4000 10.0.0.2 2>/dev/null || echo "ping large failed"
fi

echo ""
echo "Phase 5: 中断测试"
echo "=================="

# 5. 中断
cat /proc/interrupts | grep -i cosim 2>/dev/null || echo "No cosim interrupts found"

echo ""
echo "Phase 6: 压力测试 (小包风暴)"
echo "=============================="

# 6. 小包风暴
if command -v devmem2 &>/dev/null; then
    for i in $(seq 1 1000); do
        devmem2 0xfe000000 w 0x$((RANDOM % 65536)) 2>/dev/null || true
    done
    echo "Completed 1000 MMIO writes"
fi

echo ""
echo "=== 测试完成 ==="
