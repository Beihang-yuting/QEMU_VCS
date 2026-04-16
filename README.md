# QEMU-VCS CoSim Platform

将 **QEMU**（虚拟化）与 **Synopsys VCS**（RTL 仿真）打通的软硬件协同仿真基础设施。
在 RTL 阶段即可以运行真实 Linux / 驱动对 DPU、智能网卡、加速器等 ASIC 做端到端验证。

---

## Features

- **PCIe MMIO 读写联合仿真**（TLP 级）
- **DMA 数据面**（设备 ↔ Host 双向）
- **MSI 中断注入**（VCS RTL → QEMU Guest）
- **双模式同步**：
  - 快速模式：事务级，~1000-10000 事务/秒，适合功能回归
  - 精确模式：周期级锁步，~10-100 事务/秒，适合时序调试
- **运行时模式切换** + **CSV / JSON 事务追踪日志**
- POSIX SHM + Unix Domain Socket 低开销 IPC

---

## Quick Start

### 1. 构建并跑全部测试

```bash
git clone https://github.com/Beihang-yuting/QEMU_VCS.git
cd QEMU_VCS
make test   # 需要 cmake >= 3.16, gcc >= 9, pthread/librt
```

预期输出：**17/17 测试通过**

| 类型 | 测试 |
|---|---|
| 单元（P1/P2/P3） | `test_ring_buffer`, `test_shm_layout`, `test_dma_manager`, `test_trace_log`, `test_eth_shm`, `test_link_model` |
| 集成 PCIe（P1/P2） | `test_sock_sync`, `test_bridge_loopback`, `test_dma_roundtrip`, `test_msi_roundtrip`, `test_precise_mode` |
| 集成 ETH（P3） | `test_eth_loopback`, `test_link_drop`, `test_mac_stub_e2e`, `test_time_sync_loose` |
| 工具（P4） | `test_cli_smoke`, `test_launch_smoke` |

### 2. 集成到 QEMU 源码树

```bash
export QEMU_SRC=./third_party/qemu        # 指向你的 QEMU 源码
./scripts/setup_cosim_qemu.sh $QEMU_SRC   # 自动复制 cosim_pcie_rc.{c,h}
cd $QEMU_SRC && ./configure --target-list=x86_64-softmmu --enable-kvm && make -j$(nproc)
```

### 3. 编译 VCS 侧

```bash
vcs -full64 -sverilog \
    -CFLAGS  "-I bridge/common -I bridge/vcs" \
    -LDFLAGS "-L build/bridge -lcosim_bridge_vcs -lrt -lpthread" \
    bridge/vcs/bridge_vcs.sv vcs-tb/*.sv -o simv
```

### 4. 启动联合仿真

```bash
# 终端 A：启 QEMU
export GUEST_KERNEL=/path/to/bzImage
./scripts/run_cosim.sh

# 终端 B：启 VCS
./simv +SHM_NAME=/cosim0 +SOCK_PATH=/tmp/cosim.sock
```

---

## Repository Layout

```
cosim-platform/
├── bridge/
│   ├── common/   # SHM、环形缓冲、DMA allocator、trace、eth_shm、link_model
│   ├── qemu/     # QEMU 侧 libcosim_bridge.so（PCIe 通路）
│   ├── vcs/      # VCS 侧 libcosim_bridge_vcs.so + bridge_vcs.sv
│   └── eth/      # ETH 通路：eth_port、mac_stub、eth_mac_dpi（P3）
├── qemu-plugin/  # 自定义 cosim-pcie-rc 设备（装入 QEMU 源码树）
├── vcs-tb/       # 最小 PCIe EP 测试平台
├── scripts/      # run_cosim, setup_cosim_qemu, cosim_cli, trace_analyzer,
│                 # launch_dual, gen_usage_doc
├── tests/        # 单元 + 集成测试（17 个 ctest）
└── docs/         # 使用说明 Word + GDB 调试指南
```

---

## Documentation

| 文档 | 路径 |
|---|---|
| **使用说明（Word）** | [docs/CoSim-Platform-Usage-Guide.docx](docs/CoSim-Platform-Usage-Guide.docx) |
| GDB 调试指南 | [docs/GDB-Debugging-Guide.md](docs/GDB-Debugging-Guide.md) |
| 架构 PPT | `../QEMU-VCS-CoSim-Platform-Design.pptx` |

---

## Project Status

| 阶段 | 范围 | 状态 |
|---|---|---|
| **P1** | 单节点 PCIe MMIO 通路、快速模式 | 已完成 |
| **P2** | DMA + MSI + 精确模式 + Trace | 已完成 |
| **P3** | 双节点 ETH 互打、链路模型（drop/burst/rate/FC）、launcher | 已完成 |
| **P4** | cosim_cli、trace_analyzer、GDB 文档、CI、smoke tests | 已完成 |

---

## License

暂未声明。如需外部使用请先联系维护者。

## Maintainer

**Beihang-yuting** &lt;2965455908@qq.com&gt;
