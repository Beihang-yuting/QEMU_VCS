# BDF 动态缓存 + Ubuntu 内核适配设计

**日期**: 2026-04-29
**状态**: 已确认

## 背景

LTS 内核（Ubuntu/Debian generic）在 cosim 环境中启动极慢。根因：内核 PCI 枚举扫描所有 BDF（256 bus × 32 dev × 8 func = 65536），每次 config space 读都转发 VCS 仿真，加上 Q35 内置设备（AHCI、USB、SMBus）的驱动初始化产生大量 guest 指令，每条指令都消耗 VCS 仿真周期。

Alpine virt 内核启动快但缺少 VFIO/RDMA/NVMe-oF 模块（CONFIG_VFIO/CONFIG_INFINIBAND 未编译），无法满足 DPU cosim 的完整验证需求。

## 目标

1. 使用 Ubuntu/Debian 标准 LTS 内核（含 VFIO、RDMA、NVMe-oF 模块），无需自编译
2. 通过 QEMU 侧 BDF 动态缓存大幅减少无效 VCS 往返
3. 通过 QEMU 启动参数精简消除 Q35 内置设备的探测开销
4. 集成到 setup.sh 构建流程中，可复现

## 设计

### 1. BDF 动态缓存

在 `cosim_pcie_rc.c` 中新增 per-BDF 缓存，拦截 config space 访问。

#### 数据结构

```c
typedef struct {
    uint16_t vendor_id;    // 缓存的 vendor ID
    bool     probed;       // 是否已探测过
    bool     valid;        // VCS 是否返回了有效设备
} bdf_cache_entry_t;

#define COSIM_MAX_BUS   256
#define COSIM_MAX_DEV   32
#define COSIM_MAX_FUNC  8

// 在 CosimPCIeRC 结构体中新增
bdf_cache_entry_t bdf_cache[COSIM_MAX_BUS][COSIM_MAX_DEV][COSIM_MAX_FUNC];
```

#### Config Read 拦截逻辑

```
cosim_config_read(bdf, offset, size):
    bus, dev, func = parse_bdf(bdf)
    entry = &bdf_cache[bus][dev][func]

    if !entry->probed:
        // 首次访问：主动读 vendor/device ID (offset 0x00)
        cpl = bridge_send_cfgrd(bdf, offset=0x00, len=4)
        entry->vendor_id = cpl.data[0:2]  // 低 16 位
        entry->probed = true
        entry->valid  = (entry->vendor_id != 0xFFFF)

        if !entry->valid:
            return 0xFFFFFFFF

        if offset == 0x00:
            return cpl.data      // 直接返回已获取的数据

    if !entry->valid:
        return 0xFFFFFFFF        // 已知不存在，快速返回

    // 有效设备 → 正常转发 VCS
    return bridge_send_cfgrd(bdf, offset, size)
```

#### Config Write 拦截逻辑

```
cosim_config_write(bdf, offset, data, size):
    bus, dev, func = parse_bdf(bdf)
    entry = &bdf_cache[bus][dev][func]

    if !entry->probed || !entry->valid:
        return  // 丢弃，设备不存在

    bridge_send_cfgwr(bdf, offset, data, size)
```

#### 效果估算

- PCI 枚举 65536 个 BDF，假设 5 个有效设备
- 无缓存：每个 BDF ~10 次 VCS 往返 = ~65 万次
- 有缓存：无效 BDF 各 1 次 + 有效 BDF 正常 ≈ 65531 + 50 = ~6.6 万次
- **减少约 90% 的 VCS 往返**

### 2. QEMU 启动参数优化

移除 Q35 内置的无关设备，减少内核初始化代码路径：

```bash
qemu-system-x86_64 \
    -M q35 -m 256M -smp 1 \
    -nodefaults \              # 移除默认 USB/VGA/并口等
    -vga none \                # 无显卡
    -no-hpet \                 # 无高精度定时器
    -device cosim-pcie-rc,... \
    -drive file=rootfs.ext4,format=raw,if=virtio \
    -kernel vmlinuz -initrd initramfs \
    -append "console=ttyS0 root=/dev/vda rw quiet" \
    -nographic -no-reboot
```

不再需要内核命令行的 `acpi=off nousb nomodeset` 等 hack。设备本身不存在，内核自然跳过。

### 3. Ubuntu 内核提取流程

#### 目标内核

| 系统 | 内核版本 | 包名 |
|------|---------|------|
| Ubuntu | 6.8.0-107-generic | linux-image-unsigned + linux-modules + linux-modules-extra |
| Debian | 6.1.0-42-amd64 | 已有（guest/images/debian/） |

#### 提取步骤

```bash
# 1. 下载三个 deb 包
apt-get download linux-image-unsigned-6.8.0-107-generic
apt-get download linux-modules-6.8.0-107-generic
apt-get download linux-modules-extra-6.8.0-107-generic

# 2. 解压提取
dpkg-deb -x linux-image-unsigned-*.deb ./extract/
dpkg-deb -x linux-modules-*.deb ./extract/
dpkg-deb -x linux-modules-extra-*.deb ./extract/

# 3. 输出到 guest/images/ubuntu/
cp extract/boot/vmlinuz-6.8.0-107-generic  guest/images/ubuntu/vmlinuz
# 模块目录: extract/lib/modules/6.8.0-107-generic/
```

#### 关键模块验证

提取后验证以下模块存在：

- `kernel/drivers/vfio/vfio.ko.zst` — VFIO core
- `kernel/drivers/vfio/pci/vfio-pci.ko.zst` — VFIO PCI
- `kernel/drivers/infiniband/core/ib_core.ko.zst` — RDMA core
- `kernel/drivers/infiniband/hw/mlx5/mlx5_ib.ko.zst` — MLX5 InfiniBand
- `kernel/drivers/nvme/host/nvme-tcp.ko.zst` — NVMe TCP
- `kernel/drivers/nvme/host/nvme-rdma.ko.zst` — NVMe RDMA
- `kernel/drivers/nvme/target/nvmet.ko.zst` — NVMe Target

#### Rootfs 构建

基于现有 Alpine rootfs（256MB）+ 注入 Ubuntu 模块：

1. 复制 Alpine rootfs 为 ubuntu rootfs
2. 扩展镜像（+200MB 给 Ubuntu 模块，Ubuntu 模块比 Alpine 大很多）
3. 通过 debugfs 删除旧模块目录，写入新模块
4. 运行 depmod 重建依赖（在 initramfs 或 rootfs init 阶段）

#### initramfs 构建

Ubuntu 模块压缩格式为 `.ko.zst`（zstd），需确保 initramfs 中包含 `zstd` 解压工具，或在 cosim-init 脚本中使用 `modprobe`（自动处理压缩格式）。

### 4. cosim-init 脚本适配

现有 `guest/cosim-init` 已有自动检测逻辑：

- `KVER=$(uname -r)` 自动获取版本号
- `find $MODDIR -name "*.ko*"` 自动匹配 `.ko.gz` 和 `.ko.zst`
- `modprobe` 自动处理压缩格式

无需修改核心逻辑，但需验证 `.ko.zst` 的 `insmod` 兼容性（busybox insmod 可能不支持 zstd，需用 `modprobe` 或预解压）。

### 5. PCIe Vendor/Device ID 说明

- **Vendor ID**：同一厂商所有 PF/VF 共享，由 PCI-SIG 分配
- **PF Device ID**：每个 PF 可不同，在各自 config space offset 0x02
- **VF Device ID**：定义在父 PF 的 SR-IOV Capability (offset 0x1A)，同 PF 下所有 VF 共享

BDF 缓存只判断 `vendor_id != 0xFFFF`，不区分 PF/VF 的 device ID，自动适配所有拓扑。

## 不改动的部分

- MMIO 读写路径（cosim_mmio_read/write）
- DMA/MSI 通道（irq_poller）
- SHM/TCP transport 层
- 现有 Alpine virt 内核支持（保留作为快速启动备选）
- cosim.sh 主流程（通过 KERNEL= 环境变量选择内核）

## 文件改动清单

| 文件 | 改动 |
|------|------|
| `qemu-plugin/cosim_pcie_rc.h` | 新增 bdf_cache_entry_t 定义和 bdf_cache 数组 |
| `qemu-plugin/cosim_pcie_rc.c` | config_read/write 加入缓存逻辑 |
| `scripts/setup-ubuntu-kernel.sh` | 新增：下载/提取 Ubuntu 内核和模块 |
| `scripts/inject-modules.sh` | 更新：支持 Ubuntu 模块注入 |
| `cosim.sh` | 更新 QEMU 启动参数增加 -nodefaults -vga none -no-hpet |
| `guest/images/ubuntu/` | 新增目录：vmlinuz + rootfs.ext4 |

## 验证计划

1. **单元验证**：BDF 缓存逻辑 — 首次 CfgRd 转发 VCS，后续无效 BDF 本地返回
2. **启动验证**：Ubuntu 内核 + BDF 缓存 — 内核成功识别 cosim 设备，其他设备跳过
3. **功能验证**：VFIO 模块加载 — `modprobe vfio-pci` 成功
4. **回归验证**：Alpine virt 内核仍可正常使用
5. **Debian 验证**：使用现有 Debian 内核 + BDF 缓存验证
