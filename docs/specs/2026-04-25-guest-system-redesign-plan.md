# Guest 系统改造 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 去掉 initramfs 模式，改为 Alpine/Debian rootfs 全量系统，用户登录后交互式操作，终端默认安静、VERBOSE=1 开启调试。

**Architecture:** setup.sh 构建 Alpine 或 Debian rootfs.ext4（含预装工具 + cosim 脚本），Makefile 统一用 drive 模式启动，QEMU 设备属性 `debug=on/off` 控制运行时打印，kernel cmdline `quiet loglevel=1` 抑制内核噪音。

**Tech Stack:** Bash (setup/build scripts), C (QEMU device property), Make, Alpine apk / Debian debootstrap

---

### Task 1: QEMU debug 打印改为运行时设备属性

**Files:**
- Modify: `qemu-plugin/cosim_pcie_rc.h:33-61`
- Modify: `qemu-plugin/cosim_pcie_rc.c:19-24,76,120,558-565`

- [ ] **Step 1: 在 CosimPCIeRC 结构体中加 debug 字段**

在 `qemu-plugin/cosim_pcie_rc.h` 的 `struct CosimPCIeRC` 中，`void *bridge_ctx;` 之前加:

```c
    /* 运行时 debug 开关 -- -device cosim-pcie-rc,...,debug=on */
    bool debug;
```

- [ ] **Step 2: 替换编译时宏为运行时宏**

在 `qemu-plugin/cosim_pcie_rc.c` 中，将第 19-24 行:

```c
/* Debug 打印：编译时 -DCOSIM_DEBUG 开启 */
#ifdef COSIM_DEBUG
#define COSIM_DPRINTF(fmt, ...) fprintf(stderr, "cosim: " fmt, ##__VA_ARGS__)
#else
#define COSIM_DPRINTF(fmt, ...) do {} while (0)
#endif
```

替换为:

```c
/* Debug 打印：运行时通过 -device cosim-pcie-rc,...,debug=on 开启 */
#define COSIM_DPRINTF(s, fmt, ...) do { \
    if ((s)->debug) fprintf(stderr, "cosim: " fmt, ##__VA_ARGS__); \
} while (0)
```

- [ ] **Step 3: 更新所有 COSIM_DPRINTF 调用点**

第 76 行 `cosim_mmio_read` 中:
```c
    COSIM_DPRINTF(s, "MRd bar%d off=0x%04lx pcie=0x%lx be=0x%x val=0x%lx\n",
            bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
            first_be, (unsigned long)val);
```

第 120 行 `cosim_mmio_write` 中:
```c
    COSIM_DPRINTF(s, "MWr bar%d off=0x%04lx pcie=0x%lx be=0x%x val=0x%lx\n",
            bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
            first_be, (unsigned long)val);
```

注意: `s` 来自 `bc->dev`，在两个函数里已有 `CosimPCIeRC *s = bc->dev;`。

- [ ] **Step 4: 注册 debug 设备属性**

在 `qemu-plugin/cosim_pcie_rc.c` 的 `cosim_properties[]` 数组中，`DEFINE_PROP_END_OF_LIST()` 之前加:

```c
    DEFINE_PROP_BOOL("debug", CosimPCIeRC, debug, false),
```

- [ ] **Step 5: Commit**

```bash
git add qemu-plugin/cosim_pcie_rc.h qemu-plugin/cosim_pcie_rc.c
git commit -m "feat(qemu): debug 打印改为运行时设备属性 debug=on/off"
```

---

### Task 2: Makefile 改造 -- 去掉 initramfs，加 VERBOSE 参数

**Files:**
- Modify: `Makefile:26-32` (变量区)
- Modify: `Makefile:142-199` (QEMU 运行区)
- Modify: `Makefile:340-350` (info 目标)
- Modify: `Makefile:375-395` (help 目标)

- [ ] **Step 1: 去掉 INITRD 变量**

删除 Makefile 第 28-29 行:
```makefile
INITRD        ?= $(firstword $(wildcard $(PROJECT_DIR)/guest/images/custom-initramfs-phase5.gz) \
                              $(wildcard $(HOME)/workspace/custom-initramfs-phase5.gz))
```

- [ ] **Step 2: 加 VERBOSE 参数和简化 Guest 模式判断**

将第 142-164 行整个替换为:

```makefile
# ============================================================
# 运行 -- QEMU
# ============================================================
VERBOSE       ?= 0

ifeq ($(VERBOSE),1)
  _LOGLEVEL    = loglevel=7
  _COSIM_DEBUG = ,debug=on
else
  _LOGLEVEL    = quiet loglevel=1
  _COSIM_DEBUG =
endif

ifeq ($(TRANSPORT),tcp)
  _QEMU_DEV = cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=$(INSTANCE_ID)$(_COSIM_DEBUG)
else
  _QEMU_DEV = cosim-pcie-rc,shm_name=$(SHM_NAME),sock_path=$(SOCK_PATH)$(_COSIM_DEBUG)
endif

ifneq ($(ROOTFS),)
  _GUEST_ARGS  = -drive file=$(ROOTFS),format=raw,if=virtio
  _QEMU_APPEND = console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=$(GUEST_IP) peer_ip=$(PEER_IP)
else
  _GUEST_ARGS  =
  _QEMU_APPEND = console=ttyS0 $(_LOGLEVEL) guest_ip=$(GUEST_IP) peer_ip=$(PEER_IP)
endif
```

- [ ] **Step 3: 更新 run-qemu 目标**

替换 run-qemu 整个目标为:

```makefile
run-qemu:
	@if [ ! -f '$(QEMU)' ]; then \
		echo "[错误] QEMU 未找到: $(QEMU)"; \
		echo "  请指定: make run-qemu QEMU=/path/to/qemu-system-x86_64"; \
		exit 1; \
	fi
	@if [ ! -f '$(KERNEL)' ]; then \
		echo "[错误] Kernel 未找到: $(KERNEL)"; \
		echo "  请指定: make run-qemu KERNEL=/path/to/bzImage"; \
		exit 1; \
	fi
	@if [ -z '$(ROOTFS)' ]; then \
		echo "[警告] 未找到 rootfs，内核可能无法挂载根文件系统"; \
		echo "  请提供: ROOTFS=/path/to/rootfs.ext4"; \
	fi
	@mkdir -p $(LOG_DIR) $(RUN_DIR)
	@echo "============================================"
	@echo " QEMU ($(TRANSPORT) 模式)"
ifeq ($(TRANSPORT),tcp)
	@echo "  监听: $(PORT_BASE)-$$(($(PORT_BASE)+2))  Instance: $(INSTANCE_ID)"
else
	@echo "  SHM: $(SHM_NAME)  Sock: $(SOCK_PATH)"
endif
	@echo "  Guest: $(GUEST_IP)  Peer: $(PEER_IP)"
	@echo "  日志: $(LOG_DIR)/qemu.log"
	@echo "  调试: make run-qemu VERBOSE=1"
	@echo "  退出: Ctrl+A X 或 Guest 内 cosim-stop"
	@echo "============================================"
	$(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 \
		-kernel $(KERNEL) $(_GUEST_ARGS) \
		-append '$(strip $(_QEMU_APPEND))' \
		-device '$(strip $(_QEMU_DEV))' \
		-nographic -no-reboot -action panic=shutdown \
		-d unimp -D $(LOG_DIR)/qemu_debug.log \
		2>&1 | tee $(LOG_DIR)/qemu.log
```

- [ ] **Step 4: 更新 run-dual 中的 append 参数**

QEMU1 的 `-append` 改为:
```makefile
	-append 'console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=10.0.0.1 peer_ip=10.0.0.2' \
```

QEMU2 的 `-append` 改为:
```makefile
	-append 'console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=10.0.0.2 peer_ip=10.0.0.1' \
```

- [ ] **Step 5: 更新 info 目标**

将 Initrd/Rootfs/Guest 行替换为:
```makefile
	@echo "  Rootfs: $(if $(ROOTFS),$(ROOTFS)  $$(test -f '$(ROOTFS)' && echo [OK] || echo [缺失]),(未找到))"
	@echo "  VERBOSE: $(VERBOSE)"
```

- [ ] **Step 6: 更新 help 目标参数说明**

加一行:
```makefile
	@echo "  VERBOSE=0|1            日志级别（默认 0 安静，1 详细+debug）"
```

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "refactor(makefile): 去掉 initramfs 模式，加 VERBOSE 参数控制日志"
```

---

### Task 3: Guest overlay 文件 -- cosim-start/cosim-stop/motd

**Files:**
- Create: `guest/overlay/usr/local/bin/cosim-start`
- Create: `guest/overlay/usr/local/bin/cosim-stop`
- Create: `guest/overlay/etc/motd`
- Modify: `guest/overlay/etc/init.d/S99cosim`

- [ ] **Step 1: 创建 cosim-start**

```bash
mkdir -p guest/overlay/usr/local/bin
```

写入 `guest/overlay/usr/local/bin/cosim-start`:

```sh
#!/bin/sh
# cosim-start -- configure network + show available commands
# Usage: cosim-start [IP]

IP="$1"
if [ -z "$IP" ]; then
    IP=$(cat /proc/cmdline | tr ' ' '\n' | grep '^guest_ip=' | cut -d= -f2)
fi
IP="${IP:-10.0.0.1}"

PEER=$(cat /proc/cmdline | tr ' ' '\n' | grep '^peer_ip=' | cut -d= -f2)
PEER="${PEER:-10.0.0.2}"

ip link set eth0 up 2>/dev/null
ip addr flush dev eth0 2>/dev/null
ip addr add "$IP/24" dev eth0

echo ""
echo "eth0: $IP/24 -- ready"
echo ""
echo "Available commands:"
echo "  ping $PEER               connectivity test"
echo "  iperf3 -s                 start iperf server"
echo "  iperf3 -c $PEER           throughput test"
echo "  lspci -vv                 PCI device list"
echo "  cfgspace_test             Config Space verification"
echo "  dma_test <BAR_ADDR>       DMA read/write test"
echo "  nic_tx_test <BAR_ADDR>    NIC TX test"
echo "  cosim-stop                stop simulation"
echo ""
```

```bash
chmod +x guest/overlay/usr/local/bin/cosim-start
```

- [ ] **Step 2: 创建 cosim-stop**

写入 `guest/overlay/usr/local/bin/cosim-stop`:

```sh
#!/bin/sh
# cosim-stop -- stop simulation, notify VCS to exit
echo "cosim: notifying VCS to stop..."
poweroff
```

```bash
chmod +x guest/overlay/usr/local/bin/cosim-stop
```

- [ ] **Step 3: 创建 motd**

写入 `guest/overlay/etc/motd`:

```
============================================
 CoSim Guest

 1. Start VCS in another terminal:
      make run-vcs

 2. Configure network:
      cosim-start

 3. Run tests:
      ping / iperf3 / lspci / cfgspace_test

 4. Exit:
      cosim-stop          (graceful, notifies VCS)
      Ctrl+A X            (force quit QEMU)
============================================
```

- [ ] **Step 4: 修改 S99cosim -- 去掉自动配网**

将 `guest/overlay/etc/init.d/S99cosim` 替换为:

```sh
#!/bin/sh
# S99cosim -- cosim guest boot configuration
# Network is NOT auto-configured; use cosim-start manually.

case "$1" in
    start)
        if ! echo "$PATH" | grep -q '/usr/local/bin'; then
            export PATH="/usr/local/bin:$PATH"
        fi
        echo ""
        echo "cosim: ready. Run 'cosim-start' to configure network."
        echo ""
        ;;
    stop)
        ip link set eth0 down 2>/dev/null
        ;;
esac
```

- [ ] **Step 5: Commit**

```bash
git add guest/overlay/
git commit -m "feat(guest): cosim-start/cosim-stop/motd 交互式 Guest 体验"
```

---

### Task 4: Alpine rootfs 构建脚本

**Files:**
- Create: `scripts/build_rootfs_alpine.sh`

- [ ] **Step 1: 创建 Alpine 构建脚本**

写入 `scripts/build_rootfs_alpine.sh` (完整脚本):

```bash
#!/bin/bash
# build_rootfs_alpine.sh -- build Alpine Linux rootfs.ext4
# Usage: sudo ./scripts/build_rootfs_alpine.sh [output_dir]
# Requires: sudo, network (or pre-downloaded tar in third_party/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-${PROJECT_DIR}/guest/images}"
ALPINE_VER="3.20"
ALPINE_ARCH="x86_64"
ALPINE_TAR="alpine-minirootfs-${ALPINE_VER}.0-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/${ALPINE_ARCH}/${ALPINE_TAR}"
ROOTFS_SIZE_MB=256
ROOTFS_IMG="${OUTPUT_DIR}/rootfs.ext4"
MOUNT_DIR=$(mktemp -d /tmp/cosim-rootfs.XXXXXX)
LOOP_DEV=""

info()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $*"; }
fail()  { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

cleanup() {
    info "Cleaning up..."
    umount "$MOUNT_DIR" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    fail "Need root. Run: sudo $0"
fi

mkdir -p "$OUTPUT_DIR" "${PROJECT_DIR}/third_party"

# ---- Download Alpine minirootfs ----
TARBALL="${PROJECT_DIR}/third_party/${ALPINE_TAR}"
if [ -f "$TARBALL" ]; then
    info "Using cached Alpine tar: $TARBALL"
else
    info "Downloading Alpine minirootfs..."
    if ! wget -q --show-progress -O "$TARBALL" "$ALPINE_URL"; then
        rm -f "$TARBALL"
        fail "Download failed. For offline use, place tar at: $TARBALL"
    fi
    ok "Download complete"
fi

# ---- Create ext4 image ----
info "Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=none
mkfs.ext4 -q -F "$ROOTFS_IMG"
LOOP_DEV=$(losetup --find --show "$ROOTFS_IMG")
mount "$LOOP_DEV" "$MOUNT_DIR"

# ---- Extract Alpine ----
info "Extracting Alpine rootfs..."
tar xzf "$TARBALL" -C "$MOUNT_DIR"

# ---- DNS for chroot ----
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true

# ---- Install packages ----
info "Installing packages (apk add)..."
chroot "$MOUNT_DIR" /bin/sh -c '
    apk update
    apk add iperf3 iproute2 iputils ethtool tcpdump
    apk add pciutils usbutils
    apk add kmod util-linux procps coreutils
    apk add rdma-core perftest 2>/dev/null || echo "RDMA not available, skipping"
    apk add bash wget curl
    rm -rf /var/cache/apk/*
'

# ---- Configure system ----
info "Configuring system..."

cat > "$MOUNT_DIR/etc/inittab" << 'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::sysinit:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
::shutdown:/sbin/openrc shutdown
INITTAB

echo "cosim-guest" > "$MOUNT_DIR/etc/hostname"

sed -i 's/^root:.*/root::0:0:root:\/root:\/bin\/ash/' "$MOUNT_DIR/etc/shadow" 2>/dev/null || \
    echo 'root::0:0:root:/root:/bin/ash' > "$MOUNT_DIR/etc/shadow"
chmod 640 "$MOUNT_DIR/etc/shadow"

cat > "$MOUNT_DIR/etc/fstab" << 'FSTAB'
/dev/vda    /        ext4    rw,relatime    0 1
proc        /proc    proc    defaults       0 0
sysfs       /sys     sysfs   defaults       0 0
devtmpfs    /dev     devtmpfs defaults      0 0
FSTAB

# ---- Copy cosim overlay ----
info "Copying cosim overlay..."
OVERLAY_DIR="${PROJECT_DIR}/guest/overlay"
if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR"/* "$MOUNT_DIR/" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-start" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-stop" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/etc/init.d/S99cosim" 2>/dev/null || true
fi

# ---- Copy custom test tools (if built) ----
TOOLS_DIR="${PROJECT_DIR}/build/guest_tools"
if [ -d "$TOOLS_DIR" ]; then
    info "Copying custom test tools..."
    cp -a "$TOOLS_DIR"/* "$MOUNT_DIR/usr/local/bin/" 2>/dev/null || true
fi

# ---- Done ----
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

ok "Alpine rootfs built: $ROOTFS_IMG"
ls -lh "$ROOTFS_IMG"
```

```bash
chmod +x scripts/build_rootfs_alpine.sh
```

- [ ] **Step 2: Commit**

```bash
git add scripts/build_rootfs_alpine.sh
git commit -m "feat(guest): Alpine rootfs build script"
```

---

### Task 5: Debian rootfs 构建脚本

**Files:**
- Create: `scripts/build_rootfs_debian.sh`

- [ ] **Step 1: 创建 Debian 构建脚本**

写入 `scripts/build_rootfs_debian.sh` (完整脚本):

```bash
#!/bin/bash
# build_rootfs_debian.sh -- build Debian rootfs.ext4
# Usage: sudo ./scripts/build_rootfs_debian.sh [output_dir]
# Requires: sudo, debootstrap, network
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-${PROJECT_DIR}/guest/images}"
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
ROOTFS_SIZE_MB=512
ROOTFS_IMG="${OUTPUT_DIR}/rootfs.ext4"
MOUNT_DIR=$(mktemp -d /tmp/cosim-rootfs.XXXXXX)
LOOP_DEV=""

info()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $*"; }
fail()  { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

cleanup() {
    info "Cleaning up..."
    umount "$MOUNT_DIR/proc" 2>/dev/null || true
    umount "$MOUNT_DIR/sys" 2>/dev/null || true
    umount "$MOUNT_DIR/dev" 2>/dev/null || true
    umount "$MOUNT_DIR" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    fail "Need root. Run: sudo $0"
fi

if ! command -v debootstrap &>/dev/null; then
    fail "debootstrap not installed. Run: sudo apt install debootstrap"
fi

mkdir -p "$OUTPUT_DIR"

# ---- Create ext4 image ----
info "Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=none
mkfs.ext4 -q -F "$ROOTFS_IMG"
LOOP_DEV=$(losetup --find --show "$ROOTFS_IMG")
mount "$LOOP_DEV" "$MOUNT_DIR"

# ---- Debootstrap ----
info "Running debootstrap ${DEBIAN_SUITE} (5-10 minutes)..."
debootstrap --variant=minbase "$DEBIAN_SUITE" "$MOUNT_DIR" "$DEBIAN_MIRROR"

# ---- Install packages ----
info "Installing packages (apt install)..."
mount -t proc proc "$MOUNT_DIR/proc"
mount -t sysfs sysfs "$MOUNT_DIR/sys"
mount --bind /dev "$MOUNT_DIR/dev"

chroot "$MOUNT_DIR" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq iperf3 iproute2 iputils-ping ethtool tcpdump
    apt-get install -y -qq pciutils usbutils
    apt-get install -y -qq kmod util-linux procps
    apt-get install -y -qq rdma-core perftest 2>/dev/null || echo "RDMA not available"
    apt-get install -y -qq gcc make 2>/dev/null || echo "Dev tools partially installed"
    apt-get install -y -qq wget curl bash-completion
    apt-get clean
    rm -rf /var/lib/apt/lists/*
'

umount "$MOUNT_DIR/proc"
umount "$MOUNT_DIR/sys"
umount "$MOUNT_DIR/dev"

# ---- Configure system ----
info "Configuring system..."

echo "cosim-guest" > "$MOUNT_DIR/etc/hostname"
sed -i 's/^root:[^:]*:/root::/' "$MOUNT_DIR/etc/shadow"

# Auto-login on ttyS0
mkdir -p "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
AUTOLOGIN

cat > "$MOUNT_DIR/etc/fstab" << 'FSTAB'
/dev/vda    /        ext4    rw,relatime    0 1
proc        /proc    proc    defaults       0 0
sysfs       /sys     sysfs   defaults       0 0
FSTAB

# ---- Copy cosim overlay ----
info "Copying cosim overlay..."
OVERLAY_DIR="${PROJECT_DIR}/guest/overlay"
if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR"/* "$MOUNT_DIR/" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-start" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-stop" 2>/dev/null || true
fi

# ---- Copy custom test tools (if built) ----
TOOLS_DIR="${PROJECT_DIR}/build/guest_tools"
if [ -d "$TOOLS_DIR" ]; then
    info "Copying custom test tools..."
    cp -a "$TOOLS_DIR"/* "$MOUNT_DIR/usr/local/bin/" 2>/dev/null || true
fi

# ---- Done ----
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

ok "Debian rootfs built: $ROOTFS_IMG"
ls -lh "$ROOTFS_IMG"
```

```bash
chmod +x scripts/build_rootfs_debian.sh
```

- [ ] **Step 2: Commit**

```bash
git add scripts/build_rootfs_debian.sh
git commit -m "feat(guest): Debian rootfs build script"
```

---

### Task 6: 自定义 C 测试工具静态编译脚本

**Files:**
- Create: `scripts/build_guest_tools.sh`

- [ ] **Step 1: 创建编译脚本**

写入 `scripts/build_guest_tools.sh`:

```bash
#!/bin/bash
# build_guest_tools.sh -- static-compile custom C test tools for guest
# Usage: ./scripts/build_guest_tools.sh [output_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$(dirname "$SCRIPT_DIR")/build/guest_tools}"

mkdir -p "$OUTPUT_DIR"

TOOLS=(cfgspace_test virtio_reg_test devmem_test dma_test nic_tx_test)
PASS=0
FAIL=0

for tool in "${TOOLS[@]}"; do
    src="${SCRIPT_DIR}/${tool}.c"
    if [ ! -f "$src" ]; then
        echo "[SKIP] $tool -- source not found"
        continue
    fi
    echo -n "[BUILD] $tool ... "
    if gcc -static -O2 -o "${OUTPUT_DIR}/${tool}" "$src" 2>/dev/null; then
        echo "OK"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Built: $PASS  Failed: $FAIL  Output: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
```

```bash
chmod +x scripts/build_guest_tools.sh
```

- [ ] **Step 2: Commit**

```bash
git add scripts/build_guest_tools.sh
git commit -m "feat(guest): static build script for custom C test tools"
```

---

### Task 7: setup.sh 改造 -- Alpine/Debian 选择替换 minimal/full

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: 修改 usage() 帮助**

将:
```
Guest 环境 (--guest, 仅 local/qemu-only 模式):
  minimal     轻量 initramfs — virtio 驱动 + ping/iperf/netcat（基础测试）
  full        完整磁盘镜像  — 可安装自定义驱动、扩展业务测试
```
替换为:
```
Guest 环境 (--guest, 仅 local/qemu-only 模式):
  alpine      Alpine Linux — 轻量快速，apk 包管理（推荐）
  debian      Debian 精简版 — 完整工具链，apt 包管理
  skip        跳过 Guest 构建，手动准备镜像
```

- [ ] **Step 2: 修改交互式菜单**

将 Guest 选择菜单替换为:
```bash
    echo "  1) Alpine Linux  — 轻量快速，apk 包管理（推荐）"
    echo "     镜像 ~50MB，启动 ~3 秒"
    echo ""
    echo "  2) Debian 精简版 — 完整工具链，apt 包管理"
    echo "     镜像 ~500MB，启动 ~15 秒"
    echo ""
    echo "  3) 跳过 — 手动准备 rootfs 到 guest/images/"
```

选择逻辑:
```bash
            case "$choice" in
                1) GUEST_TYPE="alpine"; break ;;
                2) GUEST_TYPE="debian"; break ;;
                3) GUEST_TYPE="skip"; break ;;
            esac
```

- [ ] **Step 3: 修改参数验证和默认值**

将 `GUEST_TYPE="${GUEST_TYPE:-minimal}"` 改为 `GUEST_TYPE="${GUEST_TYPE:-alpine}"`

将 `minimal|full) ;;` 改为 `alpine|debian|skip) ;;`

- [ ] **Step 4: 替换 Guest 构建逻辑 (约第 980-1096 行)**

将 buildroot 构建部分替换为:

```bash
    mkdir -p "$IMAGES_DIR"

    if [ -f "${IMAGES_DIR}/bzImage" ] && [ -f "${IMAGES_DIR}/rootfs.ext4" ]; then
        ok "Guest 镜像已存在:"
        ok "  Kernel: ${IMAGES_DIR}/bzImage"
        ok "  Rootfs: ${IMAGES_DIR}/rootfs.ext4"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$GUEST_TYPE" = "skip" ]; then
        info "跳过 Guest 构建"
        info "  请手动准备:"
        info "    ${IMAGES_DIR}/bzImage      -- Guest 内核"
        info "    ${IMAGES_DIR}/rootfs.ext4   -- Guest 磁盘镜像"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    else
        if ! sudo -n true 2>/dev/null; then
            warn "构建 rootfs 需要 sudo 权限（mount/chroot）"
            sudo true || { fail "无法获取 sudo 权限"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
        fi

        info "编译自定义测试工具..."
        "${PROJECT_DIR}/scripts/build_guest_tools.sh" || warn "部分工具编译失败"

        if [ "$GUEST_TYPE" = "alpine" ]; then
            header "构建 Alpine rootfs"
            sudo "${PROJECT_DIR}/scripts/build_rootfs_alpine.sh" "$IMAGES_DIR"
        elif [ "$GUEST_TYPE" = "debian" ]; then
            header "构建 Debian rootfs"
            sudo "${PROJECT_DIR}/scripts/build_rootfs_debian.sh" "$IMAGES_DIR"
        fi

        if [ -f "${IMAGES_DIR}/rootfs.ext4" ]; then
            ok "Rootfs 构建完成: ${IMAGES_DIR}/rootfs.ext4"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fail "Rootfs 构建失败"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        if [ ! -f "${IMAGES_DIR}/bzImage" ]; then
            warn "bzImage 不存在，请手动准备: ${IMAGES_DIR}/bzImage"
        fi
    fi
```

- [ ] **Step 5: 修改末尾验证逻辑**

将:
```bash
    if [ "$GUEST_TYPE" = "minimal" ]; then
        for img in "${IMAGES_DIR}"/*.cpio.gz; do
            [ -f "$img" ] && check_artifact "initramfs" "$img"
        done
    elif [ "$GUEST_TYPE" = "full" ]; then
        check_artifact "cosim-guest.qcow2" "${IMAGES_DIR}/cosim-guest.qcow2"
    fi
```
替换为:
```bash
    if [ "$GUEST_TYPE" != "skip" ]; then
        check_artifact "rootfs.ext4" "${IMAGES_DIR}/rootfs.ext4"
    fi
```

- [ ] **Step 6: Commit**

```bash
git add setup.sh
git commit -m "refactor(setup): Alpine/Debian rootfs replaces buildroot minimal/full"
```

---

### Task 8: 删除废弃文件

**Files:**
- Delete: `build_initramfs.sh`
- Delete: `scripts/guest_init_phase5.sh`
- Delete: `scripts/guest_init_phase4.sh`
- Delete: `scripts/guest_init.sh`
- Delete: `scripts/guest_init_tap.sh`
- Delete: `scripts/build_guest_initramfs.sh`
- Delete: `guest/buildroot_defconfig`

- [ ] **Step 1: 删除废弃文件**

```bash
git rm build_initramfs.sh
git rm scripts/guest_init_phase5.sh
git rm scripts/guest_init_phase4.sh
git rm scripts/guest_init.sh
git rm scripts/guest_init_tap.sh
git rm scripts/build_guest_initramfs.sh
git rm guest/buildroot_defconfig
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove deprecated initramfs files"
```

---

### Task 9: 文档更新

**Files:**
- Modify: `README.md`
- Modify: `docs/SETUP-GUIDE.md`

- [ ] **Step 1: 更新 README.md Quick Start**

将 Guest 构建和启动部分更新为:

```markdown
### 2. 构建 Guest 系统

```bash
# Alpine (推荐)
./setup.sh --mode local --guest alpine

# Debian (完整工具链)
./setup.sh --mode local --guest debian
```

### 3. 启动联合仿真

```bash
# 终端 A
make run-qemu

# 终端 B
make run-vcs

# 回到终端 A，登录 root
cosim-start          # 配网
ping 10.0.0.2        # 测试
cosim-stop           # 退出
```

调试模式: `make run-qemu VERBOSE=1`
```

- [ ] **Step 2: 更新 SETUP-GUIDE.md**

更新 minimal/full 描述为 alpine/debian，构建步骤和运行步骤对应修改。

- [ ] **Step 3: Commit**

```bash
git add README.md docs/SETUP-GUIDE.md
git commit -m "docs: update README and SETUP-GUIDE for Alpine/Debian guest"
```
