# CoSim Platform 使用指南

## 1. 概述

CoSim Platform 是 QEMU-VCS 协仿平台，Guest Linux 的 virtio-net 驱动通过 PCIe TLP 与 VCS RTL 仿真交互。

### 1.1 部署模式

| 模式 | setup 命令 | 通信方式 | 适用场景 |
|------|-----------|---------|---------|
| **local** | `./setup.sh --mode local` | SHM / TCP | 同机开发调试 |
| **qemu-only** | `./setup.sh --mode qemu-only` | TCP | QEMU 在 A 机，VCS 在 B 机 |
| **vcs-only** | 不需要 setup | - | VCS 机器上手动 `make vcs-vip` |

### 1.2 架构

```
+-- QEMU 机 -----------------------+     +-- VCS 机 ----------------------------+
|                                   |     |                                      |
|  Guest Linux (virtio-net)         |     |  simv_vip (UVM + PCIe TL VIP)       |
|       |                           |     |     +-- pcie_ep_stub                 |
|  cosim-pcie-rc (QEMU 设备)        |     |     +-- virtqueue_dma.c             |
|       |                           |     |          |                           |
|       +-- Bridge (QEMU 侧)       |     |     ETH SHM (/cosim_eth_dual)       |
|            |                      |     |       +-- VCS1 (RoleA) <-> VCS2     |
|            |  SHM: /dev/shm +     |     |       +-- eth_tap_bridge (TAP)      |
|            |       Unix socket    |     |                                      |
|            |  TCP: 3 连接         |     |  Bridge (VCS 侧, DPI-C)             |
|            +----------------------+-----+--------------------------------------+
|                                   |     |
|  端口: BASE+ID*3 ~ BASE+ID*3+2   |     |  连接: REMOTE_HOST:PORT_BASE
+-----------------------------------+     +--------------------------------------+
```

### 1.3 运行模式

| 运行模式 | 组件 | 用途 | Makefile 目标 |
|---------|------|------|--------------|
| 单实例 | 1xQEMU + 1xVCS | 基本功能验证 | `run-qemu` + `run-vcs` |
| 双实例对打 | 2xQEMU + 2xVCS + ETH SHM | Guest<->Guest 网络 | `run-dual` |
| TAP 桥接 | 1xQEMU + 1xVCS + TAP | Guest<->主机网络 | `run-qemu` + `run-vcs` + `run-tap` |

---

## 2. 安装

### 2.1 QEMU 机器

```bash
# Alpine (推荐，轻量快速)
./setup.sh --mode local --guest alpine
# Debian (完整工具链，支持 Guest 内编译驱动)
./setup.sh --mode local --guest debian
# 或跨机:
./setup.sh --mode qemu-only --guest alpine
```

编译产出: Bridge 库 + QEMU (含 cosim-pcie-rc) + Guest 根文件系统镜像

### 2.2 VCS 机器 (手动编译)

```bash
source ~/set-env.sh           # 加载 VCS/Verdi 环境变量
make vcs-vip                  # 产出 vcs_sim/simv_vip
```

### 2.3 环境检查

```bash
make info                     # 显示所有路径和状态
make help                     # 完整命令列表
```

---

## 3. 运行

所有运行命令通过 `make` 执行, 参数通过 `KEY=VALUE` 传入.

### 3.1 单实例 -- SHM 模式 (同机, 2 个终端)

```bash
# 终端 1: QEMU (阻塞等待 VCS, Ctrl+C 可退出)
make run-qemu

# 调试模式 (显示详细日志)
make run-qemu VERBOSE=1

# 终端 2: VCS (连接后双方开始运行)
make run-vcs
```

Guest 启动后登录 (root / 123):

```bash
cosim-start                    # 配网 (默认 10.0.0.2)
ping -c 1 10.0.0.1             # 测试连通 (cosim 下每包需数分钟)
cosim-stop                     # 停止仿真并退出
```

### 3.2 单实例 -- TCP 模式 (可跨机, 2 个终端)

```bash
# 终端 1: QEMU 机器 (监听 9100-9102)
make run-qemu TRANSPORT=tcp

# 终端 2: VCS 机器 (连接 QEMU)
make run-vcs TRANSPORT=tcp REMOTE_HOST=<QEMU机器IP>
```

### 3.3 双实例对打

自动启动 2xQEMU + 2xVCS, Guest1(10.0.0.1) <-> Guest2(10.0.0.2):

```bash
make run-dual                          # SHM 模式
make run-dual TRANSPORT=tcp            # TCP 模式
```

拓扑:

```
Guest1 (10.0.0.1)                              Guest2 (10.0.0.2)
  virtio-net                                      virtio-net
     |                                               |
  QEMU1 (instance_id=0)                          QEMU2 (instance_id=1)
     | PCIe TLP                                     | PCIe TLP
  VCS1 (RoleA, MAC=01)  --- ETH SHM ---  VCS2 (RoleB, MAC=02)
```

手动启动 (4 个终端):

```bash
# 终端 1: QEMU1
make run-qemu TRANSPORT=tcp GUEST_IP=10.0.0.1 PEER_IP=10.0.0.2 ROLE=server

# 终端 2: QEMU2
make run-qemu TRANSPORT=tcp INSTANCE_ID=1 GUEST_IP=10.0.0.2 PEER_IP=10.0.0.1 ROLE=client

# 终端 3: VCS1
make run-vcs TRANSPORT=tcp MAC_LAST=1 ETH_ROLE=0 ETH_CREATE=1

# 终端 4: VCS2
make run-vcs TRANSPORT=tcp INSTANCE_ID=1 MAC_LAST=2 ETH_ROLE=1 ETH_CREATE=0
```

### 3.4 TAP 桥接 (Guest <-> 主机网络)

需要 `CAP_NET_ADMIN` 权限:

```bash
# 首次 (管理员执行一次)
make tap-bridge                       # 编译 eth_tap_bridge
sudo setcap cap_net_admin+ep tools/eth_tap_bridge
getcap tools/eth_tap_bridge           # 验证: 应显示 cap_net_admin=ep
```

启动 (3 个终端, 按顺序):

```bash
# 终端 1: QEMU (先启动, 等待 VCS 连接)
make run-qemu

# 终端 2: VCS (连接 QEMU, 同时创建 ETH SHM)
make run-vcs

# 终端 3: TAP bridge (VCS 创建 SHM 后才能启动)
sudo make run-tap
```

网络拓扑:

```
Host 机器
├── eth0 (物理网卡, 连内网)
├── cosim0 (TAP 虚拟网卡, IP=10.0.0.1)
│       ↕ ETH SHM (/cosim_eth0)
│   VCS RTL 仿真
│       ↕ PCIe TLP (SHM 或 TCP)
│   QEMU cosim-pcie-rc
│       ↕
└── Guest eth0 (virtio_net, IP=10.0.0.2)
```

Guest 登录后:

```bash
cosim-start                           # 配网 (默认 10.0.0.2)
ping -c 1 10.0.0.1                    # ping Host TAP
```

Host 侧 iperf 测试:

```bash
# Host 上新开一个终端
iperf3 -s                             # 监听所有网卡 (含 cosim0)
iperf3 -s -B 10.0.0.1                 # 只监听 TAP 地址

# Guest 内
iperf3 -c 10.0.0.1 -t 1              # 吞吐量测试
```

> **注意**: cosim 环境下每个网络包都经过 VCS RTL 仿真, 一次 ping 往返可能需要数分钟。
> 建议使用 `ping -c 1` 发单包验证连通性。

### 3.5 参数列表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `TRANSPORT` | `shm` | `shm` 或 `tcp` |
| `PORT_BASE` | `9100` | TCP 端口基数 |
| `INSTANCE_ID` | `0` | 实例 ID (端口 = BASE + ID x 3) |
| `REMOTE_HOST` | `127.0.0.1` | VCS 连接目标 |
| `GUEST_IP` | `10.0.0.2` | Guest IP (TAP Host 为 10.0.0.1) |
| `PEER_IP` | `10.0.0.1` | 对端 IP |
| `MAC_LAST` | `1` | MAC 末字节 (de:ad:be:ef:00:0N) |
| `ETH_SHM` | `/cosim_eth0` | ETH 共享内存名 (单实例 + TAP 共用) |
| `ETH_ROLE` | `0` | 0=创建 SHM, 1=加入 |
| `SIM_TIMEOUT` | `600000` | VCS 超时 (ms) |
| `VERBOSE` | `0` | 0=安静, 1=详细日志 + debug 打印 |
| `QEMU` / `SIMV` / `KERNEL` / `ROOTFS` | 自动发现 | 路径覆盖 |

**IP 地址分配 (10.0.0.0/24):**

| 角色 | IP | 说明 |
|------|-----|------|
| TAP Host 侧 | `10.0.0.1` | `make run-tap` 自动配置 |
| Guest 侧 | `10.0.0.2` | `cosim-start` 默认值 |
| 双实例 Guest1 | `10.0.0.1` | `run-dual` 自动分配 |
| 双实例 Guest2 | `10.0.0.2` | `run-dual` 自动分配 |
| 自定义 | 任意 | `cosim-start <IP>` 指定 |

---

## 4. 测试工具与触发原理

### 4.1 ping -- ICMP 连通性

```bash
# Guest 内执行
ping -c 3 -W 5 10.0.0.2
```

**完整数据路径 (26 步):**

```
Guest 执行 ping 10.0.0.2
    |
    v Linux 网络栈
 1. ICMP 构造 echo request
 2. IP 层: src=10.0.0.1 dst=10.0.0.2 proto=ICMP
 3. ARP 查 MAC (若无缓存先发 ARP request)
 4. 以太网帧: dst=DE:AD:BE:EF:00:02 type=0x0800
    |
    v virtio-net 驱动
 5. 帧写入 TX virtqueue descriptor (GPA 地址)
 6. 更新 avail ring idx
 7. 写 NOTIFY doorbell: writew(1, BAR0+0x2000)
    |
    v QEMU cosim-pcie-rc
 8. cosim_mmio_write() 触发
 9. 构造 MWr TLP: addr=BAR+0x2000, first_be=0x3
10. bridge_send_tlp_fire() -> SHM/TCP -> VCS
    |
    v VCS cosim_vip_top
11. cosim_rc_driver 收到 MWr -> glue -> EP stub
12. EP stub NOTIFY addr=0x2000 -> notify_valid=1, queue=1
13. handle_vio_notify(1) -> vcs_vq_process_tx():
    a. DMA read avail ring -> desc index
    b. DMA read descriptor -> 帧 GPA + length
    c. DMA read 帧数据 (98 bytes)
    d. DMA write used ring
    e. eth_mac_send_frame() -> ETH SHM
    |
    v ETH SHM (环形缓冲区)
14. 帧入 A->B 方向队列
    |
    v 对端 VCS (每 2us poll)
15. vcs_vq_process_rx():
    a. 从 ETH SHM 读帧
    b. DMA read RX avail ring
    c. DMA write 帧到 Guest RX buffer
    d. DMA write used ring
16. set ISR bit + bridge_vcs_raise_msi(0)
    |
    v 对端 QEMU
17. irq_poller -> msi_queue -> BH -> pci_set_irq(1)
18. Guest 中断 -> virtio-net NAPI -> 取帧 -> IP -> ICMP echo reply
19. Reply 反向走步骤 5-17 回到发送方
    |
    v INTx deassert
20. Guest 读 ISR (BAR0+0x3000) -> EP stub 清 ISR
21. VCS 检测 ISR read -> raise_msi(0xFFFE) -> deassert
```

### 4.2 arping -- ARP L2 连通性

```bash
arping -c 3 -I eth0 10.0.0.2
```

与 ping 区别: 直接发 ARP request (EtherType=0x0806), 不经 IP 层. 只验证 L2 (MAC 层) 可达.

### 4.3 nc (netcat) -- TCP 数据传输

```bash
# Guest1 (server)
nc -l -p 5000

# Guest2 (client)
dd if=/dev/urandom of=/tmp/data bs=1024 count=1
nc -w 3 10.0.0.1 5000 < /tmp/data
```

**触发原理:**
- TCP 三次握手: SYN / SYN-ACK / ACK, 每个包走完整 TLP 路径
- 数据分段: 1KB 数据 -> TCP segment -> IP -> 以太网帧 -> virtqueue TX
- 多包交互: 1KB 传输产生 10+ 帧 (数据 + ACK)
- 测试脚本还用 nc 做多轮测试: 512B, 1KB, 2KB, 4KB (端口 5010-5013)

### 4.4 iperf3 -- TCP/UDP 吞吐量

```bash
# Guest1 (server)
iperf3 -s -p 5201

# Guest2 (client, TCP 3秒)
iperf3 -c 10.0.0.1 -p 5201 -t 3 -i 1

# UDP 模式
iperf3 -c 10.0.0.1 -p 5201 -u -b 1M -t 3
```

**触发原理:**
- 高频发包: 尽可能快地填满 TX virtqueue, NOTIFY 频率极高
- 大 TCP 窗口: 多个 segment 可能在一次 NOTIFY 中批量处理
- 吞吐受限于协仿速度: 每个 MMIO 都是跨进程往返

### 4.5 TAP 模式测试

Guest 帧通过 ETH SHM -> eth_tap_bridge -> TAP 网卡到达主机:

```bash
# Guest 内
ping -c 5 -W 3 10.0.0.1         # ping 主机 TAP IP

# 主机上 (VCS 机器)
ping -c 5 10.0.0.2               # ping Guest
iperf3 -s -B 10.0.0.1            # 主机做 server
# Guest 内
iperf3 -c 10.0.0.1 -t 10         # Guest 做 client
```

---

## 5. 日志与调试

### 5.1 日志位置

| 日志 | 路径 | 内容 |
|------|------|------|
| QEMU 输出 | `logs/qemu.log` | Guest 串口 + MMIO trace |
| QEMU debug | `logs/qemu_debug.log` | MSI/DMA 事件 |
| VCS 输出 | `logs/vcs.log` | UVM + VQ TX/RX |
| TAP bridge | `logs/tap_bridge.log` | 帧转发统计 |
| 双实例 | `logs/dual_<timestamp>/` | 4 进程各自日志 |
| Guest 构建 | `logs/guest_build.log` | Alpine/Debian Guest 构建 |

### 5.2 关键 grep

```bash
grep "MRd\|MWr" logs/qemu.log            # MMIO
grep "MSI bh" logs/qemu_debug.log         # 中断
grep "DMA" logs/qemu_debug.log            # DMA
grep "TX notify" logs/vcs.log             # TX 处理
grep "RX inject" logs/vcs.log             # RX 注入
grep "NOTIFY" logs/vcs.log                # doorbell
```

---

## 6. Guest 登录后操作

### 6.1 登录

```
cosim-guest login: root
Password: 123
```

### 6.2 配网

```bash
cosim-start                    # 默认 IP 10.0.0.2
cosim-start 10.0.0.3           # 指定 IP
```

### 6.3 测试命令

```bash
# 连通性 (-c 指定包数, cosim 下每包需数分钟)
ping -c 1 10.0.0.1             # 发 1 个包
ping -c 5 10.0.0.1             # 发 5 个包
ping 10.0.0.1                  # 不停发 (Ctrl+C 停止)

# 吞吐量
iperf3 -s                      # Guest 做服务端
iperf3 -c 10.0.0.1 -t 1        # Guest 做客户端

# PCIe 诊断
lspci -vv                      # 查看 PCI 设备 (含 cosim 设备)
cfgspace_test                  # Config Space 验证
dma_test <BAR_ADDR>            # DMA 读写测试
nic_tx_test <BAR_ADDR>         # NIC TX 测试
```

### 6.4 TAP 模式 iperf 测试

```bash
# Host 上 (新开终端)
iperf3 -s                      # 监听所有网卡 (含 cosim0 TAP)
iperf3 -s -B 10.0.0.1          # 只监听 TAP 地址

# Guest 内
iperf3 -c 10.0.0.1 -t 1        # 连接 Host TAP
```

> iperf3 -s 在 Host 上启动后会监听 5201 端口。Guest 发起连接时,
> 数据路径: Guest eth0 -> cosim 设备 -> VCS RTL -> ETH SHM -> TAP bridge -> Host iperf3

### 6.5 退出

```bash
cosim-stop                     # 正常退出 (通知 VCS 停止)
# 或
Ctrl+A X                       # 强制退出 QEMU
```

---

## 7. 退出机制

| 操作 | 效果 |
|------|------|
| Guest 内 `cosim-stop` 或 `poweroff` | bridge_destroy 发 SHUTDOWN -> VCS 自动退出 |
| `Ctrl+A X` | QEMU 强制退出 -> 通知 VCS shutdown |
| Ctrl+C (等待连接时) | poll 返回 EINTR -> QEMU 退出 |
| Ctrl+C (双实例) | trap 捕获 -> kill 4 个进程 |
| VCS 超时 | 10 分钟安全网, 正常由 SHUTDOWN 驱动退出 |

---

## 8. 调试模式

```bash
make run-qemu VERBOSE=1        # 开启所有 debug 打印 + 内核详细日志
```

VERBOSE=1 效果:
- kernel `loglevel=7` (显示所有内核消息)
- cosim-pcie-rc `debug=on` (MMIO/CfgRd 打印)
- bridge `debug=on` (TLP 发送打印)

默认 VERBOSE=0 终端安静, 日志写入 `logs/qemu.log`。

---

## 9. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `Waiting for VCS connection...` | 等 VCS 连接 (正常) | 另开终端 `make run-vcs` |
| simv_vip 找不到 | 未编译 | `source ~/set-env.sh && make vcs-vip` |
| `Kernel panic: Unable to mount root fs` | initramfs 未注入 cosim-init | 重新构建: `rm -rf guest/images/* && sudo ./scripts/build_rootfs_alpine.sh guest/images` |
| `(none) login:` 而非 `cosim-guest` | overlay 未拷入或 hostname 服务未启用 | 重新构建 rootfs |
| `cosim-start: not found` | overlay 拷贝失败 | 确认 `git checkout good -- guest/overlay/` 后重新构建 |
| TAP `Failed to open ETH SHM` | VCS 未运行或 SHM 名不匹配 | 先启动 VCS, 确认 ETH_SHM 一致 |
| TAP `Operation not permitted` | 缺 CAP_NET_ADMIN | `sudo setcap cap_net_admin+ep tools/eth_tap_bridge` |
| ping 无响应 | cosim RTL 仿真慢 (正常) | 等待数分钟, 用 `ping -c 1` |
| `leaving for legacy driver` | MSI cap < 0x40 | 用最新 config_proxy |
| root 空密码登录失败 | 密码为 123 | 输入 `123` |
