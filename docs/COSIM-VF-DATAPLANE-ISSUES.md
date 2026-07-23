# CoSim SR-IOV VF Actuation 与数据面：问题定位汇总

> 记录从「guest `echo N > sriov_numvfs` 起不来」到「VF DMA/MSI-X 数据面端到端跑通」全过程定位到的**根因级问题**。
> 目标形态：DPU 网卡，4 PF × 每 PF ≤256 VF，config 空间 bypass 给 VCS（DUT 权威源），QEMU 做 RC/host。
>
> 环境：QEMU@58（RC/host，本地）+ VCS@53（`/home/ubuntu/test_cosim/cosim-xrc`，UVM DUT + EP model），TCP 3-conn 传输（ctrl 9100 / data 9101 / aux 9102）。Ubuntu guest（6.8.0-107，含 pci-pf-stub），`init=/bin/bash`。
>
> 相关文档：[COSIM-SRIOV-PF-VF-BAR.md](COSIM-SRIOV-PF-VF-BAR.md)（机制/aperture 模型）、[COSIM-ETH-MSIX-DEBUG.md](COSIM-ETH-MSIX-DEBUG.md)。

---

## 分类速览

| # | 类别 | 问题 | 根因 | 状态 |
|---|------|------|------|------|
| 1 | 传输同步 | ext-cap 链 0x100 间歇读失败，SR-IOV 整链隐身 | ctrl_fd 多线程无锁并发写 desync | ✅ |
| 2 | 传输同步 | 枚举期误发 VF-disable 事件 | config_proxy `!vf_en` 无边沿守卫 | ✅ |
| 3 | 传输同步 | VF_EVENT 收发错位 | payload-first（非 sync-first） | ✅ |
| 4 | SR-IOV config | 内核写 BAR base 读回 0 → sriov_init 失败 | cfg_read 走 cfg_space（未回存的 base） | ✅ |
| 5 | VF 建模 | VF config 返 `type 7f class 0xffffff` | QEMU 不转发 VF config 到 VCS | ✅ |
| 6 | VF 建模 | VF stub `already occupied by cosim-pcie-rc` | PF 缺 multifunction cap / hotplugged | ✅ |
| 7 | VF 建模 | `single function device can't be populated` | 每个 VF stub 缺 multifunction cap | ✅ |
| 8 | VF 建模 | VF 首读仍 7f（时序竞态） | CfgWr fire-and-forget，内核抢读 | ✅ |
| 9 | 拓扑 | `can't enable 256 VFs (bus 02 out of range)` | root port subordinate 只到 bus01 | ✅ |
| 10 | Guest | `echo N` 报 `no driver bound` | alpine 无 `CONFIG_PCI_PF_STUB` | ✅ |
| 11 | 数据面 | **DMA round-trip 返 0，MSI-X 丢** | **Bus Master Enable 未生效（DMA AS decode-error）** | ✅ |

---

## 1. 传输层 / 同步

### 1.1 ctrl_fd 多线程并发写 desync（最隐蔽，SR-IOV 隐身根因）
**现象**：guest 枚举时 QEMU 日志间歇 `cfg_read addr=0x100 VCS_FAIL -> local=0x0`。0x100 是 PCIe 扩展 cap 链**入口**，一次读失败 → 内核判「无任何 ext cap」→ SR-IOV cap 整链隐身 → `sriov_init` 找不到 cap（kretprobe 抓 `pci_iov_init` 返 0）。

**根因**：QEMU 主线程（config/MMIO 的 `send_sync`/`recv_sync`）与 **irq_poller 线程**（`cosim_dma_cb → bridge_complete_dma → send_sync(DMA_CPL)`）**无锁并发写 ctrl_fd**。`tcp_send_msg` 的 hdr + payload 两次 `write()` 字节交错 → VCS 读错帧 → 整个 ctrl 通道 desync。

**修复**（`bridge/common/transport_tcp.c`）：priv 加 `pthread_mutex_t ctrl_tx_lock` + helper `tcp_send_ctrl()` 包裹**所有** ctrl_fd 发送（SYNC / TOPOLOGY / VF_CONFIG / VF_EVENT / HANDSHAKE 共 6 处）。只护「一次发送突发」，不跨 recv，无死锁。**58 .so 与 53 .a/simv 都要重建**（共享代码）。

### 1.2 枚举期 spurious VF-disable 事件
**现象**：guest 首次枚举 PF 时，QEMU 收到 VF-disable 事件 + VF_CONFIG，误拆 aperture。

**根因**：`config_proxy` 在 `!vf_en` 分支无条件发 VF-disable 事件/config，枚举读 SR-IOV Control 时也触发。

**修复**（`pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv` ~L392）：
```systemverilog
end else if (!vf_en && func_mgr.sriov_caps[ctx.pf_index].vf_enable) begin
```
只在真「enabled → disabled」边沿发。

### 1.3 VF_EVENT payload-first desync
**根因**：`bridge_vcs_send_vf_event` 先发 payload 再发 sync-header，QEMU 期望 sync-first。

**修复**（`bridge/vcs/bridge_vcs.c`）：改 sync-first（先 `send_sync(SYNC_MSG_VF_EVENT)` 再 `send_vf_event`）；QEMU 侧 `bridge_consume_vf_event` + 在 `bridge_wait_completion*` drain。

---

## 2. SR-IOV config 空间

### 2.1 BAR read-back = 0 → sriov_init 失败
**现象**：`pci 01:00.0: BAR 0: error updating (0xfe800000 != 0x0)`，PF BAR 分配失败，连带 sriov_init 失败。

**根因**：`config_proxy` 把 BAR base 写进 `ctx.bar_base[]` / `sriov_cap.vf_bar[]`，但 `handle_cfg_read` 走 `func_mgr.cfg_read → cfg_space`（仍为 0）→ 内核写完 BAR 读回 0 → 判不一致。

**修复**：`handle_cfg_read_bdf` 对 BAR（dw4-9）和 VF BAR（dw0x89-0x8E），**非 sizing 且已实现**时返回存的 base（`ctx.bar_base` / `sriov_cap.vf_bar`）。

> BAR sizing 机制本身是好的：setpci 写 0x224=FFFFFFFF 读回 `ffff0000`（64KB mask）验证过。

---

## 3. VF 设备建模（QEMU 侧）

### 3.1 VF config `type 7f class 0xffffff`
**现象**：`echo 2 > sriov_numvfs` → 内核建 VF `01:00.1 [1af4:1041]`（vendor/device 正确，说明 VF BDF CfgRd 路由通），但 header-type@0x0E=0x7f、class@0x08=0xffffff → `unknown header type 7f, ignoring device` → 回滚。

**根因**：QEMU 不转发 VF BDF 的 config 访问到 VCS，VF cfg 空间只有 vendor/device。

**修复**（`qemu-plugin/cosim_pcie_rc.c`）：新增 VF config stub 设备 `cosim-pcie-rc-vf`（`CosimRcVF{parent_obj, pf, vf_bdf}`），`config_read/write` 把 CfgRd/CfgWr TLP 转发 VCS（`target_bdf = vf_bdf`）。`cosim_vf_config_apply` 每 VF `pci_new(vf_bdf&0xFF, TYPE_COSIM_RC_VF)` + `pci_realize_and_unref`。

> 命名坑：已存在 `cosim_pcie_vf.c` 用 `cosim-pcie-vf`，重名 abort → 本 stub 用 `cosim-pcie-rc-vf`。

### 3.2 / 3.3 multifunction cap 缺失
- **`slot 0 function 0 already occupied by cosim-pcie-rc`**：PF 需 `cap_present |= QEMU_PCI_CAP_MULTIFUNCTION`（**cap_present 位，非 config 字节**）+ VF stub `DEVICE(d)->hotplugged = false`。
- **`single function device can't be populated in function 1f.5`**：每个 VF stub 也需 `cap_present |= QEMU_PCI_CAP_MULTIFUNCTION` + `config[PCI_HEADER_TYPE] |= PCI_HEADER_TYPE_MULTI_FUNCTION`。

### 3.4 VF 首读仍 7f（时序竞态）
**根因**：VF-enable 的 CfgWr 是 fire-and-forget，内核在 VCS 处理完 VF_CONFIG 前就读 VF config。

**修复**：`cosim_config_write` 中 ext-config 写（`address >= 0x100`）后 `bridge_drain_vf_pending(ctx, 200)` 有界 drain（处理 VF_CONFIG→consume / VF_EVENT→consume / CPL_READY→discard）。
> 注：曾试同步 CfgWr（等 CPL）会 hang——VCS 不 CPL 写事务，故用 fire + drain。

---

## 4. 拓扑 / Guest

### 4.1 `can't enable 256 VFs (bus 02 out of range of [bus 01])`
**根因**：PF + 256 VF = 257 槽 > 单 bus 256，溢出到 bus02；root port 默认 subordinate=01。

**修复**：guest cmdline 加 `pci=assign-busses` 强制内核重排 bus，root port 变 `bridge to [bus 01-02]`。

### 4.2 alpine 无 pci-pf-stub
**现象**：`echo N > sriov_numvfs` → `no driver bound to device; cannot configure SR-IOV`（内核要求 PF 绑定带 `.sriov_configure` 的驱动）。alpine `linux-virt` `CONFIG_PCI_PF_STUB is not set`。

**修复**：换 Ubuntu guest（含 `pci-pf-stub`）。流程：`modprobe pci-pf-stub` → `echo pci-pf-stub > driver_override` → `echo BDF > drivers/pci-pf-stub/bind` → `echo N > sriov_numvfs`。

---

## 5. 数据面：DMA / MSI-X（本轮核心）

### 5.1 DMA round-trip 返 0，MSI-X 丢 —— Bus Master Enable 未生效
**现象**：EP 经 VF0 BAR0 doorbell 发起 DMA-write 0xBBBBBBBB → gpa，随后 DMA-read 同 gpa **返 0x00000000**（多地址系统性，非地址问题）。三种操作（DMA-wr/rd/MSI-X）**都到 QEMU**（机制通），但值不对。

**定位**：WRITE 路径加读回验证 →
```
DMA-WR dbg  req_gpa=0x30000000 len=4 buf=bbbbbbbb      # len/data 都对
DMA-WR verify gpa=0x30000000 rr=2 readback=00000000    # rr=2 = MEMTX_DECODE_ERROR
```
`rr=2`（`MEMTX_DECODE_ERROR`）= **PF 设备的 DMA 地址空间解不到 guest RAM**。

**根因**：QEMU 用 `PCI_COMMAND` 的 Bus Master Enable 位门控设备 DMA AS 里的 `bus_master_enable_region`（system RAM 的 alias）。
- **config-bypass 模型下，guest 写 `PCI_COMMAND`（含 MASTER 位）发给 VCS，QEMU 本地 shadow 收不到**；
- 且 realize 后的 **machine reset** 会清 command + `memory_region_set_enabled(bus_master_enable_region, false)`；
- realize 里的 `pci_set_word(config+PCI_COMMAND, MASTER)` **只改 shadow 字节、不 enable region**，还被 reset 覆盖。

→ 设备发起的 DMA 全撞 decode-error，连 MSI-X 写 APIC 0xFEE00000 也被丢（decode-error）。

**修复**（`qemu-plugin/cosim_pcie_rc.c` `cosim_vf_config_apply`，guest 使能 VF 的 config-write 路径，**持 BQL**，DMA 之前）：
```c
PCIDevice *pd = PCI_DEVICE(s);
pci_set_word(pd->config + PCI_COMMAND,
             pci_get_word(pd->config + PCI_COMMAND) | PCI_COMMAND_MASTER);
memory_region_set_enabled(&pd->bus_master_enable_region, true);
```
> 放在 realize 无效（被 reset 覆盖）；放在 `cosim_dma_cb`（irq_poller 线程，无 BQL）调 `memory_region_set_enabled` 有风险。VF-enable 路径既持 BQL 又在 DMA 之前，最合适。

**验证（修后）**：

| 环节 | 结果 |
|------|------|
| QEMU 写回读 | `DMA-WR verify rr=0 readback=bbbbbbbb` |
| QEMU DMA-read | `DMA-RD buf=bbbbbbbb` |
| VCS EP 端 | `EP VF bdf=0x0101 DMA-READ gpa=0x30000000 -> 0xbbbbbbbb` |
| MSI-X | APIC 0xFEE00000 写 data=0x21 `rr=0`（之前 decode-error） |

DMA write→read round-trip + MSI-X 投递机制**端到端全通**。

### 5.2 真实 requester_id + 多 VF round-trip
**目标**：DMA 携带发起 VF 的真实 BDF（requester_id），多 VF 各自独立跑通。

**协议**：`dma_req_t` 本就有 `requester_id` 字段（`cosim_types.h`），只是 `dma_*_rc` 没填。加 `bridge_vcs_dma_{read,write}_rc_rid(rc, requester_id, ...)` DPI 变体（旧 `_rc` 包 `requester_id=0`，不动 atomic_check 5 处调用），EP `ep_vf_mmio_write` 传 `int'(vf_bdf)`。

**VF stub DMA AS 走不通（重要发现）**：曾想按 requester_id 把 DMA 路由到对应 VF stub 的 `PCIDevice` 地址空间（`cosim_dma_dev`），但 `DMA-WR verify dev=vf wrr=2 rrr=2`（`MEMTX_DECODE_ERROR`）—— **VF stub 的 `bus_master_as` 根本解不到 guest RAM，且 `pci_set_word`/`pci_default_write_config(PCI_COMMAND, MASTER)` 都无法让它生效**。根因：config-bypass 模型无 IOMMU，VF stub 只是 config 空间壳，没有真实 bus-master 通路。
→ **正确架构**：**PF 是唯一 DMA-capable function，代所有 VF 发起 DMA**，`requester_id` 仅作身份标识（携带 + 日志 `from=vf`）。真加 IOMMU 时才需按 VF AS 路由做隔离。QEMU 侧退回统一走 `PCI_DEVICE(s)`（PF，BME 已在 5.1 修好），保留 `cosim_rid_is_vf()` 谓词仅用于日志归属。

**验证（2 VF 并发）**：

| VF | BDF | GPA | pattern | QEMU 日志 | VCS EP 读回 |
|----|-----|-----|---------|-----------|-------------|
| VF0 | 0x0101 | 0x30000000 | 0xaaaa1111 | `rid=0x0101 from=vf` | `-> 0xaaaa1111` ✅ |
| VF1 | 0x0102 | 0x31000000 | 0xbbbb2222 | `rid=0x0102 from=vf` | `-> 0xbbbb2222` ✅ |

各 VF 独立 gpa/pattern 无串扰，round-trip + MSI-X 全通。

### 5.3 EP doorbell 协议（VCS 侧 stand-in DUT）
`vcs-tb/cosim_xrc_driver.sv`，拦截发往 VF BDF 的 MWr（`func_mgr.lookup_by_bdf(tgt).is_vf`），不转发 VIP DUT：

| VF0 BAR0 offset | 语义 |
|-----------------|------|
| 0x00 / 0x04 | DMA 目标 GPA lo / hi |
| 0x08 | pattern |
| 0x0C | CTRL：bit0=DMA-write / bit1=DMA-read / bit2=MSI-X / bit3=AtomicOp(FetchAdd+1) |

后续接真实 DUT 当 EP 即可，该 model 仅为验证数据面。

### 5.4 压力测试（1000+ 混合操作）
guest bash 循环打 doorbell（VF0 400 iter + VF1 100 iter，base ctrl=0x3 wr+rd，每 10 次 +MSI-X，每 25 次 +atomic）：

| 项 | QEMU | VCS EP | 期望 |
|----|------|--------|------|
| DMA write OK | 550 | 500(+50 MSI-X) | 500 数据写 |
| DMA read OK | 500 | 500 | 500 |
| MSI-X → APIC | 50 | 50 | 每 10 次 |
| AtomicOp | 20 | 20 | 每 25 次 |
| FAIL/decode/timeout | **0** | UVM_ERROR/FATAL **0** | 0 |
| requester_id | 0x0101=840 / 0x0102=210 | — | VF0/VF1 分离 |

纯 RAM DMA=1000（500wr+500rd）+ 50 中断 + 20 atomic 交织，双 VF 并发全程无 desync/丢包/hang；atomic RMW 语义正确（`FetchAdd+1 old=0x100 ret=0`）。驱动脚本 `/tmp/stress.py`。

---

## 6. 环境 / 工具坑

- **console bracketed-paste 污染**：`init=/bin/bash` + `[?2004h` 会把多命令 send 交错 mangle。解法：单行复合命令、`re.sub` 去 ANSI、Ctrl-C×3 清行、读 `logs/qemu_rc0.log`（chardev logfile）兜底。**run 脚本自带 python 会抢 VF-enable console** → 先等 `UBUNTU_DONE` 再手动操作。
- **guest 无法直查 DMA 落地**：`iomem=relaxed` 加了但 `/dev/mem` 对 System RAM `mmap` 仍被 `STRICT_DEVMEM` 挡 → 靠 QEMU verify log + VCS EP log 验证。
- **freestanding MMIO 工具**（guest 无 python/gcc/devmem）：`/root/mmio`（raw x86-64 syscall，`__attribute__((naked)) _start` 抓 rsp——**-O2 下不能在 C `_start` 读 rsp**，prologue 会改），`gcc -nostdlib -static`，注入 rootfs（debugfs write + mode 0755）。
- **VCS 增量编译跳过 pkg-included 文件**（如 config_proxy.sv）→ 改共享 .sv 后须 clean rebuild（`rm -rf csrc *.daidir`）。
- **QEMU `undefined symbol`**：改共享代码后须重编全部 3 个 qemu obj；手动重建用**内联 CFLAGS**（别用 shell 变量，展开出 `-O` 参数错）。
- **启动顺序**：QEMU 先 listen（9100）再 VCS connect（VCS `REMOTE_HOST=58` 主动连）。53 有 stale simv 会抢连 → `pkill -9 -f simv_cosim`。
- **QEMU 僵尸堆积**：`init=/bin/bash` 退出→panic→QEMU 变 defunct（ppid=1，Z 态，不占端口），init 慢慢回收，无害。

---

## 6.5 多 PF 扩展（Phase 1：4 PF 枚举）

**架构决策**：4PF×256VF 走 **config-bypass（cosim_pcie_rc.c）**，不用 QEMU 原生 `pcie_sriov`（cosim_pcie_pf.c/vf.c）。理由：目标是 DUT/VCS 权威拥有一切 config（含 SR-IOV cap），QEMU 只做 RC/host；`pcie_sriov_pf_init` 让 QEMU 本地合成 SR-IOV cap → guest 测的是 QEMU 合成 cap 而非 DUT 的，接真实 DUT 时冲突。故 **`cosim_pcie_pf.c/.h` + `cosim_pcie_vf.c/.h` 已删**（备份 `/tmp/deleted_sriov_backup/`，meson.build 移除对应行），避免误导。

**QEMU 侧多 PF 管道**（`cosim_pcie_rc.c/.h`）：加 `pf_index`（=`PCI_FUNC(devfn)`）/`num_pfs` 属性；primary（func0）开 transport + 自动建 PF1..N-1 sibling（`pci_new(PCI_DEVFN(slot,i))` 同 slot），sibling **共享 PF0 的 bridge_ctx/irq_poller**（不各开连接），只注册 BAR + bus master；VF-config 回调按 `cfg->pf_index` 分发到 `g_rc_pfs[pf_index]`；exit 守卫（sibling 不销毁共享 ctx）。config 转发已按各 PF 自身 BDF 动态（0x0100-0103）。VCS 侧本就支持多 PF（`+NUM_PFS=4`，func_manager 循环建 N PF）。

**枚举 bug（关键）**：4 PF realize 成功但 guest 只枚举 PF0，且**从不读 01:00.1-3**（尽管 PF0 header type=0x80 multifunction）。根因：**VCS ARI Extended Cap 的 Next Function Number=0** → Linux 走 ARI 枚举时在 func0 就停（ARI 用 next-function 链取代经典 func1-7 扫描）。**修复**（`func_manager.sv` ARI cap）：`ari_cap.data[1] = (pf+1<num_pfs) ? pf+1 : 0`（Next Function Number 链 PF0→PF1→..→PF(N-1)）。修后 guest 枚举全 4 PF：`01:00.0-3 [1af4:1041] type 00 class 0x020000` ✅。

**配置**：run 脚本 `num_pfs=4,multifunction=on`；startvcs `+NUM_PFS=4 +MAX_VFS=0`（Phase 1 纯枚举，无 VF）。

## 6.6 多 PF + VF（Phase 2）

**BDF 冲突修复**：默认 `sriov_cap.first_vf_offset=1, vf_stride=1` 只对单 PF 有效——多 PF 时 PF0 的 VF0 RID = 0x0100+1 = 0x0101 撞 PF1。**修**（`func_manager.sv` sriov_cap）：`first_vf_offset = vf_stride = num_pfs`（交织布局）。4 PF 时 VF RID = pf_bdf + num_pfs + i*num_pfs：PF0 VF=0x0104/0108，PF1 VF=0x0105/0109，PF2=0x0106/010a，PF3=0x0107/010b——不撞 PF(0x0100-3) 也不互撞。config_proxy 发 vf_config 时 `first_vf_bdf=get_vf_rid(0)`、`vf_bdf_stride=get_vf_rid(1)-get_vf_rid(0)` 自动跟随。QEMU aperture 用 `vf_bdf_stride` 算 BDF、`vf_bar_stride`(=BAR size) 算地址，两者分开，交织正确解码。

**验证（PF0+PF1 各 2 VF，MAX_VFS=4）**：`echo 2 > sriov_numvfs` on 01:00.0 和 01:00.1 → guest 出 8 设备无冲突：PF0-3(01:00.0-3) + PF0 VF(01:00.4/01:01.0) + PF1 VF(01:00.5/01:01.1)。QEMU per-PF aperture：`pf0 first_bdf=0x0104 stride=4`、`pf1 first_bdf=0x0105 stride=4`（VF-config 回调按 pf_index 正确分发）。

**跨 PF 数据面**：doorbell PF0-VF0(01:00.4) + PF1-VF0(01:00.5)：

| VF | rid | GPA | 写→读回 | from |
|----|-----|-----|---------|------|
| PF0-VF0 | 0x0104 | 0x32000000 | 0xcafe0104 → **0xcafe0104** | vf |
| PF1-VF0 | 0x0105 | 0x33000000 | 0xcafe0105 → **0xcafe0105** | vf |

各 PF 的 VF requester_id 正确、round-trip 正确、跨 PF 无串扰。`cosim_rid_is_vf` 改为扫全 PF 的 vf_devs（`g_rc_pfs[*]`）以正确标注非 PF0 的 VF。**多 PF + VF 端到端全通**。

## 6.7 满规模 4PF×256VF = 1024 VF ✅

**关键洞察（cross-bus VF 不需 config stub）**：交织 stride=4，256 VF/PF 的 RID 跨 bus 01-05。QEMU 只为 PF 同 bus（bus01）的 63 个 VF 建 config stub，跨 bus 的 193 个 fallthrough 跳过。**但 guest 仍全枚举**——因为 Linux SR-IOV 的 VF vendor/device 来自 **SR-IOV cap 的 VF Device ID**（不读 VF config header），VF BAR 来自 **PF cap 的 VF BAR aperture**（地址映射，QEMU 侧 `memory_region` 覆盖全 256 VF 跨 bus）。故 cross-bus VF 无 stub 也能枚举 + 数据面。

**Root port 资源**：run 脚本 rp0 加 `bus-reserve=8,mem-reserve=256M`（覆盖 bus01-09 + 4×16MB VF BAR aperture）。

**验证**：`echo 256 > sriov_numvfs` on 全 4 PF → PF0-3 各 256，guest 总设备 1028（4 PF + 1024 VF）。QEMU 4 PF 各 mapped 256-VF aperture（pf0 0x0104/pf1 0x0105/pf2 0x0106/pf3 0x0107 交织）。数据面 spot-check：

| VF | rid | bus | 读回 | 说明 |
|----|-----|-----|------|------|
| PF0 VF191 | 0x0400 | 04 | — | 跨 bus aperture 解码 `vf191` |
| PF0 VF255 | 0x0500 | 05 | — | 跨 bus 最高 VF |
| PF3 VF0 | 0x0107 | 01 | 0xbeef0107 | 跨 PF |

aperture 地址映射覆盖全 1024 VF、解码正确 vf_index→bdf→requester_id，跨 bus + 跨 PF 无串扰。**4PF×256VF 满规模端到端全通**。

> cosim_rid_is_vf 对无 stub 的 cross-bus VF 返 `from=pf`（纯日志标签，数据面/rid 正确）——因为 requester 归属靠 vf_devs 表，cross-bus VF 不在表内。若需精确标注可改按 aperture BDF 范围判断。

## 6.8 MSI-X 中断闭环（guest 经 VFIO 收 VF 中断）✅

**目标**：VF 的 MSI-X 中断真正到达 guest（用户态可观测），非仅 EP→APIC write。

**为何之前不到**：EP 硬编 raw DMA-write 0xFEE00000/vector0x21 → guest SPU=0。因为 ① VF config 无 MSI-X cap ② VF 无驱动使能 MSI-X → 无接收方 ③ 硬编 vector 无 handler。

**5 组件**（config-bypass 模型，TCG，guest 无 gcc→host 交叉编译静态注入）：
1. **VF config MSI-X cap**（`cfg_space_manager.sv::init_msix_capability`@0x90）：cap_id 0x11，table_size=8，Table@BAR0+0x1000/BIR0，PBA@+0x1800；func_manager VF init 调它。VF cap 链 0x40(PCIe)→0x80(PM)→0x90(MSI-X)。
2. **EP 捕获 MSI-X table**（`cosim_xrc_driver.sv` ep_vf_mmio_write）：guest 写 VF BAR0+0x1000..0x100C 经 aperture MWr 到 VCS，EP 存 per-VF `ep_msix_addr/data/mask`。
3. **EP fire 捕获值**：doorbell ctrl bit2 改 fire `ep_msix_addr/data`（非硬编），`bridge_vcs_dma_write_rc_rid(vf_bdf, addr, data)`；未编程时 fallback 硬编。
4. **host 静态 VFIO 消费者**（`/tmp/vfio_msix.c`→`/root/vfio_msix`）：open container+noiommu group+device，`VFIO_DEVICE_SET_IRQS(MSIX)` 挂 eventfd，mmap BAR0，写 doorbell ctrl=4，poll eventfd。
5. **guest vfio-pci noiommu**：`modprobe vfio-pci` → `echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode` → `driver_override=vfio-pci` + bind → group `/dev/vfio/noiommu-0`。

**验证（VF 01:00.4 = 0x0104）**：
- guest 内核分配 vector 0x24，编程 VF MSI-X table：EP 捕获 `MSI-X table[0]: addr=0xfee00000 data=0x24 mask=0`
- doorbell ×4 → EP fire `MSI-X(programmed) -> addr=0xfee00000 data=0x24`（guest 编程值，非硬编 0x21）
- 用户态：`MSI-X vector 0 armed with eventfd` → **`MSIX_IRQ_RECEIVED count=4`** ✅

**闭环全通**：guest VFIO 编程 → EP 捕获 → fire → QEMU APIC 投递 vector 0x24 → guest VFIO IRQ handler → eventfd → 用户态收到。真实 DUT 接入后其驱动走同一路径（编程 MSI-X table → DUT 发中断）。

### 6.8.1 多 VF / 多 vector 扩展
EP 扩展：捕获 table[0..7] per VF（key={vf_bdf,vec}）、VF BAR0+0x10=vector-select、ctrl bit2 fire 选中 vector（`cosim_xrc_driver.sv`）。VFIO 消费者 arm N vector eventfd + 逐 vector 触发（`vfio_msix.c`）。

- **✅ 多 VF MSI-X**：01:00.4(PF0-VF0) + 01:00.5(PF1-VF0) 各绑 vfio-pci，各自 `VEC0_IRQ_RECEIVED`。跨 PF 多 VF 中断独立到达。
- **✅ 多 vector/VF（根因已修）**：`count=8` 稳定，`VEC0/1/2/3_IRQ_RECEIVED`，`MSIX_MULTIVEC_DONE ok=4/4`。

  **根因**：config-bypass 下 guest 写 MSI-X Message Control（设 Enable 位）时，某次坏读返 0 后 read-modify-write 把 **RO 的 Table Size 字段冲成 0** → `pci_msix_vec_count` 返 1 → `pci_alloc_irq_vectors` 只分 1 vector → 只编程 table[0]。（Message Control 低字节默认 RW，被 write-back 清零。）

  **修复**（`cfg_space_manager.sv::init_msix_capability`）：Message Control 低字节 `field_attrs[cap+2] = CFG_FIELD_RO`（write 路径 honor field_attrs，跳过 RO 字节）→ Table Size 恒 7，guest 写 Enable/Mask 不影响。修后 Message Control 稳定读 0x0007，count=8。

  **验证**：EP 捕获 table[0-3] 各不同 data（guest 分配 vector 0x24/0x25/0x26，addr 0xfee00000/0xfee01000 不同 CPU）；fire vec=0-3 各用 guest 编程的 addr/data → 全 4 投递。多 vector + 多 VF MSI-X 端到端全通。

## 6.9 Per-VF DMA 隔离（windowed IOMMU，opt-in）✅

**目标**：每 VF 独立 AddressSpace + 窗口翻译，越界/邻 VF DMA 被拒——真实 host IOMMU（按 requester BDF 隔离）的仿真。方案对比后选**方案1（per-VF 窗口 IOMMUMemoryRegion）**而非 QEMU 原生 intel-iommu：后者只验证 guest vIOMMU 驱动栈，真实 DUT 场景由物理 host 硬件 IOMMU 负责、不复用；方案1 测的"按 requester_id 路由到独立 AS + 越界拒绝"正是真实 VT-d 按 source-id 隔离 VF 的语义。（ATS/PRI 设备侧翻译后置。）

**设计要点**（`cosim_pcie_rc.c`）：
- **窗口 = host 侧策略**，QEMU 本地按 (pf_index, vf_index) 派生 `win_base = vf_dma_base + (pf_index*num_vfs + vf)*vf_dma_size`，**不改 vf_config 线格式**（不碰 VCS/TCP）→ 零回归。全局唯一，跨 PF 的 VF 不 alias。
- `TYPE_COSIM_VF_IOMMU`（`IOMMUMemoryRegion` 子类）`translate()`：窗内 identity + `IOMMU_RW`，窗外 `IOMMU_NONE`（→ `MEMTX_ERROR`）；**MSI 区间 0xFEE00000–0xFEF00000 恒放行**（中断非数据 DMA）。
- 每 VF 一个 `address_space_init` 包住其 IOMMU region，`vf_config_apply` 时建、`vf_teardown` 释放。
- `cosim_dma_as(s, rid, addr)` 选 AS：`vf_iommu` off → PF bus-master AS（== `pci_dma_*`，**byte-identical**）；on 且 rid 命名某 VF 且 addr 非 MSI → 该 VF 窗口 AS。所有 `pci_dma_read/write(PCI_DEVICE(s))` 改走 `cosim_dma_rd/wr(s, requester_id, ...)`（含 atomic）。越界→log `IOMMU BLOCK`+`complete_dma(tag,1)`。
- opt-in prop：`vf_iommu=on,vf_dma_base=...,vf_dma_size=...`（默认 off=passthrough）。sibling PF 继承 flag。

**验证**（num_pfs=4, 2 VF；win base=0x30000000 size=0x1000000/VF：PF0-VF0=[0x30000000,0x31000000) rid=0x0104，PF0-VF1=[0x31000000,0x32000000) rid=0x0108）：

| 例 | requester | 目标 GPA | 结果 |
|---|---|---|---|
| A write | VF0 0x0104 | 0x30002000 自窗 | `DMA write OK` ✓ |
| B write | VF0 0x0104 | 0x31002000 VF1 窗 | `IOMMU BLOCK write (out-of-window)` ✓ |
| C write | VF0 0x0104 | 0x50000000 全窗外 | `IOMMU BLOCK write` ✓ |
| D write | VF1 0x0108 | 0x31003000 自窗 | `DMA write OK` ✓ |
| E read | VF0 0x0104 | 0x30002000 自窗 | `DMA read OK` ✓ |
| F read | VF0 0x0104 | 0x31002000 邻窗 | `IOMMU BLOCK read` ✓ |

- **VF0 被挡在 0x31002000，VF1 却能写 0x31003000（同区）** → 窗口按 requester_id 隔离，正是 host IOMMU 语义。
- **MSI-X 无回归**：vf_iommu on 时 vfio VF0 `count=8`、`VEC0-3_IRQ_RECEIVED`、`MSIX_MULTIVEC_DONE ok=4/4`；QEMU log `DMA write OK GPA=0xfee00000 rid=0x0104`（MSI 走 PF AS 白名单，无 BLOCK）。
- 数据落地由 `DMA write OK`（`dma_memory_write`→`MEMTX_OK` 真写 RAM）证明；`IOMMU BLOCK`=`MEMTX_ERROR` 未写。（`/root/mmio` 读 System RAM 被 `CONFIG_STRICT_DEVMEM` 挡，非隔离结果。）

**运行**：`/tmp/qemu_iommu_run.sh`（QEMU 加 `vf_iommu=on,vf_dma_base=0x30000000,vf_dma_size=0x1000000`）+ startvcs.sh(NUM_PFS=4)。QEMU 是 TCP server，须先起 QEMU bind、再重启 simv 连入。

## 6.10 ATS/PRI 设备侧地址翻译建模 ✅

**目标**：建模 PCIe ATS（Address Translation Services）设备侧翻译 + PRI（Page Request Interface）。平台是**功能级 over-bridge 模型**（非门级 TLP），ATS/PRI 按功能接入现有 DMA 通道，EP-doorbell 驱动（同 DMA/MSI-X 验证法）。

**协议扩展**（`bridge/common/cosim_types.h`，加法式、`dma_req_t` 仍 32B、不破 wire）：
- `DMA_DIR_ATS_TRANSLATE=5`：device→RC Translation Request，host_addr=IOVA。RC 回 DMA_DATA(8B translated PA)+DMA_CPL(status 0=grant/1=deny)。
- `DMA_DIR_ATS_PAGE_REQ=6`：PRI Page Request。cpl.status 0=PRG success/1=fail。
- `DMA_AT_TRANSLATED=0x80000000`（OR 进 direction 高位）：AT=10，host_addr 已翻译，RC 信任并**绕过 per-VF 窗口**。

**QEMU**（`cosim_pcie_rc.c`）：cb 顶 `dir=DMA_DIR_BASE(direction); at=DMA_DIR_IS_TRANSLATED(direction)`。
- `cosim_ats_translate(s,rid,iova,&pa,&perm)`：复用窗口策略但**不访存**——窗内 grant+identity PA+RW，窗外 deny，MSI 区恒 grant，vf_iommu off 时 identity passthrough grant。
- ATS_TRANSLATE 分支 → `complete_dma_with_data`(8B PA, status=grant?0:1)。ATS_PAGE_REQ → `complete_dma`(present?0:1)。
- `cosim_dma_as(...,translated)`：`translated` 时返 PF AS（绕窗，已授权可信）。write/read 传 `at`。

**VCS**：`bridge_vcs.c` 3 DPI（`ats_translate_rc`/`dma_write_rc_rid_at`/`ats_page_req_rc`，`dma_write_rc_impl` 泛化加 direction 参）；`bridge_vcs.sv` import；EP doorbell（`cosim_xrc_driver.sv`）ctrl **bit4=0x10 ATS**（translate→grant 则 AT=10 write / deny 则 skip）、**bit5=0x20 PRI**。

**验证**（vf_iommu on，VF0 rid=0x0104 win=[0x30000000,0x31000000)）：

| doorbell | IOVA | QEMU log | EP log |
|---|---|---|---|
| bit4 ATS | 0x30002000 自窗 | `ATS translate GRANT PA=0x30002000 perm=0x3` + `DMA write(AT) OK GPA=0x30002000 tag=4500` | `ATS GRANT ... AT-write pattern=0x.. ret=0` |
| bit4 ATS | 0x31002000 邻窗 | `ATS translate DENY PA=0x0` | `ATS DENY (no translation, DMA skipped) ret=1` |
| bit5 PRI | 0x30002000 自窗 | `PRI page-req SUCCESS` | `PRI SUCCESS ret=0` |
| bit5 PRI | 0x50000000 窗外 | `PRI page-req FAIL` | `PRI FAIL ret=1` |

- **隔离在授权时强制**：邻窗/窗外 IOVA 拿不到翻译（DENY）→ device 无地址 → 不 DMA。真实 ATS 安全语义。
- **AT=10 translated DMA 绕窗口**：GRANT 后 EP 用 translated PA + `DMA_AT_TRANSLATED` 写 → QEMU `write(AT)`（`cosim_dma_as` 返 PF AS，不再过窗）→ 落地。
- 无回归：与 §6.9 IOMMU 同栈，MSI-X/DMA 路径不变。
- **未做（后置）**：ATS Invalidation（window 变时 RC 发 invalidation → device ATC 失效）；PASID；config-space ATS(ext cap 0x0F)/PRI(0x13) cap 广告（config-bypass 下 DUT 拥有，guest 无 ATS 驱动故仅 lspci 可见性，非功能路径）。

**构建**：QEMU@58 14:23；libcosim_bridge.a@53 22:13（`scripts/build_cosim_lib.sh`）；simv@53 22:14（cleanrebuild53.sh）。改动：cosim_types.h/cosim_pcie_rc.c/bridge_vcs.c/bridge_vcs.sv/cosim_xrc_driver.sv。

## 6.11 ATS Invalidation 闭环（RC→device ATC 失效）✅

**目标**：闭合 ATS 环——device 侧 ATC（Address Translation Cache）+ RC 发起的 Invalidation。与 Translate/PRI（device→RC）**反向**：RC→device 发起，device 响应。

**RC→device 请求-响应原语**：复用 `bridge_send_tlp_and_wait`（QEMU 主线程发 TLP 等 completion，MMIO/config read 同款），无新线程。加 `TLP_ATS_INVAL=17`（加法式、tlp_entry_t 仍 112B）。

**QEMU**（`cosim_pcie_rc.c`）：`cosim_vf_invalidate_atc(s)` 对每 VF 发 `TLP_ATS_INVAL`(addr=win_base, target_bdf=vf_bdf) via `bridge_send_tlp_and_wait_timed(5000ms)`，等 EP completion=ACK。`cosim_vf_teardown(s, invalidate)` 加参：vf_config_apply 传 true（config-write 路径 transport 活、VCS polling），exit 传 false（transport 拆除中不发）。**触发 = VF 窗口 teardown**（真实语义：mapping 移除→invalidate device ATC）。

**EP**（`cosim_xrc_driver.sv`）：
- **ATC**：`ep_atc_iova[vf_bdf]`/`ep_atc_pa[vf_bdf]` per-VF 缓存。
- **bit4 ATS 改 ATC-aware**：ATC hit(iova 匹配)→用缓存 PA 不 re-translate；miss→translate+填 ATC。
- **invalidation handler**：request_loop 认 `dpi_type==BV_TLP_ATS_INVAL(17)`→按 target_bdf 删 ATC→`send_cpl_scalar_rc`(=ACK)。

**验证**（vf_iommu on，VF0 rid=0x0104）：

| 阶段 | 证据 |
|---|---|
| ATC fill | EP `ATS ATC MISS→GRANT iova=0x30002000 pa=0x30002000 (cached)`；QEMU `ATS translate GRANT tag=4200` + `DMA write(AT) OK` |
| ATC hit | EP `ATS ATC HIT (cached, no re-translate)` —— 多次 AT-write 仅 1 次 translate |
| Invalidation 闭环 | disable(sriov_numvfs=0)→QEMU `[send_tlp] type=17 tag=442 addr=0x30000000`→`ATS invalidate VF 0x0104 -> ACK` + VF 0x0108 ACK |
| EP flush | EP `ATS INVALIDATE bdf=0x0104 -> ATC entry FLUSHED`、`0x0108 -> no ATC entry (clean)`(0x0108 未缓存) |

**闭环**：RC 发 TLP_ATS_INVAL → EP 刷 ATC → 回 completion → QEMU `bridge_send_tlp_and_wait` 解阻收 ACK。ATC MISS→HIT→FLUSHED 三态完整；flush 后 device ATC 空→下次访问 re-translate（`FLUSHED` 蕴含）。无回归（同 §6.9/§6.10 栈）。

**坑**：VF disable/re-enable churn 后 `run/cons.sock` 偶发瞬时拒连（console flakiness，非 bug；QEMU alive，重连即可）。改 `cosim_types.h` 无新 DPI 但仍须 `build_cosim_lib.sh` 重建 .a（enum 进 transport.o）再 cleanrebuild53。**构建**：QEMU@58 14:49；.a@53 22:51；simv@53 22:51。改动：cosim_types.h/cosim_pcie_rc.c/cosim_xrc_driver.sv。doc §6.11。

## 6.12 VIP 层 ATS TLP 桥接（真实 DUT 路径）✅

**背景**：§6.10/§6.11 的 ATS 建在**功能级/DPI 层**（EP 直接调 `bridge_vcs_ats_translate_rc`），真实 RTL DUT 发的是**真 PCIe ATS TLP**（header AT 字段、Translation Request/Completion）。缺口：VIP 不认 AT 字段、rx_loop 把 DUT 发起的入向 TLP 全丢弃（"DMA path TODO"）。本节补 VIP 层桥接，使真实 DUT 的 ATS TLP 跑通。

**AT 字段打通**（真 wire TLP 携带 AT）：
- `pcie_tl_tlp` 基类加 `rand bit [1:0] at = 2'b00`（默认 untranslated，向后兼容）。
- `pcie_tl_codec`：encode DW0[11:10]=`tlp.at`（原硬编码 2'b00）；decode `tlp.at = dw0[11:10]`。SV_IF_MODE 下真 DUT wire TLP 的 AT 被解出。

**rx_loop 桥接**（`cosim_xrc_driver.sv`）：DUT 发起(非 completion)的 mem TLP → `handle_dut_ats_tlp(mem)`（原来 log+drop）：
- **AT=01 Translation Request** → `bridge_vcs_ats_translate_rc` 问 QEMU RC/IOMMU → 建 **Translation Completion**(`TLP_CPLD`, `at=10`, payload=8B translated PA, status SC/UR) → `send_tlp` 回 DUT。
- **AT=10 Translated write** → `bridge_vcs_dma_write_rc_rid_at`（RC 绕窗，信任已授权 PA）。
- **AT=00** → 普通 DUT DMA（log TODO）。

**验证**（doorbell bit6=0x40 合成一个真 DUT Translation Request TLP(AT=01) 喂 `handle_dut_ats_tlp`，模拟真实 DUT RQ 发起）：
- 自窗 iova=0x30002000：EP `emit DUT Translation Request(AT=01) -> VIP handler` → `VIP ATS: DUT Translation Request bdf=0x0104 -> GRANT pa=0x30002000; sent Translation Completion tag=85`；QEMU `ATS translate GRANT PA=0x30002000`。
- 窗外 iova=0x50000000：QEMU `ATS translate DENY`（→ Completion status UR）。
- 真实 DUT 换入(SV_IF_MODE)：monitor 解 wire TLP(AT 已解)→ rx_loop → 同 `handle_dut_ats_tlp`，无需改。

- **未做后置**：AT=10/AT=00 的 DUT read → 回 DUT 的 CplD（通用 DUT-initiated-read 路径 TODO）；Invalidation 以真 Message TLP(RC→DUT) 发（当前走 DPI `TLP_ATS_INVAL`，§6.11）；ATS(0x0F)/PRI(0x13) ext-cap 广告（config-bypass DUT 拥有）。测试用合成注入(bit6) 而非真 DUT wire 发起，但走的是真实 `handle_dut_ats_tlp`+codec AT 路径。
- 无回归：AT 默认 0、codec 向后兼容、bit4 DPI-shortcut/MMIO/DMA/MSI-X/invalidation 全不变。

**构建**：QEMU@58 14:49(无变)；simv@53 23:13(relink，.a 无变)。改动：pcie_tl_tlp.sv/pcie_tl_codec.sv/cosim_xrc_driver.sv。doc §6.12。

## 6.13 VIP 层补全（DUT read→CplD + 真 Message TLP invalidation）✅

承 §6.12，补齐 VIP 层剩余两项，使真实 DUT 的 ATS 全路径过 VIP。

**(A) DUT-initiated read → 回 DUT CplD**（补全 DMA 数据面 AT=00/10 × read/write 四组合）：
- DPI：`dma_read_rc_impl` 泛化加 direction → `bridge_vcs_dma_read_rc_rid_at`（AT=10 read，RC 绕窗；QEMU cosim_dma_cb read 路径本就按 `at_translated` 旁路）。
- `handle_dut_ats_tlp` else 分支重写：`TLP_MEM_RD` → `bridge_vcs_dma_read_rc_rid[_at]` 读 guest RAM → 建 **CplD**(`TLP_CPLD`, at=mem.at, payload=data, byte_count) → `send_tlp` 回 DUT；`TLP_MEM_WR` → `dma_write_rc_rid[_at]`。translated=`at==2'b10` 选 `_at` 变体。
- **验证**：bit4 AT-write pattern `0xd00dbeef`→0x30002000；bit7(=0x80) 合成 DUT translated(AT=10) READ → EP `VIP: DUT translated(AT=10) read bdf=0x0104 addr=0x30002000 len=4 ret=0 -> CplD data[0]=0xd00dbeef`（**CplD 带回真数据**）；QEMU `DMA read(AT) OK GPA=0x30002000`。

**(B) Invalidation 以真 Message TLP(RC→DUT) 发**：
- `msg_code_e` 加 `MSG_ATS_INVALIDATION=8'h01`。
- request_loop `BV_TLP_ATS_INVAL` handler：收 QEMU 的 DPI invalidation 后，先建 **`pcie_tl_msg_tlp`**(kind=TLP_MSG, type=TLP_TYPE_MSG_ID, msg_code=MSG_ATS_INVALIDATION, target_id=vf_bdf, msg_addr=win_base) `send_tlp` 发向 DUT（真实 DUT 收到刷自身 ATC 并回 Invalidation Completion）；stand-in EP 仍 DPI flush ATC + `send_cpl` ACK QEMU。
- **验证**：disable(numvfs=0)→EP `RC0 sent ATS Invalidate Request Message -> DUT bdf=0x0104 iova=0x30000000` + `ATS INVALIDATE bdf=0x0104 -> ATC entry FLUSHED`；QEMU `ATS invalidate VF 0x0104 -> ACK`。

- **真实 DUT 换入**：monitor 解 wire TLP(AT/msg_code 已解)→ rx_loop → 同 `handle_dut_ats_tlp`；invalidation Message 走 wire 到 DUT。
- **未做后置**：真实 DUT 的 **Invalidation Completion 回程**（当前 stand-in 直接 DPI ACK；真 DUT 应回 Invalidation Completion，rx_loop 桥回 ACK — 需真 DUT 测）；ATS(0x0F)/PRI(0x13) ext-cap 广告、PASID。
- 无回归：新 read DPI/msg_code 加法式、AT 默认 0、bit4-6/MMIO/DMA/MSI-X 全不变。**构建**：QEMU@58 14:49(无变)；.a+simv@53 09:06。改动：bridge_vcs.c/.sv、pcie_tl_types.sv、cosim_xrc_driver.sv。doc §6.13。

## 6.14 ATS Invalidation Completion 回程（真实 DUT 往返闭环）✅

承 §6.13(B)：原来 RC 发 Invalidate Message 后**立即** DPI ACK QEMU（未等 DUT）。真实 DUT 收 Message→刷自身 ATC→回 **Invalidation Completion**（CC channel）→RC 才应 ACK。本节补这条回程。

**实现**（`cosim_xrc_driver.sv`）：
- pending 状态：`pend_inval_qtag[msg_tag]=qemu_tag`、`pend_inval_bdf[msg_tag]=vf_bdf`。
- request_loop `BV_TLP_ATS_INVAL`：发 Invalidate Message(tag=dpi_tag[9:0]) → **记 pending，不再立即 ACK**；stand-in DUT 刷 ATC + 合成 **Invalidation Completion**（`TLP_CPL`, tag=msg_tag）经 `m_rx_fifo.analysis_export.write()` 喂给 rx_loop（真实 DUT 则从 monitor 解 wire cpl 进 rx_loop）。
- rx_loop：收 `pcie_tl_cpl_tlp`，若 `pend_inval_qtag.exists(cpl.tag)` → 是 Invalidation Completion → `bridge_vcs_send_cpl_scalar_rc(qemu_tag)` ACK QEMU + 清 pending；否则走原 `forward_completion_to_qemu`。
- 命名歧义坑：`TLP_CPL` 在 pcie_tl_pkg 与 cosim_bridge_pkg 双定义 → 须 `pcie_tl_pkg::TLP_CPL`（`TLP_CPLD` 无冲突）。

**验证**（disable(numvfs=0) 触发，tag 0x1b3/0x1b4）：
- `RC0 sent ATS Invalidate Request Message -> DUT bdf=0x0104 tag=0x1b3 (await Completion)`
- `EP(stand-in) ATC bdf=0x0104 -> clean, returning Invalidation Completion`
- `RC0 ATS Invalidation Completion from DUT bdf=0x0104 tag=0x1b3 -> ACK QEMU tag=0x1b3`（rx_loop 桥回）
- QEMU `ATS invalidate VF 0x0104 -> ACK`（经 rx_loop 后收到，非 request_loop 立即）。0x0108 同。

**完整往返**：QEMU→RC(TLP_ATS_INVAL)→RC 发 Invalidate Message→DUT 刷 ATC+回 Invalidation Completion→RC rx_loop 收→ACK QEMU。真实 DUT 换入无需改（monitor 解 wire Completion→rx_loop 匹配 pending）。
- 无回归：pending 匹配失败才走原 completion 路径；QEMU 侧 `bridge_send_tlp_and_wait_timed` 仍 ≤5s 内收 ACK。**构建**：QEMU@58 14:49(无变)；simv@53 09:22。改动：cosim_xrc_driver.sv。doc §6.14。

## 6.15 ATS/PRI Extended Capability 广告 ✅

config-bypass 下 DUT(VCS func_manager)拥有 config，补 PF 的 ATS(0x000F)/PRI(0x0013) 扩展能力 → guest lspci/内核可见可 enable。

**实现**：
- `pcie_tl_types.sv` 加 `EXT_CAP_ID_PRI=16'h0013`（ATS=0x000F 已有）。
- `pcie_tl_func_manager.sv build_topology` 每 PF 在 AER(@0x300) 后注册：**ATS @0x350**（data[4]：Cap Reg bit5=Page Aligned；Control=0 Enable off/STU=0）+ **PRI @0x360**（data[12]：Ctrl/Status=0；Outstanding Page Request Capacity=32）。`register_ext_capability` 自动链 next_ptr（AER→ATS→PRI→0）。

**验证**（guest `dd /sys/.../0000:01:00.0/config` + QEMU cfg_read）：
- ATS @0x350 = `0x3601000f`：cap_id=0x000F(ATS)、ver=1、next=0x360 ✓
- PRI @0x360 = `0x00010013`：cap_id=0x0013(PRI)、ver=1、next=0(链尾) ✓
- 链 AER(0x300)→ATS(0x350)→PRI(0x360) 正确。guest 内核 `pci_find_ext_capability(ATS/PRI)` 可发现。

**VF 级广告**（`func_manager` vf_ctx 循环，init_msix 后）：每 VF ext-cap 链空 → **ATS @0x100**（链头）+ **PRI @0x110**。验证：VF 01:00.4 @0x100=`0x1101000f`(ATS,next=0x110)、@0x110=`0x00010013`(PRI,next=0)；PF @0x100=`0x2001000e`(ARI，PF 独立链)。PF+VF 均广告，guest 见 per-VF ATS。
- SV 坑：begin 块内变量声明须在语句前（`vats`/`vpri` 两声明提前，否则 Error-[SE]）。

- **说明**：cap Enable 位默认 0，guest 写 Control.Enable 才启用（config-bypass 转 VCS，当前 stub 不强制 gate）；数据面 ATS TLP 由 VIP 桥接(§6.12–6.14)承载。
- 无回归：新 ext-cap 加在链尾(PF)/新链(VF)，不影响 ARI/SR-IOV/AER/MSI-X。**构建**：QEMU@58 14:49(无变)；simv@53 09:57。改动：pcie_tl_types.sv、pcie_tl_func_manager.sv。doc §6.15。

## 6.16 guest ATS 驱动 enable + 数据面 gating ✅

承 §6.15：ATS/PRI cap 已广告但 Control.Enable 不 gate。本节让 guest 写 Enable 后数据面才放行 ATS（模拟 `pci_enable_ats`）。

**Enable 落地**（无需改代码）：guest 写 ATS Control Register Enable(bit15@cap+4) → config-bypass `handle_cfg_write_bdf` → `func_mgr.cfg_write` → `ctx.cfg_mgr.write` 落 func cfg_mgr cfg_space（与 ext-cap 同源）。

**gating**（`cosim_xrc_driver.sv`）：
- `ats_enabled_for(bdf)`：`func_mgr.lookup_by_bdf(bdf).cfg_mgr.read(ats_off+4)` 取 [31]（=Control bit15 Enable）。ATS cap off：VF=0x100/PF=0x350。
- `handle_dut_ats_tlp`：`ats_en = (at==00)?1:ats_enabled_for(rid)`。AT=01 未 enable→跳 translate、Completion status UR、log BLOCKED；AT=10 未 enable→log BLOCKED+return；AT=00 不 gate。

**验证**（VF 01:00.4，two-phase）：
- Phase1 ATS off：bit6 Translation Request → EP `BLOCKED — ATS not enabled (Control.Enable=0)`；QEMU 无 ATS translate（gate 在 DPI 前挡）。
- 写 Enable：`setpci -s 01:00.4 0x104.l=0x80000020`（DW 写避 sub-DW 合并坑；[31]=Enable/[15:0]=Cap Reg 0x20）→ 读回 `0x80000020`✓。
- Phase2 ATS on：bit6 → EP `GRANT pa=0x30002000; sent Translation Completion`；QEMU `ATS translate rid=0x0104 -> GRANT`。

**PRI Enable gating**（同理）：`pri_enabled_for(bdf)`=`cfg_mgr.read(pri_off+4)[0]`（PRI Control.Enable bit0；VF pri_off=0x110/PF=0x360）。bit5 page-req handler gate：未 enable→BLOCKED，enable→SUCCESS。验证：Phase1 PRI off→bit5→EP `PRI page-req BLOCKED — PRI not enabled`+QEMU 无 page-req；`setpci -s 01:00.4 0x114.l=0x00000001`(Enable bit0) 读回 0x1；Phase2→bit5→EP+QEMU `PRI page-req -> SUCCESS`。

- **说明**：真实 guest 用 `pci_enable_ats()`/`pci_enable_pri()` 写同一 Enable 位。
- 无回归：off 时 AT≠00/PRI 才 gate，AT=00/MMIO/DMA/MSI-X 不变。**构建**：QEMU@58 14:49(无变)；simv@53 10:32。改动：cosim_xrc_driver.sv。doc §6.16。

## 6.17 PASID（Process Address Space ID）✅

ATS/PRI 最后一环：PASID cap 广告 + 携带 + gating + RC 归属。

**广告**（`func_manager`）：`EXT_CAP_ID_PASID=0x001B`（已有）。PF PASID @0x370（链在 PRI 后）+ VF PASID @0x120（链尾）。Cap Reg [12:8] Max PASID Width=16。验证：PF 0x370=`0x0001001b`、VF 01:00.4 0x120=`0x0001001b`（id=0x001B,ver=1）✓。

**携带**（wire 不变）：PASID[15:0] 复用 `dma_req_t._pad_rid`（纯 padding）。`bridge_vcs_ats_translate_rc_pasid(rc,rid,pasid,iova,out_pa)`（重构 `ats_translate_impl` 加 pasid 参）。EP：doorbell **0x14** 设 `ep_pasid[vf_bdf]`；`handle_dut_ats_tlp` AT=01 若 pasid≠0→`translate_rc_pasid`。QEMU `cosim_dma_cb` ATS 分支读 `req->_pad_rid` 记 log。

**gating**：`pasid_enabled_for(bdf)`=`cfg_mgr.read(pasid_off+4)[16]`（PASID Control.Enable=Control bit0=DW bit16，因 Control 在 [31:16]；VF off=0x120/PF=0x370）。AT=01：`pasid_ok=(pasid==0)||pasid_enabled_for(rid)`，未 enable→BLOCKED。

**验证**（VF 01:00.4，pasid=7，ATS 已 enable）：
- PhaseA PASID off：bit6→EP `pasid=0x00007 Translation Request BLOCKED — PASID not enabled`；QEMU 无 translate。
- 写 Enable：`setpci -s 01:00.4 0x124.l=0x00010000`（PASID Control @0x124，Enable=DW bit16）读回 `0x00010000`✓。
- PhaseB PASID on：bit6→EP `pasid=0x00007 ... -> GRANT`；QEMU `ATS translate rid=0x0104 pasid=0x00007 -> GRANT`（PASID 携带+归属）。

**per-PASID window 隔离**（`cosim_pcie_rc.c`）：`cosim_ats_translate` 加 pasid 参。pasid=0→全 VF 窗口(兼容)；pasid>0→VF 窗口内子槽 slot=[win_base+pasid*COSIM_PASID_WIN_SIZE(1MB), +1MB)，越槽 DENY，slot 超出 VF 窗口 DENY。callers 传 `req->_pad_rid`。验证(VF0，ATS+PASID enabled)：pasid=7 iova=0x30700000(slot7)→GRANT / iova=0x30002000(slot0)→DENY；pasid=2 iova=0x30700000(slot7)→DENY / 0x30200000(slot2)→GRANT。**同 iova 0x30700000 → pasid7 GRANT/pasid2 DENY** = per-PASID 地址空间隔离（各 PASID 限自己子槽）。

- **说明**：真实 guest 用 `pci_enable_pasid()`。
- 无回归：`_pad_rid` 原为 padding、pasid=0 走无 PASID 路径。**构建**：QEMU@58 02:48；.a+simv@53 10:49。改动：func_manager.sv、bridge_vcs.c/.sv、cosim_xrc_driver.sv、cosim_pcie_rc.c。doc §6.17。

**至此 ATS/PRI/PASID 全景闭环**（真实 DUT ready，无需改 VIP）：配置广告(PF+VF ATS/PRI/PASID) → 使能 gating(ATS/PRI/PASID Control.Enable) → 数据面(Translation Request/Completion + PASID 携带 + AT=10 DMA + read CplD) → 失效(Invalidation Message + Completion 回程)。

## 7. ETH 真实网卡数据面 —— 现状 + 缺口（留待真实 DUT 验证）

基础设施齐全但**在 cosim 流程 inert，datapath 被 stub**。真实 DUT 换入时按此图接线。

**已有**：
- `eth_frame_t`(eth_types.h)、双向 SHM 环 `eth_shm`(eth_shm.c，"/cosim_eth0")、link model(drop/rate/FC，link_model.c)。
- DPI：`vcs_eth_mac_init_dpi`/`send_frame`/`poll_frame`/`send_raw`/`recv_raw`(eth_mac_dpi.c)。
- **virtqueue 处理**（`bridge/vcs/virtqueue_dma.c`，真实实现）：`vcs_vq_configure(q,desc/avail/used_gpa,size)`、`vcs_vq_process_tx()`(DMA 读 avail→desc 链→跳 12B virtio-net hdr→取 payload→`vcs_eth_mac_send_raw`→写 used)、`vcs_vq_process_rx()`(poll `recv_raw`→`rx_inject_one` 写 virtio-net hdr+frame 到 guest RX desc→写 used)。
- `tools/eth_tap_bridge.c`：eth_shm(Role B) ↔ TAP，真实网络 egress/ingress。**需 sudo(/dev/net/tun)，ryan 无权限**。
- config_proxy.sv 已建 virtio PCI cap 结构：COMMON_CFG@0x50、NOTIFY_CFG@0x64、ISR@0x78、DEVICE_CFG@0x88、MSI-X@0x98。guest `eth0 UP`(config 探测通)。

**缺口（包不流动的原因）**：
1. **datapath 未链入**：`.a` 只 `eth_shm.o`；`virtqueue_dma.c`/`eth_mac_dpi.c`/`eth_port.c`/`link_model.c` 仅 `build_cosim_lib.sh --with-eth` 才编（需 VCS gcc + svdpi.h），当前链的是 `vq_eth_stub.c`(vcs_vq_* 全返 0)。
2. **SV 未驱动**：`cosim_xrc_driver` 从不调 `vcs_eth_mac_init_dpi`/`vcs_vq_configure`/`vcs_vq_process_tx`/`vcs_vq_process_rx`。
3. **virtio ring 未捕获**：guest 写 COMMON_CFG 的 queue_desc/avail/used_lo/hi + queue_enable + notify kick（MWr 到 device BAR）未解码→`vcs_vq_configure`/`vcs_vq_process_tx`。插入点=request_loop 的 MWr handler（现只处理 VF doorbell/aperture）。
4. **无 egress peer**：frame 到 eth_shm 后需 Role-B 消费者；tap_bridge 要 sudo，或用无 sudo 的 in-proc loopback peer。
5. **TX/RX 中断未接**：process_tx/rx 后未 `bridge_vcs_raise_msi` → guest 驱动收不到完成中断。

**Phase 1 计划（选定：Guest TX egress 端到端）**：链真 virtqueue+eth_mac→SV init eth MAC + 捕获 virtio COMMON_CFG queue GPA + notify→`vcs_vq_process_tx`→eth_shm→Role-B peer reader 验证收到 guest 发的包(ping/arp)。→ 真实 DUT 验证。

## 待办

- [x] DMA `requester_id` 用真实 VF BDF（`_rc_rid` DPI 变体，见 §5.2）
- [x] 多 VF 并发数据面测试（VF0/VF1 各自 gpa/pattern round-trip 通，见 §5.2）
- [ ] MSI-X guest 收中断（需 VF 绑真驱动，当前 `virtio-pci: leaving for legacy driver` 无 handler）
- [x] 4 PF 枚举（Phase 1，§6.5）—— rc.c 多 PF 管道 + ARI next-func 链
- [x] 多 PF + VF（Phase 2，§6.6）—— VF offset=stride=num_pfs 交织，跨 PF VF 数据面 + rid 归属通
- [x] 大规模 4PF×256VF=1024（§6.7）—— cross-bus VF 无需 stub（vendor 来自 cap，BAR 来自 aperture），root port bus/mem-reserve；1024 VF 全枚举 + 跨 bus/PF 数据面通
- [x] cross-bus VF 的 `from=vf` 标签精确化（`cosim_rid_is_vf` 改按 aperture VF BDF 范围判断）
- [x] MSI-X guest 收中断闭环（§6.8，VFIO noiommu + EP MSI-X table 捕获/fire，`MSIX_IRQ_RECEIVED`）
- [x] 按 VF AS 路由 DMA 做真隔离（§6.9）—— per-VF windowed IOMMUMemoryRegion，DMA 走 `cosim_dma_as(rid)`，越界/邻窗 BLOCK，MSI 白名单无回归；opt-in `vf_iommu=on`
- [x] ATS/PRI 设备侧地址翻译建模（§6.10）—— Translation Request/Completion + AT=10 translated DMA 绕窗 + PRI Page Request/PRG，EP-doorbell bit4/bit5 驱动，隔离在授权时强制
- [x] ATS Invalidation 闭环（§6.11）—— RC→device `TLP_ATS_INVAL` via `bridge_send_tlp_and_wait`，EP ATC fill/hit/flush + completion ACK，窗口 teardown 触发
- [x] VIP 层 ATS TLP 桥接（§6.12）—— AT 字段进 TLP+codec，rx_loop DUT-initiated → `handle_dut_ats_tlp`（AT=01 Translation Request→Completion / AT=10 translated write），真实 DUT 路径打通
- [x] VIP 层补全（§6.13）—— DUT read→CplD(AT=00/10)、Invalidation 以真 Message TLP(MSG_ATS_INVALIDATION) 发 DUT
- [x] 真实 DUT 的 Invalidation Completion 回程桥接（§6.14）—— pending + rx_loop 收 Completion→ACK QEMU
- [x] ATS(0x0F)/PRI(0x13) ext-cap 广告（§6.15）—— PF @0x350/0x360，链 AER→ATS→PRI，guest 内核可见
- [x] VF 级 ATS/PRI 广告（§6.15）—— 每 VF ATS@0x100→PRI@0x110，独立 ext-cap 链
- [x] guest ATS 驱动 enable + gating（§6.16）—— Control.Enable 写落 func cfg_mgr，数据面 `ats_enabled_for` gate（off 拒/on 放行）
- [x] PRI Enable gating（§6.16）—— `pri_enabled_for` gate bit5 page-req（off BLOCKED/on SUCCESS）
- [x] PASID（§6.17）—— cap 广告(PF/VF) + `_pad_rid` 携带 + `pasid_enabled_for` gating + QEMU 归属 + **per-PASID window 隔离**（子槽，同 iova 不同 pasid 不同授权）
- [ ] 后续（可选）：ETH 真实网卡数据面
