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
- Guest kernel (bzImage) + rootfs（buildroot 或 initramfs）
- EDA 环境：VCS 机器需 `source ~/set-env.sh`

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
