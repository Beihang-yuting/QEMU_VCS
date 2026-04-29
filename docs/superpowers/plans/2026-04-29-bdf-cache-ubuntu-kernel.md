# BDF 动态缓存 + Ubuntu 内核适配 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通过 QEMU 侧 BDF 动态缓存减少 90% 无效 VCS 往返，并集成 Ubuntu LTS 内核（含 VFIO/RDMA/NVMe-oF 模块）到 cosim 构建流程。

**Architecture:** 在 cosim-pcie-rc 设备的 config_read/config_write 中新增 per-BDF 缓存层。首次访问某 BDF 时转发 VCS 读取 vendor ID，缓存结果后对无效 BDF 直接本地返回。QEMU 启动参数加 `-nodefaults -vga none -no-hpet` 消除 Q35 内置设备。Ubuntu 内核从 apt 仓库提取 deb 包，注入 Alpine rootfs。

**Tech Stack:** C (QEMU plugin), Bash (构建脚本), debugfs (rootfs 操作)

---

### Task 1: BDF 缓存数据结构

**Files:**
- Modify: `qemu-plugin/cosim_pcie_rc.h:18-64`

- [ ] **Step 1: 在 cosim_pcie_rc.h 中新增 BDF 缓存定义**

在 `COSIM_MAX_BARS` 定义之后、`TYPE_COSIM_PCIE_RC` 之前，添加：

```c
/* BDF 动态缓存: 首次 CfgRd 探测 vendor ID，缓存结果
 * 无效 BDF 后续访问直接返回 0xFFFFFFFF，不转发 VCS */
#define COSIM_MAX_BUS   256
#define COSIM_MAX_DEV   32
#define COSIM_MAX_FUNC  8

typedef struct CosimBdfCacheEntry {
    uint16_t vendor_id;    /* 缓存的 vendor ID */
    bool     probed;       /* 是否已探测过 */
    bool     valid;        /* VCS 是否返回了有效设备 */
} CosimBdfCacheEntry;
```

在 `struct CosimPCIeRC` 的 `bool debug;` 之后添加：

```c
    /* BDF 动态缓存 — config space 访问过滤 */
    CosimBdfCacheEntry bdf_cache[COSIM_MAX_BUS][COSIM_MAX_DEV][COSIM_MAX_FUNC];
```

- [ ] **Step 2: 验证定义已添加**

Run: `grep -c CosimBdfCacheEntry qemu-plugin/cosim_pcie_rc.h`

Expected: `2`（typedef + 成员声明各一处）

- [ ] **Step 3: Commit**

```bash
git add qemu-plugin/cosim_pcie_rc.h
git commit -m "feat(qemu): add BDF cache data structure for config space filtering"
```

---

### Task 2: Config Read BDF 缓存拦截

**Files:**
- Modify: `qemu-plugin/cosim_pcie_rc.c:234-280` (cosim_config_read 函数)

- [ ] **Step 1: 替换 cosim_config_read 函数**

将现有 `cosim_config_read`（234-280 行）替换为：

```c
static uint32_t cosim_config_read(PCIDevice *pci_dev, uint32_t address, int len)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* Bridge 未连接时，使用 QEMU 本地 config space */
    if (!ctx) {
        uint32_t local_val = pci_default_read_config(pci_dev, address, len);
        COSIM_DPRINTF(s, "cfg_read LOCAL addr=0x%02x len=%d -> 0x%x\n",
                address, len, local_val);
        return local_val;
    }

    /* ---- BDF 缓存过滤 ---- */
    int bus  = pci_bus_num(pci_get_bus(pci_dev));
    int dev  = PCI_SLOT(pci_dev->devfn);
    int func = PCI_FUNC(pci_dev->devfn);

    if (bus < COSIM_MAX_BUS && dev < COSIM_MAX_DEV && func < COSIM_MAX_FUNC) {
        CosimBdfCacheEntry *entry = &s->bdf_cache[bus][dev][func];

        if (!entry->probed) {
            /* 首次访问: 主动读 vendor/device ID (offset 0x00) */
            tlp_entry_t probe_req = {0};
            probe_req.type     = TLP_CFGRD;
            probe_req.addr     = 0x00;
            probe_req.len      = 4;
            probe_req.first_be = 0xF;

            cpl_entry_t probe_cpl = {0};
            int probe_ret = bridge_send_tlp_and_wait(ctx, &probe_req, &probe_cpl);

            if (probe_ret < 0) {
                entry->vendor_id = 0xFFFF;
            } else {
                entry->vendor_id = (uint16_t)(probe_cpl.data[0] |
                                              (probe_cpl.data[1] << 8));
            }
            entry->probed = true;
            entry->valid  = (entry->vendor_id != 0xFFFF);

            COSIM_DPRINTF(s, "BDF %02x:%02x.%x probe: vendor=0x%04x valid=%d\n",
                    bus, dev, func, entry->vendor_id, entry->valid);

            if (!entry->valid) {
                return 0xFFFFFFFF;
            }

            /* 如果内核请求的就是 offset 0x00，直接返回已获取的数据 */
            if ((address & ~3u) == 0x00) {
                uint32_t dword = 0;
                for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
                    dword |= ((uint32_t)probe_cpl.data[i]) << (i * 8);
                }
                uint32_t byte_offset = address & 3u;
                uint32_t val = dword >> (byte_offset * 8);
                if (len < 4) {
                    val &= (1u << (len * 8)) - 1;
                }
                return val;
            }
        }

        if (!entry->valid) {
            return 0xFFFFFFFF;
        }
    }

    /* 有效设备 — 正常转发 VCS */
    uint32_t dword_addr = address & ~3u;
    uint32_t byte_offset = address & 3u;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len = 4;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        uint32_t fallback = pci_default_read_config(pci_dev, address, len);
        COSIM_DPRINTF(s, "cfg_read addr=0x%02x len=%d VCS_FAIL -> local=0x%x\n",
                address, len, fallback);
        return fallback;
    }

    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }

    uint32_t val = dword >> (byte_offset * 8);
    if (len < 4) {
        val &= (1u << (len * 8)) - 1;
    }

    COSIM_DPRINTF(s, "cfg_read addr=0x%02x len=%d -> 0x%x (dw=0x%08x off=%u)\n",
            address, len, val, dword, byte_offset);
    return val;
}
```

- [ ] **Step 2: 验证**

Run: `grep -c "bdf_cache\|BDF" qemu-plugin/cosim_pcie_rc.c`

Expected: 至少 8 处引用

- [ ] **Step 3: Commit**

```bash
git add qemu-plugin/cosim_pcie_rc.c
git commit -m "feat(qemu): implement BDF cache in config_read for fast invalid-device rejection"
```

---

### Task 3: Config Write BDF 缓存拦截

**Files:**
- Modify: `qemu-plugin/cosim_pcie_rc.c:282-313` (cosim_config_write 函数)

- [ ] **Step 1: 替换 cosim_config_write 函数**

将现有 `cosim_config_write`（282-313 行）替换为：

```c
static void cosim_config_write(PCIDevice *pci_dev, uint32_t address,
                               uint32_t data, int len)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* 始终先写本地 config space，保证 QEMU 内部状态一致 */
    pci_default_write_config(pci_dev, address, data, len);

    if (!ctx) {
        return;
    }

    /* ---- BDF 缓存过滤: 无效设备的 CfgWr 直接丢弃 ---- */
    int bus  = pci_bus_num(pci_get_bus(pci_dev));
    int dev  = PCI_SLOT(pci_dev->devfn);
    int func = PCI_FUNC(pci_dev->devfn);

    if (bus < COSIM_MAX_BUS && dev < COSIM_MAX_DEV && func < COSIM_MAX_FUNC) {
        CosimBdfCacheEntry *entry = &s->bdf_cache[bus][dev][func];
        if (!entry->probed || !entry->valid) {
            COSIM_DPRINTF(s, "BDF %02x:%02x.%x CfgWr dropped (invalid device)\n",
                    bus, dev, func);
            return;
        }
    }

    /* 有效设备 — 转发 CfgWr TLP 到 VCS */
    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = address;
    req.len = len;
    for (int i = 0; i < len && i < COSIM_TLP_DATA_SIZE; i++) {
        req.data[i] = (data >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: CfgWr failed addr=0x%x data=0x%x\n",
                      address, data);
    }

    COSIM_DPRINTF(s, "CfgWr addr=0x%02x len=%d data=0x%x\n",
                  address, len, data);
}
```

- [ ] **Step 2: Commit**

```bash
git add qemu-plugin/cosim_pcie_rc.c
git commit -m "feat(qemu): filter config_write through BDF cache, drop writes to invalid devices"
```

---

### Task 4: BDF 缓存初始化

**Files:**
- Modify: `qemu-plugin/cosim_pcie_rc.c:378-382`

- [ ] **Step 1: 在 realize 函数开头清零 BDF 缓存**

在 `cosim_pcie_rc_realize` 函数的 `s->num_bars = 0;`（381 行）之后添加：

```c
    /* 清零 BDF 缓存 */
    memset(s->bdf_cache, 0, sizeof(s->bdf_cache));
```

- [ ] **Step 2: 验证**

Run: `grep -n "memset.*bdf_cache" qemu-plugin/cosim_pcie_rc.c`

Expected: 一行匹配，在 realize 函数内

- [ ] **Step 3: Commit**

```bash
git add qemu-plugin/cosim_pcie_rc.c
git commit -m "feat(qemu): initialize BDF cache in device realize"
```

---

### Task 5: QEMU 启动参数优化

**Files:**
- Modify: `cosim.sh`

- [ ] **Step 1: 找到所有 QEMU 启动点**

Run: `grep -n "\-M q35" cosim.sh`

记录所有行号。

- [ ] **Step 2: 在每个 -M q35 行之后添加 -nodefaults -vga none -no-hpet**

对 `cosim.sh` 中每个 `-M q35 -m "${GUEST_MEMORY}" -smp 1 \` 行，在其后添加：

```bash
        -nodefaults -vga none -no-hpet \
```

对 `start_qemu_generic` 函数（约 1069 行），将：

```bash
    local QEMU_ARGS=(
        -M q35 -m "${GUEST_MEMORY}" -smp 1
        -device "$device_arg"
        -no-reboot
    )
```

改为：

```bash
    local QEMU_ARGS=(
        -M q35 -m "${GUEST_MEMORY}" -smp 1
        -nodefaults -vga none -no-hpet
        -device "$device_arg"
        -no-reboot
    )
```

- [ ] **Step 3: 验证所有启动点已更新**

Run: `grep -c "nodefaults" cosim.sh`

Expected: 与 `-M q35` 出现次数相同

- [ ] **Step 4: Commit**

```bash
git add cosim.sh
git commit -m "perf(qemu): add -nodefaults -vga none -no-hpet to strip Q35 built-in devices"
```

---

### Task 6: Ubuntu 内核提取脚本

**Files:**
- Create: `scripts/setup-ubuntu-kernel.sh`

- [ ] **Step 1: 创建脚本**

```bash
#!/bin/bash
# setup-ubuntu-kernel.sh — 从 Ubuntu apt 仓库提取 LTS 内核及模块
# 用于 cosim guest，包含 VFIO/RDMA/NVMe-oF 等完整模块
set -euo pipefail

KVER="${1:-6.8.0-107-generic}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_DIR}/guest/images/ubuntu"
WORK_DIR="/tmp/cosim-ubuntu-kernel-${KVER}"

echo "============================================"
echo " Ubuntu 内核提取: ${KVER}"
echo "============================================"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR"

# ---- 1. 下载 deb 包 ----
echo "[1/4] 下载内核包..."
for pkg in \
    "linux-image-unsigned-${KVER}" \
    "linux-modules-${KVER}" \
    "linux-modules-extra-${KVER}"; do
    if [ ! -f "${pkg}"_*.deb ]; then
        echo "  下载 $pkg..."
        apt-get download "$pkg" 2>/dev/null || {
            echo "ERROR: 无法下载 $pkg"
            echo "  确保 apt 源包含 Ubuntu $(lsb_release -cs) 仓库"
            exit 1
        }
    else
        echo "  $pkg 已存在，跳过"
    fi
done

# ---- 2. 解压 ----
echo "[2/4] 解压..."
rm -rf extract && mkdir extract
for deb in *.deb; do
    dpkg-deb -x "$deb" extract/ 2>/dev/null
done

# ---- 3. 提取 vmlinuz ----
echo "[3/4] 提取内核和模块..."
VMLINUZ=$(find extract/boot -name "vmlinuz-*" -type f | head -1)
if [ -z "$VMLINUZ" ]; then
    echo "ERROR: vmlinuz not found in extracted packages"
    exit 1
fi
cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
echo "  vmlinuz: $(ls -lh "$OUTPUT_DIR/vmlinuz" | awk '{print $5}')"

# ---- 4. 打包模块 ----
MODDIR=$(find extract/lib/modules -maxdepth 1 -mindepth 1 -type d | head -1)
if [ -z "$MODDIR" ]; then
    echo "ERROR: modules directory not found"
    exit 1
fi
REAL_KVER=$(basename "$MODDIR")
echo "  内核版本: $REAL_KVER"

if command -v depmod &>/dev/null; then
    depmod -b extract "$REAL_KVER" 2>/dev/null || true
fi

cd extract
tar czf "$OUTPUT_DIR/modules.tar.gz" lib/modules/
echo "  modules.tar.gz: $(ls -lh "$OUTPUT_DIR/modules.tar.gz" | awk '{print $5}')"

# ---- 验证关键模块 ----
echo "[4/4] 验证关键模块..."
MISSING=0
for mod in \
    "kernel/drivers/vfio/vfio.ko" \
    "kernel/drivers/vfio/pci/vfio-pci.ko" \
    "kernel/drivers/infiniband/core/ib_core.ko" \
    "kernel/drivers/infiniband/hw/mlx5/mlx5_ib.ko" \
    "kernel/drivers/nvme/host/nvme-tcp.ko" \
    "kernel/drivers/nvme/host/nvme-rdma.ko"; do
    found=$(find "lib/modules/$REAL_KVER" -path "*${mod}*" | head -1)
    if [ -n "$found" ]; then
        echo "  OK: $(basename "$found")"
    else
        echo "  MISSING: $mod"
        MISSING=1
    fi
done

if [ $MISSING -eq 1 ]; then
    echo "WARNING: 部分关键模块缺失"
else
    echo "  所有关键模块验证通过"
fi

echo ""
echo "============================================"
echo " 提取完成"
echo " vmlinuz:  ${OUTPUT_DIR}/vmlinuz"
echo " modules:  ${OUTPUT_DIR}/modules.tar.gz"
echo " 版本:     ${REAL_KVER}"
echo "============================================"
echo ""
echo "下一步: ./scripts/inject-modules.sh ubuntu"
```

- [ ] **Step 2: 设置可执行权限并运行**

```bash
chmod +x scripts/setup-ubuntu-kernel.sh
./scripts/setup-ubuntu-kernel.sh 6.8.0-107-generic
```

Expected: vmlinuz 和 modules.tar.gz 生成，VFIO/RDMA/NVMe 模块验证通过

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-ubuntu-kernel.sh
git commit -m "feat(guest): add Ubuntu kernel extraction script with VFIO/RDMA/NVMe verification"
```

---

### Task 7: 模块注入脚本

**Files:**
- Modify: `scripts/inject-modules.sh`

- [ ] **Step 1: 替换 inject-modules.sh**

替换为支持多系统（ubuntu/alpine）的版本：

```bash
#!/bin/bash
# inject-modules.sh — 将内核模块注入 rootfs
# 用法: ./scripts/inject-modules.sh [ubuntu|alpine]
set -euo pipefail

SYSTEM="${1:-ubuntu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COSIM_DIR="${PROJECT_DIR}/guest/images/${SYSTEM}"
ALPINE_DIR="${PROJECT_DIR}/guest/images/alpine"

MODULES_TAR="${COSIM_DIR}/modules.tar.gz"
SRC_ROOTFS="${ALPINE_DIR}/rootfs.ext4"
DST_ROOTFS="${COSIM_DIR}/rootfs.ext4"

if [ ! -f "$MODULES_TAR" ]; then
    echo "ERROR: 找不到模块包: $MODULES_TAR"
    echo "  请先运行对应的 setup 脚本"
    exit 1
fi

if [ ! -f "$SRC_ROOTFS" ]; then
    echo "ERROR: 找不到 Alpine 基础 rootfs: $SRC_ROOTFS"
    exit 1
fi

# ---- 1. 复制基础 rootfs ----
echo "[1/4] 复制 Alpine rootfs 为 ${SYSTEM} rootfs..."
if [ -f "$DST_ROOTFS" ]; then
    echo "  目标已存在，备份为 rootfs.ext4.bak"
    mv "$DST_ROOTFS" "${DST_ROOTFS}.bak"
fi
cp "$SRC_ROOTFS" "$DST_ROOTFS"

# ---- 2. 扩展 rootfs ----
EXTRA_MB=200
if [ "$SYSTEM" = "alpine" ]; then
    EXTRA_MB=50
fi
echo "[2/4] 扩展 rootfs (+${EXTRA_MB}MB)..."
truncate -s "+${EXTRA_MB}M" "$DST_ROOTFS"
e2fsck -fy "$DST_ROOTFS" 2>/dev/null || true
resize2fs "$DST_ROOTFS" 2>/dev/null

# ---- 3. 注入模块 ----
echo "[3/4] 注入内核模块..."

NEW_KVER=$(tar tzf "$MODULES_TAR" | head -1 | cut -d/ -f3)
echo "  新内核版本: $NEW_KVER"

TMPDIR=$(mktemp -d)
cd "$TMPDIR"
tar xzf "$MODULES_TAR"

if command -v depmod &>/dev/null; then
    depmod -b "$TMPDIR" "$NEW_KVER" 2>/dev/null || true
fi

DBGCMDS=$(mktemp)

OLD_KVER="6.6.134-0-virt"
echo "kill_file lib/modules/${OLD_KVER}" >> "$DBGCMDS"

find "lib/modules/${NEW_KVER}" -type d | sort | while read dir; do
    echo "mkdir $dir" >> "$DBGCMDS"
done

find "lib/modules/${NEW_KVER}" -type f | sort | while read file; do
    echo "write $(pwd)/$file $file" >> "$DBGCMDS"
done

CMD_COUNT=$(wc -l < "$DBGCMDS")
echo "  debugfs 命令数: $CMD_COUNT"

debugfs -w -f "$DBGCMDS" "$DST_ROOTFS" 2>/dev/null

rm -f "$DBGCMDS"

# ---- 4. 验证 ----
echo "[4/4] 验证注入结果..."
MOD_COUNT=$(debugfs -R "ls lib/modules/${NEW_KVER}/kernel" "$DST_ROOTFS" 2>/dev/null | wc -w)
echo "  模块目录条目: $MOD_COUNT"

VFIO_CHECK=$(debugfs -R "dump lib/modules/${NEW_KVER}/modules.dep /dev/stdout" "$DST_ROOTFS" 2>/dev/null | grep -c "vfio" || true)
echo "  VFIO 模块数: $VFIO_CHECK"

RDMA_CHECK=$(debugfs -R "dump lib/modules/${NEW_KVER}/modules.dep /dev/stdout" "$DST_ROOTFS" 2>/dev/null | grep -c "infiniband\|rdma" || true)
echo "  RDMA 模块数: $RDMA_CHECK"

rm -rf "$TMPDIR"

echo ""
echo "============================================"
echo " 模块注入完成 (${SYSTEM})"
echo " rootfs:  ${DST_ROOTFS}"
echo " 内核:    ${NEW_KVER}"
echo "============================================"
echo ""
echo "运行 cosim:"
echo "  KERNEL=${COSIM_DIR}/vmlinuz ./cosim.sh start qemu --drive ${DST_ROOTFS}"
```

- [ ] **Step 2: 运行注入**

```bash
chmod +x scripts/inject-modules.sh
./scripts/inject-modules.sh ubuntu
```

Expected: rootfs 生成，VFIO/RDMA 模块数 > 0

- [ ] **Step 3: Commit**

```bash
git add scripts/inject-modules.sh
git commit -m "feat(guest): update inject-modules.sh to support Ubuntu/Alpine with auto-sizing"
```

---

### Task 8: setup.sh 集成

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: 查看 setup.sh 中镜像构建位置**

Run: `grep -n "alpine\|image\|kernel\|guest" setup.sh | head -30`

确认插入点。

- [ ] **Step 2: 在 Alpine 镜像构建之后添加 Ubuntu 内核提取**

在 setup.sh 中现有 Alpine 镜像构建步骤之后添加：

```bash
# ---- Ubuntu LTS 内核提取（含 VFIO/RDMA/NVMe-oF 模块）----
log_info "提取 Ubuntu LTS 内核..."
if [ ! -f "${PROJECT_DIR}/guest/images/ubuntu/vmlinuz" ]; then
    "${PROJECT_DIR}/scripts/setup-ubuntu-kernel.sh" "6.8.0-107-generic"
    "${PROJECT_DIR}/scripts/inject-modules.sh" ubuntu
else
    log_info "Ubuntu 内核已存在，跳过"
fi
```

- [ ] **Step 3: Commit**

```bash
git add setup.sh
git commit -m "feat(setup): integrate Ubuntu kernel extraction into setup flow"
```

---

### Task 9: 端到端验证

**Files:** 无新文件

- [ ] **Step 1: 验证 Ubuntu 内核文件完整**

Run: `ls -lh guest/images/ubuntu/vmlinuz guest/images/ubuntu/rootfs.ext4 guest/images/ubuntu/modules.tar.gz`

Expected: 三个文件存在

- [ ] **Step 2: 验证 BDF 缓存代码一致性**

Run: `grep -n "CosimBdfCacheEntry\|bdf_cache" qemu-plugin/cosim_pcie_rc.h qemu-plugin/cosim_pcie_rc.c`

Expected: .h 中 typedef + 成员，.c 中 memset + config_read 使用 + config_write 使用

- [ ] **Step 3: 验证 QEMU 启动参数**

Run: `grep -c "\-nodefaults" cosim.sh`

Expected: 与 `-M q35` 出现次数相同

- [ ] **Step 4: 验证 Alpine 内核不变（回归）**

Run: `ls -lh guest/images/alpine/bzImage guest/images/alpine/rootfs.ext4`

Expected: 文件不变

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: end-to-end verification of BDF cache + Ubuntu kernel integration"
```
