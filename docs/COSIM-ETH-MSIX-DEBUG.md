# CoSim-ETH 数据面打通实录：MSI-X 中断 + 参数调优通流

本文档记录 cosim-eth 跨机 guest↔guest 从"帧不通"到"ping 0% 丢包 + TCP 字节精确传输"
的完整调试过程，重点是**仿真慢导致的高 RTT 下、用参数调优让流量真正跑通的方法**。

适用场景：双 guest 跨机 cosim（53 跑两个 QEMU，61 跑两个 `simv_vip` role0/role1
共享 ETH-SHM），无需 TAP / 无需 sudo。

---

## 1. 拓扑（dual-guest，无 TAP / 无 sudo）

```
 53 (QEMU 机, simv-ai)                         61 (VCS 机, qingteng)
 ┌─────────────────────┐   TCP 9100/9101/9102  ┌──────────────────────┐
 │ QEMU g1 (10.0.0.1)  │◄─────────────────────►│ simv_vip role0        │
 │  cosim-pcie-rc      │                       │  +ETH_ROLE=0 +CREATE=1 │
 └─────────────────────┘                       └──────────┬───────────┘
                                                          │ /dev/shm/cosim_eth_dual
 ┌─────────────────────┐   TCP 9200/9201/9202  ┌──────────┴───────────┐
 │ QEMU g2 (10.0.0.2)  │◄─────────────────────►│ simv_vip role1        │
 │  cosim-pcie-rc      │                       │  +ETH_ROLE=1 +CREATE=0 │
 └─────────────────────┘                       └──────────────────────┘
```

- 每个 QEMU 是 TCP **server**（先起，阻塞等 client）；`simv_vip` 是 client（后连）。
- QEMU 器件 ID = `1af4:1041`（virtio-net，非多功能 abcd:1234）。
- 两个 `simv_vip` 共享同一个 `ETH_SHM=/cosim_eth_dual`：role0 写的 TX 帧被 role1 当 RX
  读，反之亦然 —— guest1↔guest2 的以太帧在此转发。

---

## 2. 三个连环问题（都已修复）

### 2.1 漏 `+BYPASS_CONFIG=1` → guest 枚举不出 eth0

**症状**：guest `lspci` 出 `01:00.0 [1af4:1041]`，但 `/sys/class/net` 只有 `lo`，
`modprobe virtio_net` 后仍无 eth0；`dmesg` 见
`virtio-pci 0000:01:00.0: virtio_pci: leaving for legacy driver`。

**根因**：不带 `+BYPASS_CONFIG=1` 时 `pcie_tl_config_proxy.sv` 的 `bypass_enable=0`，
config TLP **穿透到 `pcie_ep_stub.sv` RTL** 回应。ep_stub 的 CfgWr 处理对 DW1 做
全字节合并，guest 写 Command（`len=4`）时把 Status 高 16 位的 **Capability-List 位
（0x10）清零** → guest 读到 `Status: Cap-` → 不遍历 capability 链 → virtio-pci modern
probe 找不到 `COMMON_CFG` → 退给 legacy → 0x1041 非 legacy ID → 无人绑 → 无 eth0。

**修法（零改码，启动加 flag）**：`simv_vip` 加 `+BYPASS_CONFIG=1`，让
`config_proxy` 接管 config 空间（它正确保留 Status 只读位、且带完整 MSI-X capability
@0x98）。

**验证**：guest `lspci -vv 01:00.0` 出
```
Status: Cap+ ...
Capabilities: [40] MSI: ...
Capabilities: [98] MSI-X: Enable+ Count=4 Masked-
Capabilities: [50/64/78/88] Vendor Specific: VirtIO CommonCfg/Notify/ISR/DeviceCfg
```
`/sys/class/net` 出 `eth0`。

### 2.2 `bridge_vcs_dma_write_sync` 发送顺序反了 → MSI-X 中断永不投递

**症状**：`virtio1` NIC 走 MSI-X（`/proc/interrupts` 见 `PCI-MSIX-0000:01:00.0
virtio1-input.0`），但 input 中断计数**恒为 0**，guest 收不到 RX 中断，ping 100% 丢。
QEMU 插件日志有大量正常 virtqueue DMA 写（`cosim: DMA write OK GPA=0x3a61xxx`），
但**从无 `GPA=0xfee01004`**（MSI-X doorbell 写）。

**根因**：`bridge/vcs/bridge_vcs.c` 的 `bridge_vcs_dma_write_sync`（MSI-X 投递用）
**先发 `DMA_DATA` 再发 `DMA_REQ`**；而工作正常的 `bridge_dma_write_bytes`（普通
virtqueue 写）**先发 `DMA_REQ` 再发 `DMA_DATA`**，其注释明写：QEMU `irq_poller` 用
`MSG_PEEK` 按类型匹配，`DMA_DATA` 在前会堵住 aux channel，请求永不被 `cosim_dma_cb`
派发 → 不 `pci_dma_write` → MSI 消息到不了 APIC。

**修法**：把 `bridge_vcs_dma_write_sync` 改成先 `send_dma_req` 再 `send_dma_data`，
与 `bridge_dma_write_bytes` 一致。改后在 61 上重编：
```bash
cd /tmp/cosim-vcsvip-run && source ~/set-env.sh && make vcs-vip   # 增量 ~10s，relink
```

**验证**：guest `/proc/interrupts` 的 `virtio1-input.0` 计数 **0 → 非 0**（MSI-X
真投到 APIC），ARP 双向解析成功，ICMP echo request/reply 帧级双向往返。

### 2.3 simv role1 端口偏移

**症状**：role1 的 `simv_vip` `[tcp] connect timeout: 10.11.10.53:9203` → `UVM_FATAL
bridge_vcs_init_ex (tcp) failed`，200ns 就退。

**根因**：`+INSTANCE_ID=1` 使 simv 连的端口 = `PORT_BASE + INSTANCE_ID*3 = 9203`，
但 QEMU g2（`instance_id=0`, `port_base=9200`）监听 9200。

**修法**：每个 QEMU 都用 `instance_id=0` + 各自 `port_base`（9100 / 9200）；对应的
`simv_vip` 也用 `+INSTANCE_ID=0` + 匹配的 `+PORT_BASE`。

---

## 3. ★ 参数调优通流法（高 RTT 下让流量真正跑通）

修完上面三点后，**帧级已双向连通**，但直接 `ping`／`iperf3` 仍"失败"：

| 现象 | 真相 |
|---|---|
| `ping -c N`（默认 `-W`）100% 丢 | reply 帧确实到达，但 RTT ≈ **2–7 秒**，超过默认超时 |
| `iperf3 -t 10` 传 0 字节 | 10 秒测试窗内首个数据段还没走完一个 RTT |
| `iperf3 -n 16K` 卡死不出汇总 | TCP RTO(~200ms–1s) ≪ RTT(5s) → **spurious 重传风暴**；iperf3 控制连接内部超时自行中止 |

**根因不是数据面 bug，是 VCS 仿真 ~1000× 慢** → 往返是秒级不是毫秒级。TCP 默认参数
是为毫秒级 RTT 设计的，在秒级 RTT 下会疯狂 spurious 重传。

### 3.1 加大应用层超时（先验证连通）

```bash
# ping：等每个 reply 最多 60s，包间隔 5s
ping -c 3 -W 60 -i 5 10.0.0.1
# 期望：0% packet loss，RTT min/avg/max ≈ 2154/5101/7233 ms
```

### 3.2 调 TCP `rto_min ≥ RTT`，消除 spurious 重传（关键）

在**两个** guest 上把到对端路由的最小 RTO 调到 ≥ 实测 RTT（这里 RTT≈5s，设 8s）：

```bash
ip route change 10.0.0.0/24 dev eth0 rto_min 8s
ip route show | grep rto_min      # 期望：... rto_min lock 8s
```

### 3.3 用裸 `nc` 做定量传输（绕开 iperf3 控制通道超时）

```bash
# G1（接收端）：收到固定字节写文件
nc -l -p 1234 > /tmp/rx.bin &

# G2（发送端）：发 4096 字节
head -c 4096 /dev/zero | nc -w 60 10.0.0.1 1234; echo SENT_RC=$?

# G1 核对：应精确 4096 字节
wc -c /tmp/rx.bin      # 期望：4096 /tmp/rx.bin
```

**实测结果**：`SENT_RC=0`，G1 收 `4096` 字节字节精确，TCP 连接干净关闭 →
**cosim-eth TCP 批量数据传输端到端完成**。

> iperf3 若要跑通，同样需要先 `rto_min` 调优，并用足够长的 `-t`／`-n` 给秒级 RTT
> 留出多个往返的时间（或改用 iperf2 / 裸 nc）。**吞吐数在 VCS 仿真速度下无实际意义**，
> 连通性验证以 ping 0% + 定量 nc 传输为准。

---

## 4. 完整复现命令

### 4.1 启动配方

```bash
# ---- 53：两个 QEMU（TCP server，先起）----
# g1: port 9100, IP 10.0.0.1, serial gcon1.sock  （调试可加 -d int -D /tmp/qint.log）
# g2: port 9200, IP 10.0.0.2, serial gcon2.sock
#   -device pcie-root-port,id=rp0,bus=pcie.0,addr=0x3,chassis=1
#   -device cosim-pcie-rc,bus=rp0,addr=0x0,transport=tcp,port_base=<PORT>,instance_id=0

# ---- 61：两个 simv_vip（TCP client，后连），共享 ETH_SHM ----
BASE="+transport=tcp +REMOTE_HOST=10.11.10.53 +UVM_TESTNAME=cosim_test \
      +SIM_TIMEOUT_MS=20000000 +STOP_AFTER_TLPS=20000 +BYPASS_CONFIG=1 +NUM_PFS=0 +NO_WAVE"
# role0（先起，建 SHM）
simv_vip $BASE +PORT_BASE=9100 +INSTANCE_ID=0 +ETH_SHM=/cosim_eth_dual +ETH_ROLE=0 +ETH_CREATE=1 +MAC_LAST=1
# role1（后起，附着 SHM）
simv_vip $BASE +PORT_BASE=9200 +INSTANCE_ID=0 +ETH_SHM=/cosim_eth_dual +ETH_ROLE=1 +ETH_CREATE=0 +MAC_LAST=2
```

### 4.2 guest 内配网（两个 guest 都做）

```bash
# virtio_net 依赖链必须按序加载（net_failover 依赖 failover）
modprobe -a failover net_failover virtio_net
ip link set eth0 up
ip addr add 10.0.0.1/24 dev eth0        # g2 用 10.0.0.2
ip route change 10.0.0.0/24 dev eth0 rto_min 8s   # 高 RTT 通流关键
```

### 4.3 验证

```bash
ping -c 3 -W 60 -i 5 10.0.0.1                       # 期望 0% loss
# 定量 TCP：见 3.3
```

---

## 5. 备注

- bracket-safe 杀进程（`pkill -f qemu-system-x86_64` 会自匹配自身 shell 而误杀）：
  ```bash
  pkill -9 -f '[q]emu-system-x86_64'
  pkill -9 -f '[s]imv_vip'
  ```
- `config_proxy`（config 空间，`+BYPASS_CONFIG=1`）与 `pcie_ep_stub`（BAR0 MMIO：
  common_cfg/notify/ISR/device_cfg/MSI-X table）分工：前者答 config TLP，后者答 BAR 读写。
  **不要走 ep_stub 答 config**（它有 Status cap-bit 被清、且缺 MSI-X cap 的问题）。
- 单 guest + TAP 组网（需 61 上 `CAP_NET_ADMIN` 的 `eth_tap_bridge`）见
  [COSIM-CROSS-MACHINE-GUIDE.md](COSIM-CROSS-MACHINE-GUIDE.md)。
