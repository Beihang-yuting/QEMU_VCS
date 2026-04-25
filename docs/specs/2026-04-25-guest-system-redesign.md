# Guest 系统改造设计

日期: 2026-04-25

## 背景

当前 Guest 系统存在以下问题:
- setup.sh 的 minimal/full 选择是空壳，实际都走 buildroot 生成 rootfs.ext4
- initramfs 模式无法生成，minimal 名不副实
- rootfs.ext4 启动后：DHCP 自动配网导致 TX timeout 刷屏、无欢迎信息、缺少测试工具、无退出提示
- debug 打印无法运行时控制，需重新编译 QEMU
- 内核消息和 cosim 日志混在用户终端，影响交互

## 目标

用户执行 `make run-qemu` 后看到干净的终端，登录后有清晰的操作指引，能手动控制测试节奏，需要调试时通过参数打开详细日志。

## 设计

### 1. 模式简化

去掉 minimal（initramfs），只保留 full 模式。支持两种 rootfs:

| | Alpine Linux | Debian 精简版 |
|---|---|---|
| 包管理 | apk | apt |
| 镜像大小 | ~50MB | ~500MB |
| 启动速度 | ~3 秒 | ~15 秒 |
| Guest 内编译驱动 | 支持（需 apk add gcc） | 开箱即用 |
| 适用场景 | 功能测试、快速迭代 | 驱动开发、全能力测试 |

setup.sh 交互菜单:
```
选择 Guest 系统:
  1) Alpine Linux  — 轻量快速，apk 包管理（推荐）
  2) Debian 精简版 — 完整工具链，apt 包管理
  3) 跳过 — 手动准备 rootfs 到 guest/images/
```

### 2. 构建流程

#### Alpine
1. 下载官方 minirootfs tar (~3MB)
2. 创建 ext4 镜像，mount loop
3. 解压 tar 到挂载点
4. chroot 内 `apk add` 安装工具包
5. 拷入自定义工具和脚本
6. umount，生成 rootfs.ext4
- 需要: sudo（mount/chroot）、联网（apk add）
- 离线: 提示用户预下载 tar 包放到 `third_party/alpine-minirootfs.tar.gz`

#### Debian
1. `debootstrap --variant=minbase` 创建精简系统
2. chroot 内 `apt install` 安装工具包
3. 拷入自定义工具和脚本
4. 打包为 ext4 镜像
- 需要: sudo（debootstrap/chroot）、debootstrap 已安装、联网
- 离线: 提示用户从其他机器 scp rootfs.ext4 或预下载 debootstrap cache

#### 预装工具（两种都包含）

| 类别 | 包 |
|------|-----|
| 网络测试 | iperf3, iproute2, iputils (ping), ethtool, tcpdump |
| PCIe 诊断 | pciutils (lspci) |
| 系统工具 | kmod (insmod/modprobe), util-linux, procps |
| RDMA | rdma-core, perftest |
| 自定义工具 | cfgspace_test, virtio_reg_test, dma_test, nic_tx_test, devmem_test |

自定义 C 测试工具在 host 上静态编译（`-static`），拷入 rootfs 的 `/usr/local/bin/`。

#### 内核
使用现有 buildroot 构建的 bzImage，或从 setup.sh 提供的源编译。内核与 rootfs 独立，两种 rootfs 共用同一个 bzImage。

### 3. Guest 启动体验

#### 内核 cmdline
```
console=ttyS0 root=/dev/vda rw quiet loglevel=1 guest_ip=10.0.0.1 peer_ip=10.0.0.2
```
- `quiet loglevel=1`: 默认只显示 CRITICAL 内核消息，TX timeout 等 WARNING 不上屏
- `guest_ip`/`peer_ip`: 供 cosim-start 读取

#### 登录后欢迎信息
通过 `/etc/motd` 或 `/etc/profile.d/cosim.sh` 显示:
```
============================================
 CoSim Guest (Alpine/Debian)

 VCS 未连接 -- 请在另一个终端执行:
   make run-vcs

 VCS 就绪后:
   cosim-start               一键配网
   cosim-start 10.0.0.2      指定 IP

 退出:
   cosim-stop                停止仿真 (通知 VCS 退出)
   Ctrl+A X                  强制退出 QEMU
============================================
```

#### cosim-start（/usr/local/bin/cosim-start）
```sh
#!/bin/sh
# 读取 cmdline 参数或使用命令行参数
IP="${1:-$(sed 's/.*guest_ip=\([^ ]*\).*/\1/' /proc/cmdline)}"
IP="${IP:-10.0.0.1}"

ip link set eth0 up
ip addr flush dev eth0 2>/dev/null
ip addr add "$IP/24" dev eth0

echo "eth0: $IP/24 -- ready"
echo ""
echo "Available commands:"
echo "  ping <peer_ip>           connectivity test"
echo "  iperf3 -s / -c <ip>     throughput test"
echo "  lspci -vv               PCI device list"
echo "  cfgspace_test           Config Space verification"
echo "  virtio_reg_test <BAR>   Virtio register verification"
echo "  dma_test <BAR>          DMA read/write test"
echo "  nic_tx_test <BAR>       NIC TX test"
echo "  devmem <ADDR>           direct MMIO read/write"
```

#### cosim-stop（/usr/local/bin/cosim-stop）
```sh
#!/bin/sh
echo "cosim: notifying VCS to stop..."
poweroff
```

### 4. Debug 打印运行时开关

#### QEMU 设备属性
在 `cosim_pcie_rc` 设备上加 `debug` 属性:
```c
// cosim_pcie_rc.h -- CosimPCIeRC 结构体加字段
bool debug;

// cosim_pcie_rc.c -- 属性定义
DEFINE_PROP_BOOL("debug", CosimPCIeRC, debug, false),

// cosim_pcie_rc.c -- 打印宏改为运行时判断
#define COSIM_DPRINTF(s, fmt, ...) do { \
    if ((s)->debug) fprintf(stderr, "cosim: " fmt, ##__VA_ARGS__); \
} while (0)
```

使用:
```bash
# 默认：无 debug 打印
-device "cosim-pcie-rc,shm_name=/cosim0,sock_path=..."

# 调试：打开 debug 打印
-device "cosim-pcie-rc,shm_name=/cosim0,...,debug=on"
```

#### Makefile VERBOSE 参数

| 命令 | 效果 |
|------|------|
| `make run-qemu` | quiet loglevel=1, debug=off, stderr 只写日志文件 |
| `make run-qemu VERBOSE=1` | loglevel=7, debug=on, stderr 终端+日志文件 |

实现:
```makefile
ifeq ($(VERBOSE),1)
  _LOGLEVEL = loglevel=7
  _COSIM_DEBUG = ,debug=on
else
  _LOGLEVEL = quiet loglevel=1
  _COSIM_DEBUG =
endif

_QEMU_APPEND = console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=$(GUEST_IP) ...
_QEMU_DEV = cosim-pcie-rc,...$(_COSIM_DEBUG)
```

启动提示:
```
============================================
 QEMU (shm mode, Guest: drive)
 Log: logs/qemu.log
 Debug: make run-qemu VERBOSE=1
============================================
```

### 5. setup.sh 改造

```
setup.sh flow:

[1] 选择部署模式 (local / qemu-only / vcs-only)     -- 保持不变
[2] 选择 Guest 系统 (Alpine / Debian / 跳过)          -- 替换 minimal/full
[3] QEMU 源码 (download / path / skip)                -- 保持不变
[4] 依赖检查 + 权限检查
    - sudo 权限（chroot/debootstrap/mount 需要）
    - 网络连通性（在线 -> 直接构建；离线 -> 提示手动准备）
    - debootstrap 是否安装（仅 Debian）
[5] 构建 Guest rootfs
    - Alpine: 下载 minirootfs -> chroot apk add -> 打包 ext4
    - Debian: debootstrap -> chroot apt install -> 打包 ext4
    - 两者都: 静态编译自定义 C 工具 -> 拷入 rootfs
[6] 编译 QEMU + Bridge
[7] 验证 + 使用提示
```

CLI 支持:
```bash
./setup.sh --mode local --guest alpine
./setup.sh --mode local --guest debian
./setup.sh --mode qemu-only --guest alpine
```

### 6. Makefile 变更

- 去掉 INITRD 变量和 initramfs 分支
- `_GUEST_MODE` 只有 `drive` 和 `none`
- 新增 `VERBOSE` 参数控制日志级别和 debug 开关
- 启动提示加日志路径和 VERBOSE 用法

### 7. 删除清理

| 文件 | 原因 |
|------|------|
| `build_initramfs.sh` | initramfs 模式移除 |
| `scripts/guest_init_phase5.sh` | initramfs init 脚本 |
| `scripts/guest_init_phase4.sh` | initramfs init 脚本 |
| `scripts/guest_init.sh` | initramfs init 脚本 |
| `scripts/guest_init_tap.sh` | initramfs init 脚本 |
| `scripts/build_guest_initramfs.sh` | initramfs 构建脚本 |
| `guest/buildroot_defconfig` | 不再用 buildroot |

保留:
- `guest/overlay/` -- cosim-start/cosim-stop/motd 的源文件
- `scripts/*.c` -- 自定义测试工具源码，静态编译后拷入 rootfs

### 8. 退出机制

| 场景 | 操作 | 效果 |
|------|------|------|
| 正常结束 | Guest 内 `cosim-stop` 或 `poweroff` | QEMU bridge_destroy -> 发 SHUTDOWN -> VCS 退出 |
| 强制退出 | `Ctrl+A X` | QEMU 退出 -> 通知 VCS shutdown |
| VCS 侧主动停 | VCS 终端 `Ctrl+C` | VCS 停止，QEMU 检测到断连 |

已有 bridge_destroy -> SYNC_MSG_SHUTDOWN 机制（commit c247263），无需额外开发。

### 9. 用户完整操作流程

```
1. ./setup.sh --mode local --guest alpine     # 一次性构建环境
2. make run-qemu                               # 终端 1: 启动 QEMU
   -> 看到 login prompt（终端干净，无刷屏）
3. make run-vcs                                # 终端 2: 启动 VCS
4. 回到终端 1，登录 root
   -> 看到欢迎信息和操作指引
5. cosim-start                                 # 配网
   -> "eth0: 10.0.0.1/24 -- ready"
6. ping 10.0.0.2                               # 连通性测试
7. iperf3 -s                                    # 吞吐量测试
8. lspci -vv                                    # PCIe 诊断
9. cosim-stop                                   # 结束，VCS 自动退出
```
