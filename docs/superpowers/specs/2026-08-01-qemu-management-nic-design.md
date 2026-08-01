# QEMU 默认管理网卡设计

## 目标

为 `make run-qemu` 启动的每个 QEMU Guest 添加一张独立的管理网卡，用于从 QEMU
宿主机向 Guest 导入文件。该网卡不能经过 DUT、VCS 或 cosim PCIe 数据面。

## 方案

使用 QEMU user-mode NAT 后端和一张 `e1000e` 网卡。默认启用；主机侧 SSH 端口只绑定
`127.0.0.1`，不向内网暴露。

每个实例 `r` 的启动参数为：

```
-netdev user,id=mgmtnet<r>,hostfwd=tcp:127.0.0.1:<base+r>-:22
-device e1000e,netdev=mgmtnet<r>,mac=52:54:00:53:00:<r+1>
```

单实例 `CONSOLE=login` 使用 `r=0`。`login-multi` 和 `file` 在循环中使用当前的
`r`。这样 `NUM_RC>1` 时网卡 ID、MAC 和端口都唯一。

## 接口

- `MGMT_NET ?= 1`：默认创建管理网卡；值为 `0` 时不添加任何管理网络参数。
- `MGMT_SSH_PORT_BASE ?= 2222`：RC `r` 的宿主 SSH 端口为
  `MGMT_SSH_PORT_BASE + r`。
- 值必须受 Makefile 验证，避免错误配置或命令注入。

使用示例：

```bash
make run-qemu
scp -P 2222 tool user@127.0.0.1:/tmp/

make run-qemu NUM_RC=2 CONSOLE=login-multi
# RC0: 127.0.0.1:2222; RC1: 127.0.0.1:2223

make run-qemu MGMT_NET=0
```

Guest 必须有 `e1000e` 驱动、通过 DHCP 获得 user-NAT 地址，并已有 SSH server；该功能
不负责向 Guest 安装 SSH server 或修改 Guest rootfs。

## 隔离与安全

管理网络仅是普通 QEMU 外设，QEMU 内部 NAT 与 PCIe cosim 通路相互独立。端口绑定
`127.0.0.1`，只有 QEMU 宿主机可访问。不会改变 `+REAL_DUT`、`+BYPASS_CONFIG=1`、
VCS 配置空间模拟或 DMA 数据面。

## 错误处理与验证

`run-qemu` 将在启动前验证 `MGMT_NET` 仅能为 `0` 或 `1`，端口基数为合法 TCP 端口，
并保留所有现有的 QEMU 启动检查。

集成测试以 `make -n run-qemu` 覆盖三种 `CONSOLE` 路径，确认：

1. 默认命令包含一个 user-NAT 后端和 `e1000e` 网卡；
2. 多实例端口与网卡 ID 不重复；
3. `MGMT_NET=0` 不包含管理网络参数；
4. 非法变量被拒绝且不会执行注入内容。
