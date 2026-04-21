# QEMU Virtio 端到端测试设计

## 目标

验证完整的 QEMU virtio-net 端到端数据通路：Guest VM 内 virtio-net 驱动发包 → cosim-pcie-rc → TCP transport → VCS 仿真 → virtqueue DMA 处理 → ETH 帧输出。

## 部署架构

```
QEMU VM (10.11.10.53, Ubuntu)              VCS 仿真 (10.11.10.61:2222, CentOS)
┌──────────────────────────┐               ┌──────────────────────────┐
│ Buildroot Guest Linux    │               │ tb_top.sv                │
│  - virtio-net driver     │               │  ├ pcie_ep_stub.sv       │
│  - iperf3, ping, ip      │               │  │  (virtio PCI regs)    │
│  - static IP 10.0.0.2   │               │  ├ TLP poll loop         │
└────────┬─────────────────┘               │  ├ doorbell → vq_process │
         │ MMIO / DMA                      │  └ RX poll → ISR → MSI  │
┌────────┴─────────────────┐               └────────┬─────────────────┘
│ cosim-pcie-rc            │                        │ DPI-C
│  PCI ID: 1AF4:1041       │               ┌────────┴─────────────────┐
│  BAR0: virtio regs       │               │ bridge_vcs.c             │
│  irq_poller thread       │               │ virtqueue_dma.c          │
│  bridge_qemu (TCP mode)  │               │ eth_mac_dpi.c            │
└────────┬─────────────────┘               └────────┬─────────────────┘
         │                                          │
         │ TCP ctrl(9100) + data(9101)              │
         ╚══════════════════════════════════════════╝
```

## 技术方案

### 方案选择：纯 TLP 模式

所有 Guest MMIO 读写和 DMA 操作通过 cosim TLP 路径跨机传递到 VCS。这是 cosim 平台的核心验证场景——完整 TLP 级 co-simulation。

性能预期：受 TCP DMA 延迟限制（~280us/次），每个报文需要多次 DMA 往返（读描述符、读数据、写 used ring），预计吞吐量 1-5 Kpps，对应 10-60 Mbps（1500B 帧）。

### 组件 1：Buildroot Guest 镜像

在 10.11.10.53 上用 Buildroot 构建最小化 x86_64 Linux：

- 基础配置：`qemu_x86_64_defconfig`
- 内核：启用 `CONFIG_VIRTIO_PCI` + `CONFIG_VIRTIO_NET`（defconfig 默认开启）
- 用户空间包：busybox, iperf3, iproute2
- rootfs 格式：ext4，约 20MB
- 启动配置：`root=/dev/vda console=ttyS0 nokaslr`
- 网络自动配置：`/etc/init.d/S99cosim` 脚本设置 `eth0` 为 `10.0.0.2/24`

输出：`output/images/bzImage` + `output/images/rootfs.ext4`

### 组件 2：QEMU 编译 + cosim-pcie-rc TCP 适配

在 10.11.10.53 上执行 `scripts/setup_cosim_qemu.sh` 编译 QEMU v9.2.0 + cosim-pcie-rc 设备。

cosim-pcie-rc TCP 适配：
- 新增设备属性：`transport`（"shm" 或 "tcp"），`remote_host`，`port_base`，`instance_id`
- `cosim_pcie_rc_realize()` 中：若 `transport=tcp`，调用 `bridge_init_ex()` 创建 TCP transport；否则走原有 SHM 路径
- `run_cosim.sh` 新增 TCP 模式参数：`TRANSPORT=tcp REMOTE_HOST=10.11.10.61 PORT_BASE=9100`

### 组件 3：VCS 侧 TCP 适配

tb_top.sv 初始化改动：
- 增加 `+transport=tcp` / `+LISTEN` / `+PORT_BASE` plusargs 解析
- 若检测到 TCP 模式，调用 `bridge_vcs_init_ex()` 替代 `bridge_vcs_init()`

ETH 通道适配：
- TCP 模式下 `virtqueue_dma.c` 提取的报文需通过 TCP transport 的 `send_eth()` / `recv_eth()` 发送
- 方案：在 `eth_mac_dpi.c` 中增加 transport 感知——若 TCP transport 可用，通过 transport ETH 通道发送；否则走 ETH SHM
- 替代方案：`virtqueue_dma.c` 中新增 `vcs_vq_set_transport()` 函数，直接将提取的帧送入 transport

### 组件 4：端到端启动脚本

`scripts/run_e2e_virtio.sh`：自动化跨机启动流程。

启动顺序（VCS 先监听，QEMU 后连接）：
1. SSH 到 10.11.10.61 启动 VCS 仿真（后台），等待 TCP 监听就绪
2. 在 10.11.10.53 启动 QEMU + Guest
3. 等待 Guest 启动完成（检测串口输出 "login:" 或超时）
4. 通过 QEMU monitor 或串口在 Guest 内执行测试命令

VCS 仿真超时：设为 60 秒（`+SIM_TIMEOUT_MS=60000`），足够完成 virtio 协商 + 报文测试。

## 测试阶段

### 阶段 1：设备识别验证

Guest 侧验证：
- `lspci` 输出包含 `1af4:1041` (Virtio network device)
- `dmesg | grep virtio` 显示驱动加载成功
- `ip link show eth0` 显示接口存在

VCS 侧验证：
- 日志可见 feature negotiation TLP（device_feature_sel, driver_feature 写入）
- 日志可见 queue setup TLP（queue_desc, queue_driver, queue_device 地址配置）
- 日志可见 DRIVER_OK status 写入（dev_status bit 2 置位）

### 阶段 2：TX 报文验证

Guest 操作：
```bash
ip addr add 10.0.0.2/24 dev eth0
ip link set eth0 up
ping -c 5 10.0.0.1  # 会发出 ARP + ICMP，不期望回复
```

VCS 侧验证：
- `notify_valid` 脉冲触发（doorbell 写入）
- `vcs_vq_process_tx()` 返回值 > 0（成功提取报文）
- ETH 通道收到帧，帧内容为合法的 ARP 或 ICMP 报文
- 打印帧的 hex dump 用于人工确认

### 阶段 3：吞吐量测试

Guest 操作：
```bash
iperf3 -c 10.0.0.1 -u -b 100M -t 10 --no-delay
```

VCS 侧统计：
- 每秒报告接收帧数和吞吐量
- 10 秒持续运行不崩溃
- 帧数据完整性校验

验收标准：
- 持续 10 秒稳定运行
- 吞吐量 > 1 Kpps（受 DMA 延迟限制的合理下限）
- 零帧损坏

注意：本阶段只验证 TX 方向（Guest → VCS）。iperf3 使用 UDP 单向模式，不需要 VCS 侧回复。iperf3 client 会报告 "server not responding" 但 TX 发包不受影响。

## 不做什么

- 不实现 RX 回路（VCS → Guest 注入报文）——ISR+MSI 机制已在现有测试中验证
- 不实现 ARP/ICMP responder——只验证 TX 方向
- 不实现 indirect descriptor 支持——Guest 默认不使用
- 不实现 vhost-user 加速——纯 TLP 模式是验证目标
- 不实现 VIP UVM 模式——使用 legacy tb_top.sv 即可

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `qemu-plugin/cosim_pcie_rc.c` | 修改 | 增加 TCP transport 属性和初始化路径 |
| `vcs-tb/tb_top.sv` | 修改 | 增加 TCP plusargs + bridge_vcs_init_ex 调用 |
| `bridge/eth/eth_mac_dpi.c` | 修改 | 增加 transport 感知，TCP 模式用 transport ETH 通道 |
| `scripts/setup_cosim_qemu.sh` | 修改 | 适配 Buildroot 镜像路径 |
| `scripts/run_cosim.sh` | 修改 | 增加 TCP 模式启动参数 |
| `scripts/run_e2e_virtio.sh` | 新建 | 跨机端到端自动化启动脚本 |
| `scripts/buildroot_defconfig` | 新建 | Buildroot 配置片段 |
| `guest/S99cosim` | 新建 | Guest 网络自动配置 init 脚本 |
