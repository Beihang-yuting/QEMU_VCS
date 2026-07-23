# CoSim SR-IOV: 真实硬件的 PF/VF 探测与 BAR 映射，及 cosim 实现

> 目标形态：一个 DPU 网卡，**4 个 PF，每 PF 支持 256 个 VF**，每个 PF 和 VF 都有自己的 BAR。
> 本文说明真实 PCIe/Linux 是怎么做的，再映射到 QEMU-VCS cosim 的实现（含支撑 256 VF 的 aperture 模型）。

---

## 1. 真实硬件：SR-IOV 的 BDF 与 BAR 机制

### 1.1 BDF / ARI
- 4 PF = 一个 ARI 设备的 function 0–3（或多个设备）。每个 PF 在扩展 config 空间（0x100+）有 **SR-IOV Extended Capability**。
- **VF 没有独立的 BDF 寄存器**——VF 的 RID 是**算出来**的：

  ```
  VF_RID = PF_RID + VF_Offset + vf_index × VF_Stride
  ```

  `VF_Offset`、`VF_Stride` 都在 PF 的 SR-IOV cap 里。
- 256 VF/PF 时 RID 会**跨多个 bus number**，因此**必须 ARI**（function number 变成平坦 8 位，溢出滚进后续 bus）。RC/switch 的 secondary/subordinate bus range 必须覆盖这些 RID。

### 1.2 VF BAR（与直觉不同的关键点）
- **VF 自己 config 空间里的 BAR 是只读 0**，VF 不使用自己的 BAR 寄存器。
- BAR 定义在 **PF 的 SR-IOV cap 中的 VF BAR0–5**（config 偏移 0x24–0x3C），它描述的是**一个 aperture**（一个 BAR 类型/尺寸）。
- **每个 VF 的实际 BAR 地址 = VF_BAR_aperture_base + vf_index × VF_BAR_size**（连续 striped，不是各自独立分配）。
- 示例：PF0，VF BAR0 size = 64 KB，256 VF：
  - aperture 总大小 = 256 × 64 KB = 16 MB
  - VFk 的 BAR0 = aperture_base + k × 64 KB
- `System Page Size` 寄存器控制 VF BAR 的对齐。

### 1.3 BAR sizing（OS 怎么知道尺寸）
- **PF BAR**：标准 sizing——写全 1，读回得到尺寸掩码。
- **VF BAR**：对 **PF SR-IOV cap 里的 VF BAR** 做 sizing（不是对 VF 自己的 config）。

---

## 2. Linux 内核驱动流程（真实）

```
PF probe:
  PCI 枚举 → 匹配 vendor/device → driver.probe()
  → pci_enable_device() + pci_iomap(PF BARs)   // PF MMIO 映射
  → pci_sriov_get_totalvfs()                    // 读 SR-IOV cap

VF enable:
  echo N > /sys/bus/pci/devices/<PF>/sriov_numvfs
  → PF driver.sriov_configure() → pci_enable_sriov(pf, N)
  → 写 SR-IOV cap 的 NumVFs + VF Enable
  → 内核用 VF_Offset/Stride 算每个 VF 的 RID → 为每 VF 建 struct pci_dev
  → 从 PF SR-IOV VF BAR aperture 算每 VF BAR = base + k × size → 赋给 VF 的 BAR 资源
  → 每个 VF driver.probe() → pci_iomap(VF BARs)   // VF MMIO 映射
```

**BAR 地址谁分配：**
- PF BAR：BIOS/内核在枚举时从 PCI MMIO 窗口分配，写进 PF 的 BAR 寄存器。
- VF BAR：**在 PF 枚举时就预留整个 aperture**（TotalVFs × vf_bar_size），每个 VF 的 BAR 只是 aperture 内的偏移，**不单独分配**。

---

## 3. DPU 硬件内部（VCS 要模拟的角色）

DPU 的 PCIe 控制器里有一个 **BAR → 资源解码器**：
- 进来的 MMIO TLP(addr) → 落在哪个 PF/VF 的 BAR range → 该 function 的内部寄存器块 / 队列。
- 维护一张表：`(bar_base, size) → function → 内部资源`，MMIO 时按 addr 区间解码。

**这正是 VCS 侧要做的地址解码。**

---

## 4. 映射到 QEMU-VCS cosim

| 真实硬件 | cosim 对应 |
|---|---|
| DPU 的 config space + SR-IOV cap | **VCS** `func_manager`（4 个 PF context，每 PF 一个 `sriov_cap`：TotalVFs=256、VF BAR aperture+size、VF_Offset/Stride、ARI） |
| DPU 的 BAR → 资源解码器 | **VCS** MMIO addr → function（`g_bdf_bar_base` 表 / config_proxy 路由） |
| RC / host bridge + BAR 资源 | **QEMU** 的 BAR `MemoryRegion` |

### 4.1 权责划分（本项目约定）
- **BDF**：QEMU 自管（PCI 槽位分配）。PF 的 BDF 由 QEMU `-device addr=` 决定；VF 的 BDF 由 PF BDF + ARI 派生（两边用**同一公式**）。
- **设备状态**（vendor/device/caps/BAR size/SR-IOV/VF 数）：**VCS 权威**，用户在 VCS 配置阶段随意设（按 PF index，不碰 BDF）。
- **QEMU 同步**：realize 时 `bridge_query_topology` 从 VCS **拉** BAR size / msix / num_vfs 来建自己的 region；PF 的 BDF↔pf_index 由 QEMU **报**给 VCS（bind）。
- **VF 布局**：运行期 VCS → QEMU 推 `vf_config`（每 PF 的 VF0 BDF/BAR base + stride + num_vfs + msix）。

### 4.2 ⚠️ 支撑 256 VF 的关键：aperture 模型（而非 per-VF region）
- **错误做法**：给每个 VF 每个 BAR 建一个 `MemoryRegion`。4 PF × 256 VF × 6 BAR = **6144 个 region**，不现实，也不像真硬件。
- **正确做法（对标真硬件 aperture+stride）**：**每个 (PF, BAR) 建一个 aperture region**，覆盖该 BAR 下所有 VF：

  ```
  aperture region = [aperture_base, aperture_base + num_vfs × vf_bar_size)
  ```

  MMIO handler 里按地址**解码 vf_index**：

  ```
  offset    = addr - aperture_base          // region 内偏移
  vf_index  = offset / vf_bar_size
  vf_bdf    = first_vf_bdf + vf_index × vf_bdf_stride
  pcie_addr = aperture_base + offset
  → 转发 TLP(target_bdf = vf_bdf, addr = pcie_addr)
  ```

  256 VF 只需**每 BAR 一个 region**（≤6 个/PF）。和真硬件 aperture+stride 完全一致。

- `vf_config_t` 已携带所需参数：`vf_bar_base[6]`（=aperture base）、`vf_bar_stride[6]`（=vf_bar_size）、`first_vf_bdf`、`vf_bdf_stride`、`num_vfs`。

### 4.3 实现落点
1. **VCS** `func_manager`：配 4 PF × 256 VF（每 PF `sriov_cap` 带 aperture/stride/ARI），MMIO 按 addr 解码到 VF。
2. **QEMU** `cosim_pcie_rc.c`：`cosim_vf_config_apply` 用 **aperture region + handler 内解码**（见 4.2），取代 per-VF region。
3. **BDF**：PF 由 QEMU 槽位定 + bind 报 VCS；VF BDF 由 PF BDF + ARI 派生。

---

## 5. 前置阻塞（记录，待做）
guest 目前枚举到 cosim PF 但**看不到 SR-IOV cap**（`lspci -vvv` 无 Capabilities，`sriov_totalvfs` 不存在）→ 无法 `echo N > sriov_numvfs` 触发 VF。根因在 VCS config_proxy 没把 **cap 链**（cap_ptr@0x34 + PCIe Express cap + SR-IOV ext cap@0x100）暴露给 guest。详见 memory `vf_config_sync_channel` 与 `pcie_config_sim_gap`。cap 链修好后，本文的 PF/VF/BAR 全链路即可端到端验证。

---

_相关代码：`qemu-plugin/cosim_pcie_rc.c`（QEMU 侧 BAR/VF apply）、`bridge/common/cosim_topology.h`（`vf_config_t`）、`pcie_tl_vip/src/shared/pcie_tl_{func_manager,sriov_cap,config_proxy}.sv`（VCS 侧 config + SR-IOV 模型）。_
