# CoSim Platform Setup 使用指南

## 概述

CoSim Platform 支持两种部署模式：

| 模式 | 命令 | 通信方式 | 适用场景 |
|------|------|---------|---------|
| **local** | `./setup.sh --mode local` | POSIX SHM | 同机开发调试 |
| **qemu-only + vcs-only** | 分机执行 | TCP | 跨机联调、QEMU/VCS 在不同服务器 |

---

## 一、安装编译

### 1.1 Local 模式（同一台机器）

```bash
./setup.sh --mode local --guest minimal
```

编译组件：Bridge 库 + QEMU + VCS (VIP) + eth_tap_bridge + Guest initramfs

### 1.2 跨机模式

**QEMU 机器：**
```bash
./setup.sh --mode qemu-only --guest full
```
编译：Bridge 库 + QEMU + Guest 镜像

**VCS 机器：**
```bash
./setup.sh --mode vcs-only
```
编译：Bridge 库 + VCS (VIP) + eth_tap_bridge + setcap

### 1.3 交互式安装

无参数运行进入安装向导：
```bash
./setup.sh
```

---

## 二、Local 模式运行

### 2.1 自动编排测试

```bash
# 单 QEMU + VCS 基础测试
./cosim.sh test phase1     # Config Space
./cosim.sh test phase2     # MMIO + MSI/DMA
./cosim.sh test phase3     # Virtio-net TX

# 双 QEMU + VCS 网络测试
./cosim.sh test phase4     # 双向 Ping
./cosim.sh test phase5     # iperf 吞吐

# TAP 桥接
./cosim.sh test tap

# 全部
./cosim.sh test all
```

### 2.2 手动逐组件启动

```bash
# 终端 1: QEMU（基础模式，串口输出到终端）
./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock \
    --drive /path/to/rootfs.ext4

# 终端 2: VCS（默认开启波形 dump）
./cosim.sh start vcs --shm /cosim0 --sock /tmp/cosim0.sock --role A

# 终端 3: TAP bridge（如需网络测试）
./cosim.sh start tap --eth-shm /cosim_eth0
```

### 2.3 串口交互模式（推荐）

加 `--serial-sock` 可通过 Unix socket 与 Guest 串口交互，执行 ping/iperf 等测试：

```bash
# 终端 1: QEMU（串口通过 socket 输出）
./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock \
    --serial-sock /tmp/qemu-serial.sock \
    --drive /path/to/rootfs.ext4

# 终端 2: VCS
./cosim.sh start vcs --shm /cosim0 --sock /tmp/cosim0.sock --role A

# 终端 3: TAP bridge
./cosim.sh start tap --eth-shm /cosim_eth0

# 终端 4: 连接串口交互
python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/qemu-serial.sock')
s.settimeout(5)
# drain boot output
try:
    while True: s.recv(4096)
except: pass
# login
s.sendall(b'\n'); time.sleep(1); s.recv(4096)
s.sendall(b'root\n'); time.sleep(3); s.recv(4096)
# configure network
s.sendall(b'ip addr add 10.0.0.2/24 dev eth0\n'); time.sleep(3)
s.sendall(b'ip link set eth0 up\n'); time.sleep(3)
# ping test
s.sendall(b'ping -c 5 -W 600 10.0.0.1\n')
# read output...
"
```

> **提示：** TCP 跨机模式也支持 `--serial-sock`，操作方式完全相同。

### 2.4 波形查看

VCS 默认输出 `cosim_wave.fsdb`（Verdi 打开）：
```bash
# 关闭波形（提升仿真速度）
./cosim.sh start vcs ... +NO_WAVE

# 指定波形文件名
./cosim.sh start vcs ... +WAVE_FILE=my_test.fsdb
```

---

## 三、跨机 TCP 模式运行

### 3.1 启动顺序

**严格按此顺序，否则连接超时：**

```
1. QEMU (server, listen)  →  2. VCS (client, connect)  →  3. TAP bridge
```

### 3.2 QEMU 机器

```bash
# minimal guest（initramfs）
./cosim.sh start qemu --transport tcp --port-base 9100

# full guest（磁盘镜像）
./cosim.sh start qemu --transport tcp --port-base 9100 \
    --drive /path/to/rootfs.ext4
```

**提示：**
- QEMU 启动后阻塞等待 VCS 连接（端口 9100-9102），终端无输出是正常的
- 确认防火墙已放行 TCP 9100-9102
- instance_id=0 占用 port_base+0/+1/+2 三个端口

### 3.3 VCS 机器

```bash
# 启动 VCS
./cosim.sh start vcs --transport tcp --remote-host <QEMU机器IP> --port-base 9100

# 启动 TAP bridge
./cosim.sh start tap --eth-shm /cosim_eth0
```

**提示：**
- VCS connect 自动重试 15 秒
- eth_tap_bridge 需要 `CAP_NET_ADMIN`：
  ```bash
  sudo setcap cap_net_admin+ep tools/eth_tap_bridge
  ```

### 3.4 本机 TCP 测试

```bash
# 终端 1
./cosim.sh start qemu --transport tcp --port-base 9100
# 终端 2
./cosim.sh start vcs --transport tcp --remote-host 127.0.0.1 --port-base 9100
# 终端 3
./cosim.sh start tap --eth-shm /cosim_eth0
```

---

## 四、功能测试

### 4.1 交互式测试向导

```bash
./cosim.sh test-guide
```

提供 5 种测试：
1. **ping 连通性** — Guest ↔ TAP 双向验证
2. **iperf3 吞吐量** — TCP/UDP 性能测试
3. **arping ARP** — L2 层验证
4. **批量 ping 压力** — 200 包持续稳定性
5. **环境信息** — IP/MAC/配置汇总

### 4.2 Guest 网络配置（手动）

在 Guest 串口中执行：
```bash
ip addr add 10.0.0.2/24 dev eth0
ip link set eth0 up
arp -s 10.0.0.1 <TAP侧cosim0的MAC>    # ip link show cosim0 查看
ping -c 5 -W 600 10.0.0.1
```

### 4.3 监控命令

```bash
# 进程状态
./cosim.sh status

# 查看日志
./cosim.sh log all

# 构建信息
./cosim.sh info

# 清理所有资源
./cosim.sh clean
```

**VCS 侧监控：**
```bash
# VQ-TX 转发计数
grep -c 'VQ-TX.*Forwarded' /tmp/vcs_e2e.log

# RX 注入计数
grep -c 'VIP-VQ.*RX injected' /tmp/vcs_e2e.log

# TAP 收发统计
tail -1 /tmp/eth_tap_bridge.log
```

**QEMU 侧监控：**
```bash
grep -c 'DMA read OK' /tmp/qemu_e2e.log
grep -c 'DMA write OK' /tmp/qemu_e2e.log
grep -c 'MSI' /tmp/qemu_e2e.log
```

---

## 五、验证状态

| 测试项 | Local SHM | TCP 跨机 |
|--------|-----------|---------|
| PCIe TLP 交换 | ✅ 168+ CPL | ✅ 100K+ TLP |
| DMA read/write | ✅ 280 次 | ✅ 4319r/2197w |
| MSI 中断注入 | ✅ | ✅ 10万次 |
| VQ-TX → TAP | ✅ 47 包 | ✅ 1066 包 |
| 波形 dump (FSDB) | ✅ | ✅ |
| tag mismatch | 0 | 0 |
| DMA error | 0 | 0 |

---

## 六、前置依赖

### 编译依赖
- gcc/g++, cmake >= 3.16, python3 >= 3.8, meson, ninja
- glib >= 2.66（QEMU 需要，setup.sh 可自动从源码编译）
- VCS (Synopsys) + License

### 运行依赖
- Guest kernel + rootfs 存放在 `guest/images/`（setup.sh 可自动构建 buildroot）
  - `guest/images/bzImage` — 内核
  - `guest/images/rootfs.ext4` — 磁盘镜像
- EDA 环境：VCS 机器需 `source ~/set-env.sh`

### 目录结构
```
vcs_sim/          VCS 仿真产物（simv_vip + 波形 + 日志）
guest/images/     Guest 镜像（bzImage + rootfs.ext4）
logs/             测试运行日志
build/            Bridge CMake 产物
third_party/      QEMU / glib / buildroot 源码
```

### 网络配置
| 角色 | IP | MAC |
|------|-----|-----|
| Guest (eth0) | 10.0.0.2/24 | de:ad:be:ef:00:01 |
| TAP (cosim0) | 10.0.0.1/24 | 自动分配 |

---

## 七、常见问题

| 问题 | 解决 |
|------|------|
| `eth_tap_bridge: Operation not permitted` | `sudo setcap cap_net_admin+ep tools/eth_tap_bridge` |
| QEMU 启动后无输出 | TCP 模式正常——在等 VCS 连接 |
| VCS `Segmentation fault` | 确认 QEMU 版本匹配（含最新 bridge 代码） |
| Guest `eth0 not found` | 用 buildroot rootfs（含 virtio_net 驱动），非 Alpine initramfs |
| `tag mismatch` | 确认 bridge_qemu.c 含 stale cpl drain 循环 |
| 仿真速度慢 | 正常（RTL 仿真限制），ping 超时设 600s+ |

---

## 八、用户扩展指南

### 8.1 自定义 VCS Testbench

```bash
# 修改 EP 行为（寄存器/completion 逻辑）
vi vcs-tb/pcie_ep_stub.sv

# 修改 VIP 顶层（NOTIFY 处理/RX poll/波形 dump）
vi vcs-tb/cosim_vip_top.sv

# 修改 glue 信号转换
vi vcs-tb/glue_if_to_stub.sv

# 重编
make vcs-vip
```

### 8.2 新增 DPI-C 函数

1. 在 `bridge/vcs/bridge_vcs.c` 添加 C 函数
2. 在 `bridge/vcs/bridge_vcs.sv` 添加 `import "DPI-C"` 声明
3. 在 `vcs-tb/cosim_pkg.sv` 导入（`import cosim_bridge_pkg::your_func`）
4. 在 SV testbench 中调用
5. `make vcs-vip` 重编

### 8.3 新增 UVM 测试 Sequence

1. 在 `pcie_tl_vip/src/seq/` 下新建 sequence 文件
2. 在 `pcie_tl_vip/src/pcie_tl_pkg.sv` 中 include
3. 在 `vcs-tb/cosim_test.sv` 中引用或替换默认 sequence
4. `make vcs-vip` 重编

### 8.4 自定义 Guest

**方式 A：Buildroot（推荐）**
```bash
cd ~/workspace/buildroot
make menuconfig    # 启用 iperf3/netcat 等工具
make               # 产出 bzImage + rootfs.ext4
```

**方式 B：自定义 initramfs**
```bash
./scripts/build_guest_initramfs.sh phase4   # 构建特定变体
```

### 8.5 编译命令速查

| 命令 | 用途 |
|------|------|
| `make bridge` | 仅编译 Bridge 共享库 |
| `make vcs-vip` | 编译 VCS VIP 模式 (UVM + pcie_tl_vip) |
| `make vcs-vip-perf` | VIP + 性能统计 |
| `make test-unit` | 运行单元测试 |
| `make test-integration` | 运行集成测试 |
| `cmake -B build && cmake --build build` | CMake 编译 Bridge |
| `cd qemu/build && ninja` | 重编 QEMU |

### 8.6 Bridge C 文件说明

| 文件 | 用途 | 修改场景 |
|------|------|---------|
| `bridge/common/cosim_types.h` | TLP/CPL/DMA/MSI 数据结构 | 新增字段 |
| `bridge/common/cosim_transport.h` | 传输层抽象接口 | 新增传输方式 |
| `bridge/common/transport_tcp.c` | TCP transport 实现 | 修改 TCP 协议 |
| `bridge/common/transport_shm.c` | SHM transport 实现 | 修改 SHM 布局 |
| `bridge/common/ring_buffer.c` | 无锁环形缓冲区 | 调整队列大小 |
| `bridge/common/shm_layout.c` | SHM 内存布局（4MB） | 修改 SHM 结构 |
| `bridge/qemu/bridge_qemu.c` | QEMU 侧 bridge API | 修改 TLP 发送/completion 等待 |
| `bridge/qemu/irq_poller.c` | QEMU IRQ/DMA 轮询线程 | 修改 DMA/MSI 处理 |
| `bridge/vcs/bridge_vcs.c` | VCS 侧 DPI-C 函数 | 新增 DPI-C 接口 |
| `bridge/vcs/virtqueue_dma.c` | Virtqueue TX/RX DMA | 修改 virtio 数据面 |
| `bridge/eth/eth_port.c` | ETH SHM 读写 | 修改以太网处理 |
| `qemu-plugin/cosim_pcie_rc.c` | QEMU PCIe RC 设备 | 修改 MMIO/DMA/MSI 行为 |

---

## 九、调试

详细 GDB 调试指南参见 [GDB-Debugging-Guide.md](GDB-Debugging-Guide.md)。

### 快速调试技巧

```bash
# QEMU 侧日志监控
tail -f /tmp/qemu_e2e.log | grep -E "DMA|MSI|error"

# VCS 侧日志监控
tail -f /tmp/vcs_e2e.log | grep -E "VQ-TX|VQ-RX|NOTIFY|error"

# 波形调试
verdi -ssf cosim_wave.fsdb &    # 打开 Verdi 查看波形

# 进程状态
./cosim.sh status

# 清理环境
./cosim.sh clean
```
