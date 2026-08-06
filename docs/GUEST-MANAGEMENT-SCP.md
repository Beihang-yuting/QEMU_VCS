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

`GUEST_TYPE` 默认为 `ubuntu`。两个 profile 的区别如下：

| profile | 默认内存 | 系统与用途 |
| --- | ---: | --- |
| `ubuntu` | 256M | compact Guest；沿用现有轻量镜像，含普通用户态 C/C++ 所需的 `build-essential`，但不含匹配的 kernel headers，因此不支持在 Guest 内原生编译 DPU 内核模块 |
| `ubuntu-server` | 2G | Ubuntu Server 24.04、内核 `6.8.0-107-generic`；含 `gcc`、`make` 和匹配 headers，支持在 Guest 内原生编译内核模块 |

两个 profile 都预装以下静态链接工具：

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

联网构建时通过 `setup.sh` 选择 profile：

```bash
./setup.sh --mode qemu-only --guest ubuntu
./setup.sh --mode qemu-only --guest ubuntu-server
```

生成 Ubuntu Server 离线包时选择 `ubuntu-server`：

```bash
./setup.sh --prepare-offline --guest ubuntu-server \
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

接入真实 DUT 时，`TAG_BIT`、`NUM_PFS`、BAR 空间以及 QEMU/VCS 两侧参数必须
保持一致。不要从本文另行推导 plusarg 或拓扑参数；按
[CoSim VCS 侧集成指南](COSIM-VCS-INTEGRATION.md)第 8 节中的真实 DUT 配置和
一致性要求启动 QEMU 与 VCS。
