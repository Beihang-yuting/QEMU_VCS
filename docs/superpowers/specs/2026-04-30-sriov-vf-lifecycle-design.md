# SR-IOV VF 完整生命周期验证设计

**日期**: 2026-04-30
**状态**: Draft
**目标**: 在 cosim-platform 上实现完整的 SR-IOV VF 动态创建/销毁流程，Guest 通过标准 Linux `sriov_numvfs` 接口操作

---

## 背景与问题

cosim-platform 已支持 4PF multifunction 设备（00:03.0~00:03.3），SR-IOV capability 正确暴露。但 VF 动态创建不工作，存在三个障碍：

1. **VF devfn 冲突**：`pcie_sriov_pf_init` 使用 `vf_offset=1, vf_stride=1`，VF 的 devfn 与相邻 PF 重叠
2. **Q35 root bus 无 ACPI hotplug**：QEMU 的 `acpi_pcihp_device_plug_cb` 在 Q35 root bus 上找不到 `acpi-pcihp-bsel` 属性，VF 的 `qdev_realize` 失败
3. **无 PF 驱动**：Guest 内没有匹配 `abcd:1234` 的驱动，无法通过 sysfs 操作 SR-IOV

## 设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 验证目标 | 完整 SR-IOV 生命周期 | Guest 通过标准 sriov_numvfs 动态创建/销毁 VF |
| PF 拓扑 | 多 Function 同 slot | 符合真实多口网卡（如 Intel XXV710） |
| 机器类型 | Q35（不可更换） | 唯一支持 PCIe extended config space 的 x86 机器 |
| Hotplug 解决 | Patch Q35 root bus | 拓扑不变，自定义驱动切换零影响 |
| PF 驱动 | Stub 驱动 + 自定义驱动切换 | stub 快速验证，用户可切换自己的驱动 |
| Stub 驱动职责 | SR-IOV 管理 + 基础网卡收发 | ping 等基本验证在 stub 模式下可跑通 |

---

## 组件 1: QEMU Q35 Hotplug Patch

### 修改文件

`hw/acpi/pcihp.c`（QEMU 9.2.0）

### 修改内容

在 `acpi_pcihp_device_plug_cb` 函数中，对 SR-IOV VF 设备跳过 bsel 检查：

```c
void acpi_pcihp_device_plug_cb(HotplugHandler *hotplug_dev,
                                AcpiPciHpState *s,
                                DeviceState *dev, Error **errp)
{
    PCIDevice *pdev = PCI_DEVICE(dev);
    int bsel = acpi_pcihp_get_bsel(pci_get_bus(pdev));

    if (bsel < 0) {
        /* SR-IOV VFs don't need ACPI hotplug notification --
         * the kernel discovers them via the PF's SR-IOV capability. */
        if (pci_is_vf(pdev)) {
            return;
        }
        error_setg(errp, "Unsupported bus...");
        return;
    }
    // ... existing logic unchanged
}
```

### 原理

SR-IOV VF 不依赖 ACPI hotplug 事件。Linux 内核的 SR-IOV 子系统在 PF 驱动调用 `pci_enable_sriov()` 时，根据 PF config space 中的 SR-IOV capability 信息自行创建 VF 设备结构。

### 管理

- Patch 保存为 `qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch`
- `setup.sh` 构建 QEMU 时自动应用
- 不影响其他设备的 hotplug 行为
- `pci_is_vf()` 是 QEMU 内置 API

---

## 组件 2: cosim_pcie_pf.c VF Offset/Stride 修正

### 问题

4 个 PF 占据 func 0~3，`vf_offset=1, vf_stride=1` 导致 VF devfn 与 PF 冲突：
- PF0 (func 0) 的 VF0 = func 1 = PF1 的位置

### 修正

```c
uint16_t npfs = g_cosim_shared.num_pfs > 1
              ? g_cosim_shared.num_pfs : 1;
pcie_sriov_pf_init(pci_dev, COSIM_SRIOV_CAP_OFFSET,
                   TYPE_COSIM_PCIE_VF, s->vf_device_id,
                   s->num_vfs, s->num_vfs,
                   npfs,    /* vf_offset: skip PF functions */
                   npfs);   /* vf_stride: interleave across PFs */
```

VF 分布（4 PF, 4 VF each, offset=4, stride=4）：
- PF0 VFs: func 4, func 8 (slot+1 func 0), func 12 (slot+1 func 4), func 16 (slot+2 func 0)
- PF1 VFs: func 5, func 9, func 13, func 17
- 互不冲突

### 清理

撤销之前调试中的 hack 代码：
- 移除 realize 中的 cold-plug VF 代码（写 NumVFs + VFE + pcie_sriov_config_write）
- 移除 VF VID/DID 覆写代码
- 移除 `cosim_pcie_pf_reset` 回调

---

## 组件 3: Guest Stub 驱动（cosim_nic.ko）

### 文件

- `guest/driver/cosim_nic.c` -- 驱动源码
- `guest/driver/Makefile` -- 交叉编译 Makefile

### 模块结构

```
cosim_nic.ko
+-- PCI driver 注册 (probe / remove)
+-- SR-IOV 管理 (sriov_configure)
+-- netdev 注册 (基础网卡)
+-- 收发包 (ndo_start_xmit / NAPI poll via ETH SHM)
```

### PCI ID 匹配

- 默认匹配 VCS topology 的 VID/DID（abcd:1234）
- 模块参数支持自定义：`insmod cosim_nic.ko vid=0xabcd did=0x1234`
- 支持 `new_id` sysfs 动态绑定

### probe 流程

```
pci_enable_device
  -> pci_request_regions
  -> pci_set_master
  -> alloc_etherdev + SET_NETDEV_DEV + register_netdev
  -> 映射 BAR0 (MMIO, 转发到 VCS)
  -> MSI-X 初始化 (如果有)
```

### sriov_configure

```c
static int cosim_sriov_configure(struct pci_dev *dev, int num_vfs)
{
    if (num_vfs > 0)
        return pci_enable_sriov(dev, num_vfs);
    pci_disable_sriov(dev);
    return 0;
}
```

### 数据面

- `ndo_start_xmit`: 通过 cosim ETH SHM 通路发包
- NAPI poll: 从 ETH SHM 收包
- 复用 `bridge/common/eth_shm.h` 共享内存接口

### PF / VF 区分

同一个 `cosim_nic.ko` 同时作为 PF 和 VF 驱动：
- PF probe: 完整初始化 + SR-IOV 注册
- VF probe: 跳过 SR-IOV，只注册 netdev + 收发

通过 `pci_is_vf(pdev)` 区分。

---

## 组件 4: Setup 流程 + 驱动切换

### 命令行接口

```bash
./setup.sh --mode local --guest alpine --driver stub    # 默认
./setup.sh --mode local --guest alpine --driver custom --ko /path/to/my_nic.ko
./setup.sh --mode local --guest alpine --driver none
```

### 三种模式

| 模式 | 行为 | 场景 |
|------|------|------|
| stub | 编译打包 cosim_nic.ko，Guest 自动 insmod | 快速验证 SR-IOV 全流程 |
| custom | 用户 .ko 打包到 rootfs，Guest 自动 insmod | 用户自己的 DPU 驱动验证 |
| none | 不打包驱动 | 手动操作 / 纯配置空间验证 |

### rootfs 结构

```
guest/images/<type>/rootfs.ext4
+-- /lib/modules/
|   +-- cosim_nic.ko      (stub 模式)
|   +-- custom_nic.ko     (custom 模式)
+-- /etc/cosim/
    +-- driver.conf        # mode=stub|custom|none, ko_name=xxx
```

### Guest init 脚本修改（cosim-init）

```bash
source /etc/cosim/driver.conf
case "$mode" in
    stub|custom)
        insmod /lib/modules/${ko_name} 2>/dev/null
        echo "[cosim-init] Loaded driver: ${ko_name}"
        ;;
    none)
        echo "[cosim-init] No driver loaded (manual mode)"
        ;;
esac
```

### 交互式选择（无 --driver 参数时）

```
选择 PF 驱动模式:
  1) stub   -- 内置 cosim_nic 驱动 (默认，快速验证)
  2) custom -- 使用自定义驱动 (.ko 文件)
  3) none   -- 不加载驱动 (手动操作)
请选择 [1]:
```

### custom 模式用户指引

```
[INFO] Custom driver mode:
  1. Guest 启动后驱动已自动加载
  2. 确认 PF 绑定: lspci -k -s 00:03.0
  3. 创建 VF:  echo 2 > /sys/bus/pci/devices/0000:00:03.0/sriov_numvfs
  4. 查看 VF:  lspci | grep "Virtual Function"
  5. 如需重新加载: rmmod xxx && insmod /lib/modules/xxx.ko
```

---

## 端到端验证流程

### 启动

```bash
# 终端 A
make run-qemu NUM_PFS=4 MAX_VFS=4

# 终端 B
make run-vcs NUM_PFS=4 MAX_VFS=4
```

### Guest 内操作

```bash
# 1. 确认 PF 可见且驱动已绑定
lspci -k -s 00:03.0
# -> Kernel driver in use: cosim_nic

# 2. 查看 SR-IOV capability
lspci -vvs 00:03.0 | grep -A5 "SR-IOV"
# -> Initial VFs: 4, Total VFs: 4, NumVFs: 0

# 3. 创建 2 个 VF
echo 2 > /sys/bus/pci/devices/0000:00:03.0/sriov_numvfs

# 4. 确认 VF 出现
lspci | grep "Virtual Function"
# -> 00:03.4 ... Virtual Function
# -> 00:04.0 ... Virtual Function

# 5. 配网测试
ip addr add 10.0.0.2/24 dev eth1
ip link set eth1 up
ping 10.0.0.1

# 6. 销毁 VF
echo 0 > /sys/bus/pci/devices/0000:00:03.0/sriov_numvfs

# 7. 确认 VF 消失
lspci | grep "Virtual Function"
# -> (空)
```

### 成功标准

| 步骤 | 验证点 |
|------|--------|
| PF 枚举 | 4 PF 可见，multifunction，驱动已绑定 |
| SR-IOV cap | Initial/Total VFs 正确，VF offset/stride = npfs |
| VF 创建 | sriov_numvfs 写入触发 VF realize，lspci 可见 |
| VF 配置空间 | VF CfgRd/CfgWr 正确转发到 VCS |
| 数据面 | PF netdev ping 通 |
| VF 销毁 | sriov_numvfs=0 触发 VF unrealize，lspci 清除 |

### 不在本次 scope

- VF 数据面收发包（需要 VF 驱动 + VCS 侧 VF 数据通路）
- VF MMIO BAR 映射到用户态（VFIO passthrough 场景）
- 多 PF 同时创建 VF 的并发测试
