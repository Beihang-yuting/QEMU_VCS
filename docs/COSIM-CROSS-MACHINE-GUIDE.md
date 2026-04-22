# CoSim 跨机联调手册（61 ↔ 53）

本文档记录 QEMU-VCS CoSim 平台在**双机环境**下的启动流程、登录凭据和关键运维命令。
架构：QEMU 在 **10.11.10.53**，VCS 在 **10.11.10.61**，两机通过 TCP（默认 9100 端口）
交换 PCIe TLP；61 上额外跑 `eth_tap_bridge` + TAP `cosim0` + `dnsmasq`，让 Guest 的
virtio-net 数据面报文能出到宿主网络。

---

## 1. 机器与登录凭据

| 角色 | 主机 | 账号 | 密码 | SSH 端口 | 项目路径 |
|---|---|---|---|---|---|
| VCS 仿真（client） | `10.11.10.61` | `ryan` | `Ryan@2025` | `2222` | `~/cosim-platform` |
| QEMU 虚拟机（server） | `10.11.10.53` | `ubuntu` | `123` | `22` | `~/workspace/cosim-platform`；QEMU 在 `~/workspace/qemu/build/qemu-system-x86_64` |
| 上游 VIP 源码 | `10.11.10.59` | `ubuntu` | `ubuntu` | `22` | `~/ryan/pcie_work/pcie_tl_vip` |

SSH 示例：

```bash
# 登录 61（VCS 机）
sshpass -p 'Ryan@2025' ssh -p 2222 ryan@10.11.10.61

# 登录 53（QEMU 机）
sshpass -p '123' ssh ubuntu@10.11.10.53

# 拷贝文件到 61
sshpass -p 'Ryan@2025' scp -P 2222 <src> ryan@10.11.10.61:~/cosim-platform/<dst>
```

---

## 2. 拓扑

```
┌─────────────────────────┐                     ┌───────────────────────────────────┐
│  10.11.10.53 (QEMU)     │   TCP 9100 (TLP)    │   10.11.10.61 (VCS)               │
│                         │ ◀────────────────▶ │                                   │
│  Guest Linux (buildroot)│                     │   simv_vip                        │
│   eth0 10.0.0.2         │                     │     └── cosim_pcie_rc EP (stub)   │
│   virtio-net driver     │                     │                                   │
│        │                │                     │   virtqueue_dma.c (DMA → ETH SHM) │
│        ▼                │                     │         │                         │
│  virtio-pci device      │                     │   /cosim_eth0 (POSIX SHM)         │
│  (cosim-pcie-rc plugin) │                     │         │                         │
│                         │                     │   eth_tap_bridge (Role B)         │
│                         │                     │         │                         │
│                         │                     │   TAP cosim0 10.0.0.1             │
│                         │                     │         │                         │
│                         │                     │   dnsmasq (DHCP, 10.0.0.10-50)    │
└─────────────────────────┘                     └───────────────────────────────────┘
```

**关键编译宏：**

- `COSIM_VIP_MODE` — 走 UVM VIP 栈（当前跨机联调用这个）
- `COSIM_VIRTIO_SOFT_MODEL`（默认）— 软件模拟 virtio 数据面，启用 `virtqueue_dma.c`
- `COSIM_VIRTIO_REAL_IP`（未来）— 切换为接入真实 virtio-net HDL IP，拆掉软件模拟段

---

## 3. 关键一次性配置命令

### 3.1 给 `eth_tap_bridge` 加 `CAP_NET_ADMIN`（每次编译后必跑）

每次重新编译 `tools/eth_tap_bridge` 之后，都要在 **61** 上执行（**必须用绝对路径**，
因为 `ryan` 的 NOPASSWD sudo 白名单严格匹配路径前缀 `/home/ryan/*`）：

```bash
sudo /sbin/setcap cap_net_admin+ep /home/ryan/cosim-platform/tools/eth_tap_bridge
```

> 如果你在其他机器/路径编译过，把路径换成对应目录。例如 53 上路径是
> `/home/ubuntu/workspace/cosim-platform/tools/eth_tap_bridge`。

**为什么需要：** 61 是 LXC 容器，`ryan` 用户 `CapEff=0`，直接 `TUNSETIFF` 会
`Operation not permitted`。给 binary 加 `cap_net_admin+ep` 后，普通用户执行该
binary 时会自动继承 `CAP_NET_ADMIN`，可以直接 `TUNSETIFF` 建 TAP 并做 `ip addr`
/ `ip link up`（由 binary 内部通过 `/sbin/ip` 完成）。

**验证：**

```bash
# 61 上
/sbin/getcap /home/ryan/cosim-platform/tools/eth_tap_bridge
# 期望输出：
#   /home/ryan/cosim-platform/tools/eth_tap_bridge = cap_net_admin+ep
```

**`ryan` 的 sudo 白名单（仅此两条 NOPASSWD）：**

```
(root) NOPASSWD: /usr/sbin/setcap cap_net_admin+ep /home/ryan/*
(root) NOPASSWD: /usr/sbin/setcap cap_net_raw+ep  /home/ryan/*
```

也就是说 `ryan` **不能**自己跑 `ip tuntap add` / `dnsmasq` 等命令。但有了
`CAP_NET_ADMIN` 的 `eth_tap_bridge` 进程**自己就能建 TAP + 配 IP**，因此这
一行 `sudo setcap` 是跨机联调的唯一 sudo 前置条件。

### 3.2 （可选）建 persistent TAP + 启 dnsmasq DHCP

**默认不需要。** Guest 侧 `scripts/guest_init_tap.sh` 用**静态 IP** `10.0.0.2`
并写静态 ARP（对应 TAP 侧 MAC），不走 DHCP。启动流程里 `eth_tap_bridge` 自己
`TUNSETIFF` 建 TAP 并配 `10.0.0.1/24` —— 无需 `setup_tap_61.sh` 介入。

仅当你想让 Guest 走 DHCP（更真实的网络联调场景）时才需要跑：

```bash
sudo bash ~/cosim-platform/scripts/setup_tap_61.sh ryan
```

这要求你另外拿到可跑 `ip tuntap add` + `dnsmasq` 的 sudo 权限。当前 `ryan`
的白名单**做不到**，需要让管理员一次性执行。

---

## 4. 跨机启动完整流程

### 4.1 源码同步（本地 → 61 / 53）

本地开发机 → 61（VCS 源码树 + simv_vip 编译）：

```bash
# 只推有改动的那些文件即可。常用 rsync：
sshpass -p 'Ryan@2025' rsync -avz -e 'ssh -p 2222' \
    --exclude 'build/' --exclude '*.o' --exclude '*.vdb' --exclude '*.daidir' \
    ~/ryan/software/cosim-platform/ ryan@10.11.10.61:~/cosim-platform/
```

QEMU 侧只需要同步 bridge 共享代码和 QEMU plugin：

```bash
sshpass -p '123' scp ~/ryan/software/cosim-platform/bridge/qemu/bridge_qemu.c \
    ubuntu@10.11.10.53:~/workspace/qemu/hw/net/bridge_qemu.c
sshpass -p '123' scp ~/ryan/software/cosim-platform/qemu-plugin/cosim_pcie_rc.c \
    ubuntu@10.11.10.53:~/workspace/qemu/hw/net/cosim_pcie_rc.c
# 然后 53 上：cd ~/workspace/qemu/build && ninja qemu-system-x86_64
```

### 4.2 在 61 上编译 simv_vip + eth_tap_bridge

```bash
# 登录 61
sshpass -p 'Ryan@2025' ssh -p 2222 ryan@10.11.10.61

# 加载 EDA 环境（VCS 许可证 + 路径）
source ~/set-env.sh

cd ~/cosim-platform

# simv_vip
make vcs-vip                                            # 产出 build/simv_vip

# eth_tap_bridge
cd tools && make                                        # 产出 tools/eth_tap_bridge
sudo setcap cap_net_admin+ep ./eth_tap_bridge           # ★ 编译后必跑
cd ..
```

### 4.3 启 TAP + dnsmasq（仅首次或机器重启后）

```bash
# 仍在 61 上
sudo bash scripts/setup_tap_61.sh ryan
```

### 4.4 启动 `eth_tap_bridge`（61 本地后台）

```bash
# 仍在 61 上
./tools/eth_tap_bridge -s /cosim_eth0 -t cosim0 > /tmp/eth_tap_bridge.log 2>&1 &
echo "eth_tap_bridge pid=$!"
```

### 4.5 启动 `simv_vip`（61 上，TCP client，连到 53）

```bash
# 仍在 61 上
cd ~/cosim-platform
source ~/set-env.sh
nohup timeout 600 build/simv_vip \
    +transport=tcp \
    +REMOTE_HOST=10.11.10.53 \
    +PORT_BASE=9100 \
    +INSTANCE_ID=0 \
    +UVM_TESTNAME=cosim_test \
    +SIM_TIMEOUT_MS=600000 \
    +STOP_AFTER_TLPS=100 \
    +ETH_SHM=/cosim_eth0 \
    +ETH_ROLE=0 \
    +ETH_CREATE=1 \
    > /tmp/vcs_fresh.log 2>&1 &
```

### 4.6 启动 QEMU（53 上，TCP server，监听 9100）

```bash
# 登录 53
sshpass -p '123' ssh ubuntu@10.11.10.53

# 启动 QEMU
timeout 500 ~/workspace/qemu/build/qemu-system-x86_64 \
    -machine q35 -m 512 -nographic \
    -device "cosim-pcie-rc,transport=tcp,port_base=9100,instance_id=0" \
    -kernel ~/workspace/buildroot/output/images/bzImage \
    -append "root=/dev/vda console=ttyS0 nokaslr" \
    -drive "file=$HOME/workspace/buildroot/output/images/rootfs.ext4,format=raw,if=virtio" \
    -no-reboot -cpu max \
    > /tmp/qemu_e2e.log 2>&1 &
```

**启动顺序：先 `eth_tap_bridge` → 再 `simv_vip`（它会等 TCP 对端）→ 最后 QEMU。**

### 4.7 观测

```bash
# 61 上——看 virtio 数据面 TLP 计数 + vq 处理情况
tail -f /tmp/vcs_fresh.log | grep -E "virtio-data TLP|VIP-VQ|EP-VIO"

# 61 上——看 TAP↔SHM 流量
tail -f /tmp/eth_tap_bridge.log

# 61 上——看 DHCP 事件
sudo tail -f /tmp/dnsmasq_cosim0.log

# 53 上——看 Guest 启动日志
tail -f /tmp/qemu_e2e.log
```

**成功指标：**

- VCS 侧日志出现 `[VIP-VQ] TX notify: processed N packets` 且 `virtio-data TLP #N kind=NOTIFY`
- `dnsmasq` 日志里出现 `DHCPDISCOVER / DHCPOFFER / DHCPREQUEST / DHCPACK`（按 Guest MAC）
- Guest 侧（QEMU log）出现 `eth0: adding: 10.0.0.X`（DHCP 拿到地址）
- `ping 10.0.0.1`（宿主 TAP）成功 → `eth_tap_bridge` 日志里 TAP↔SHM 包计数递增

---

## 5. 清理/重置

```bash
# 61 上停进程
pkill -9 -f simv_vip
pkill -9 -f eth_tap_bridge
# 53 上停 QEMU
ssh -p 22 ubuntu@10.11.10.53 'pkill -9 -f qemu-system'

# 如需彻底重置 TAP/DHCP（需要 sudo）：
sudo pkill -9 dnsmasq
sudo ip link del cosim0 2>/dev/null
```

---

## 6. 常见错误

| 症状 | 原因 | 解决 |
|---|---|---|
| `eth_tap_bridge: ioctl TUNSETIFF: Operation not permitted` | 没跑 setcap 或重编译后失效 | `sudo setcap cap_net_admin+ep ~/cosim-platform/tools/eth_tap_bridge` |
| `Cannot connect to the license server` | VCS lmgrd 挂了 | 61 上跑 `LD_PRELOAD=/opt/synopsys/scl/2021.03/linux64/bin/snpslmd-hack.so nohup /opt/synopsys/scl/2021.03/linux64/bin/lmgrd -c /opt/synopsys/license/license.dat -l /opt/synopsys/license/lmgrd.log &` |
| VCS 侧 `Completion Timeout: tag=...` | TLP pipeline 回归 | 检查 `glue_if_to_stub.sv` 的 ST_WAIT/wait_cnt、`pcie_ep_stub.sv` 的 cpl_ack、`bridge_qemu.c` 的 drain 循环是否完整；参见记忆 `cosim_vip_pipeline_serialization.md` |
| Guest `virtio: device refuses features: 0` | glue 对 wdata 字节序翻转 | 确认 `vcs-tb/glue_if_to_stub.sv` 的 `hdr_wdata` 是 LSByte-first（`bytes[12]→[7:0]`），不是 PCIe BE |
| Guest `eth0 not found` | Guest rootfs 未加载 virtio_net | 检查 `scripts/guest_init_tap.sh` 里 `insmod virtio_net.ko` 路径 |
| `dnsmasq: failed to bind DHCP server socket` | 已有 dnsmasq 占端口 / systemd 上游管 53 端口 | kill 旧实例；本项目脚本已 `--bind-interfaces` 限定 cosim0 |

---

## 7. 新增 / 关键改动文件清单

| 文件 | 用途 |
|---|---|
| `scripts/setup_tap_61.sh` | 一次性 sudo 建 TAP + 启 dnsmasq |
| `tools/eth_tap_bridge.c` | TAP ↔ ETH SHM 桥接 daemon |
| `bridge/vcs/virtqueue_dma.c` | VCS 侧 virtqueue 真实 TX/RX DMA 处理 |
| `bridge/eth/eth_mac_dpi.c` | DPI-C 包装 `eth_port.c` |
| `bridge/eth/eth_port.c` | ETH SHM 读写 + 链路模型 |
| `vcs-tb/cosim_vip_top.sv` | VIP 模式顶层 + 软件模拟 virtio 数据面驱动段（`ifndef COSIM_VIRTIO_REAL_IP`） |
| `vcs-tb/pcie_ep_stub.sv` | virtio-pci EP stub（common_cfg/notify/ISR/device_cfg 寄存器 + `cpl_ack`） |
| `vcs-tb/glue_if_to_stub.sv` | VIP bus ↔ stub 信号转换 + `cpl_ack` 握手 + `ST_WAIT` 流水线 serialization |
| `bridge/qemu/bridge_qemu.c` | QEMU 侧 bridge（stale cpl drain 循环） |
| `docs/COSIM-CROSS-MACHINE-GUIDE.md` | 本文档 |

---

## 8. 备注

- GitHub 主仓：<https://github.com/Beihang-yuting/QEMU_VCS/tree/main>
- 上游 VIP 同步源：`10.11.10.59:~/ryan/pcie_work/pcie_tl_vip/`；同步回本地时需保留
  `pcie_tl_if_adapter.sv` 的 blocking-assign 本地补丁 + `pcie_tl_codec.sv` 的
  `payload_len<0` 防护补丁，详见记忆 `cosim_vip_pipeline_serialization.md`。
- VCS 许可证：`30000@qingteng`；lmgrd 挂掉时用 `~/set-env.sh` 里 `lmli2` alias 的
  LD_PRELOAD 方式重启。
