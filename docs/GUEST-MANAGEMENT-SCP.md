# Guest 管理网、调试工具与驱动导入

`make run-qemu` 默认启用一张独立的 e1000e 管理网卡（`MGMT_NET=1`）。
它使用 QEMU user-mode NAT，只允许 QEMU 宿主机通过回环地址访问 Guest，
不经过 DUT、VCS、PCIe 配置面或 DMA 数据面。

## 选择 Guest profile

显式选择 compact Ubuntu Guest 或 Ubuntu Server Guest：

```bash
make run-qemu GUEST_TYPE=ubuntu MGMT_SSH_PORT_BASE=2222
make run-qemu GUEST_TYPE=ubuntu-server MGMT_SSH_PORT_BASE=2222
```

`GUEST_TYPE` 默认为 `ubuntu`。下表描述的是本次发布及其 Ubuntu Server v3
离线包中的**已生成镜像**，不是任意从零构建的 rootfs 都自动具备这些内容：

| profile | 默认内存 | 系统与用途 |
| --- | ---: | --- |
| `ubuntu` | 256M | 已 provision 的 compact Guest；沿用现有轻量镜像，含普通用户态 C/C++ 所需的 `build-essential`，但不含匹配的 kernel headers，因此不支持在 Guest 内原生编译 DPU 内核模块 |
| `ubuntu-server` | 2G | Ubuntu Server 24.04、内核 `6.8.0-107-generic`；含 `gcc`、`make` 和匹配 headers，支持在 Guest 内原生编译内核模块 |

本次发布生成的两个 profile 都预装以下静态链接工具：

```text
/usr/local/bin/pci_debug
/usr/local/bin/reg_display
```

`ubuntu-server` 还携带可在 Guest 内修改和重编的源码：

```text
/opt/dpu-debugutils
```

QEMU 命令行使用 `-snapshot`，因此 Guest 内的文件、软件包和配置改动默认只在
本次运行中有效，不会写回 `rootfs.ext4`。需要长期保留的文件应复制回宿主机，
或通过镜像构建/导入流程固化。

## 管理 SSH 与 SCP

RC0 默认把宿主回环地址的 2222 端口转发到 Guest 的 SSH 端口：

```bash
ssh -p 2222 ryan@127.0.0.1
```

这里的 2222 来自 `MGMT_SSH_PORT_BASE`，对应管理 e1000e 的
`hostfwd=tcp:127.0.0.1:2222-:22`。它不是 cosim 的 `PORT_BASE`；后者默认从
9100 开始，供 QEMU cosim PCIe 设备和 VCS 之间的 TCP 传输使用。多 RC 时，
管理 SSH 端口为 `MGMT_SSH_PORT_BASE + RC 编号`。

不需要管理网时可以关闭：

```bash
make run-qemu MGMT_NET=0
```

## BAR 调试工具

先用 `lspci` 确认实际 BDF，再查看工具帮助或访问 BAR0：

```bash
pci_debug -h
reg_display -h
sudo pci_debug -s 01:00.0 -b 0
sudo reg_display -s 01:00.0 -b 0
```

`-s` 接受 `lspci` 显示的设备地址，`-b 0` 选择 BAR0。两个工具通过 PCI sysfs
resource 映射访问 BAR，实际 BAR 访问需要 `sudo`；示例中的 `01:00.0` 只是常见
BDF，应以当前 Guest 的枚举结果为准。

## 在 Ubuntu Server 内编译并手工加载 DPU 驱动

PF0-only/QID128 host-driver-net 源码包是独立交付物。先在 QEMU 宿主机上传：

```bash
scp -P 2222 host-driver-net-pf0only-vnetcache.tar.gz ryan@127.0.0.1:/tmp/
ssh -p 2222 ryan@127.0.0.1
```

然后在 `ubuntu-server` Guest 内编译、核对内核 ABI，并手工加载和卸载：

```bash
cd /tmp
tar -xf host-driver-net-pf0only-vnetcache.tar.gz
cd host-driver-net
make KERNELDIR=/lib/modules/$(uname -r)/build
modinfo ./dpu_snd1.ko | grep vermagic
sudo insmod ./dpu_snd1.ko
lsmod | grep dpu_snd1
sudo rmmod dpu_snd1
```

`modinfo` 输出的 vermagic 必须与 `uname -r` 对应；当前 server profile 是
`6.8.0-107-generic`。只有 `ubuntu-server` 提供匹配 headers 并支持上述原生
内核模块编译。compact `ubuntu` 的资源和 kernel-build 工具有限，应在宿主机上
针对 Guest 的精确内核 headers 编译 `.ko`，再经管理 SCP 导入；导入前后都必须
确认 vermagic 匹配。

驱动加载是运行时的手工操作。默认镜像和默认离线包不包含 direct DPU
`dpu_snd1.ko`，不会安装它，也不会配置 autoload。离线打包时显式使用
`--custom-driver` 只是保留携带/导入兼容素材的能力，并不表示默认镜像会自动加载
驱动。

## setup、离线导入与 relocated archive

### 使用已经生成或导入的镜像

以下命令用于选择**已经存在**的 profile，并以普通用户构建 QEMU/Bridge：

```bash
./setup.sh --mode qemu-only --guest ubuntu
./setup.sh --mode qemu-only --guest ubuntu-server
```

如果 `guest/images/ubuntu-server/` 还没有完整镜像，不要依赖当前 `setup.sh` 的
自动 fallback：它会以调用 `setup.sh` 的普通用户直接执行 server builder，无法
满足 builder 的 root 和 Guest 密码前置条件。也不要用 `sudo ./setup.sh ...`，
否则会让整个项目构建产物变为 root ownership。安全的从零构建流程见下一节。

### 从零构建 Ubuntu Server 镜像

真实构建需要外网、`debootstrap` 等 builder 依赖、EUID 0，以及非空的
`COSIM_GUEST_SSH_PASSWORD`。先以普通用户准备共享内核和调试工具，并查看无副作用
的构建计划：

```bash
./scripts/setup-ubuntu-kernel.sh 6.8.0-107-generic
./scripts/build_dpu_debugutils.sh
./scripts/build_rootfs_ubuntu_server.sh --dry-run \
  "$PWD/guest/images/ubuntu-server"
```

然后只对 rootfs builder 提权。密码通过环境传入，不要写入命令行、脚本或归档：

```bash
read -rsp 'Password for Guest user ryan: ' COSIM_GUEST_SSH_PASSWORD
printf '\n'
export COSIM_GUEST_SSH_PASSWORD

if sudo --preserve-env=COSIM_GUEST_SSH_PASSWORD \
    ./scripts/build_rootfs_ubuntu_server.sh \
    "$PWD/guest/images/ubuntu-server"; then
  build_status=0
else
  build_status=$?
fi
unset COSIM_GUEST_SSH_PASSWORD
test "$build_status" -eq 0
```

builder 启动后立即从环境捕获并移除该变量；通过 `sudo` 启动时的 `SUDO_USER` 还用于
把最终三个镜像产物归还给调用者。镜像生成以后，再以普通用户运行前面的
`./setup.sh --mode qemu-only --guest ubuntu-server`，不要把整个 setup 放到 `sudo`
下执行。`sudo` policy 必须允许保留这个指定变量；若拒绝 `--preserve-env`，应由
管理员配置该权限，不要改成把密码直接写在命令行里。

### compact 镜像的 provisioning 边界

本次发布/离线包中的 compact 镜像已经 provision，因此有 `ryan` 管理账号、SSH、
`sudo` 和 `build-essential`。但是，从空目录运行
`./setup.sh --mode qemu-only --guest ubuntu` 时，即使外网和 `sudo -n` 条件满足，
其 fallback 也只构建 Debian minbase、注入 Ubuntu 内核模块和调试工具；它不会
自动调用 `provision_guest_ssh.sh`。对这种新生成的 compact rootfs，确认文件已经
存在且宿主可联网后，再以普通用户执行；该脚本会在需要时调用 `sudo`：

```bash
test -f "$PWD/guest/images/ubuntu/rootfs.ext4"
read -rsp 'Password for Guest user ryan: ' COSIM_GUEST_SSH_PASSWORD
printf '\n'
export COSIM_GUEST_SSH_PASSWORD

if ./scripts/provision_guest_ssh.sh \
    --rootfs "$PWD/guest/images/ubuntu/rootfs.ext4" --user ryan; then
  provision_status=0
else
  provision_status=$?
fi
unset COSIM_GUEST_SSH_PASSWORD
test "$provision_status" -eq 0
```

该脚本只从环境读取密码，并在内部仅对 mount/chroot 等操作使用 `sudo`。如果不想
在目标机联网 provision compact，请直接使用本次发布的离线镜像，不要把未
provision 的从零构建 rootfs 当作具有上述管理能力。

### 生成和导入离线包

先确认本次发布要求的 compact 与 server 镜像都已经构建并 provision，再以普通
用户打包。此时显式使用 `--skip-rootfs`，避免 packager 再进入当前不可用的自动
builder fallback；packager 仍会通过 `sudo` 只读挂载并验证两套 rootfs：

```bash
for artifact in \
  guest/images/ubuntu/vmlinuz \
  guest/images/ubuntu/rootfs.ext4 \
  guest/images/ubuntu-server/vmlinuz \
  guest/images/ubuntu-server/modules.tar.gz \
  guest/images/ubuntu-server/rootfs.ext4; do
  test -f "$artifact" || { printf 'missing: %s\n' "$artifact" >&2; exit 1; }
done

./setup.sh --prepare-offline --guest ubuntu-server \
  --skip-rootfs \
  --output /path/to/cosim-offline-ubuntu-server.zip
```

这种新 Ubuntu Server 离线包同时携带 `guest/ubuntu` 和
`guest/ubuntu-server` 两套镜像。导入一次以后，运行时仍用 `GUEST_TYPE=ubuntu`
或 `GUEST_TYPE=ubuntu-server` 选择，不需要重新导入。

“relocated archive” 指把 zip 移到与产出目录不同的任意绝对路径，并在另一个
项目目录中导入，以确认包内没有依赖原构建机的绝对路径。例如：

```bash
cd /path/to/relocated/cosim-platform
./setup.sh --import /other/path/cosim-offline-ubuntu-server.zip --import-only
make run-qemu GUEST_TYPE=ubuntu-server MGMT_SSH_PORT_BASE=2222
```

`--import-only` 只把离线素材导入当前项目；需要同时继续编译安装时，省略它并指定
部署选择，例如：

```bash
./setup.sh --import /other/path/cosim-offline-ubuntu-server.zip \
  --mode qemu-only --guest ubuntu-server
```

导入镜像与运行时手工加载驱动是两个独立步骤；导入不会替代上面的 `insmod`
流程。

## 真实 DUT / cosim 参数

接入真实 DUT 时，QEMU 侧的 `TAG_BIT`/`NUM_PFS` 必须与 VCS 侧的
`+TAG_BIT`/`+NUM_PFS` 成对一致。例如，QEMU 侧声明 8-bit tag、4 PF：

```bash
make run-qemu GUEST_TYPE=ubuntu-server NUM_PFS=4 TAG_BIT=8 \
  PCIE_PREF64_RESERVE=256M
```

VCS 侧现有真实 DPU invocation 使用相同数值：

```text
+REAL_DUT +BYPASS_CONFIG=1 +CFG_PROFILE=DPU_20F9_501X \
  +NUM_PFS=4 +MAX_VFS=16 +TAG_BIT=8
```

`TAG_BIT` 只接受 8 或 10；QEMU Makefile 将它写入连接描述符，VCS
`cosim_xrc_driver` 解析对应的 `+TAG_BIT`。BAR 空间、profile、真实 DUT top 和
Completion 来源等其余要求不要从本文另行推导；按
[CoSim VCS 侧集成指南](COSIM-VCS-INTEGRATION.md)第 8 节中的真实 DUT 配置启动。
