# QEMU 管理网卡 SCP 服务设计

## 目标

让 `feature/qemu-vcs-isolated-tcp` 已有的 QEMU 管理网卡能够从 QEMU 宿主机向
正在运行的 Ubuntu Guest 导入文件。管理通道只绑定宿主机回环地址，不经过 DUT、VCS
或 PCIe cosim 数据面；新离线包不得包含或自动加载 DPU 自定义驱动。

## 架构

保留已有的 `MGMT_NET=1` 默认行为：QEMU 为每个 RC 创建一张 e1000e 网卡，RC0 的
宿主机端口是 `127.0.0.1:2222`，映射到 Guest TCP 22；多 RC 继续使用
`MGMT_SSH_PORT_BASE + rc_index`。DUT 使用的 Root Port 保持固定地址，因此管理网卡
不改变 DUT 下游 BDF。

Ubuntu rootfs 在打包前安装并启用 OpenSSH server，配置一个仅用于本地管理网的非 root
测试登录。登录口令不进入 Git、脚本、文档或离线包清单；构建时由受控环境变量提供，
并只在 rootfs 的密码哈希中存在。sshd 仅接受经 QEMU `hostfwd` 的回环连接。

离线包仍只包含 QEMU、Guest 镜像、内核模块和构建素材；不会传入 `--custom-driver`，
rootfs 中也不保留 `dpu_snd1.ko`、`cosim-driver.service`、`driver.conf` 或自动加载
脚本。

## 使用流程

```text
Host file
  -> scp -P 2222 127.0.0.1
  -> QEMU user-NAT / loopback-only hostfwd
  -> e1000e management NIC
  -> Guest sshd
  -> /tmp or user home directory
```

Guest 内手工执行 `insmod` 加载导入的驱动；本设计不创建 modules-load 配置或 systemd
驱动服务，因此重启后保持无自定义驱动的默认状态。

## 验证

1. 启动参数测试继续确认 `MGMT_NET=1` 的 e1000e/hostfwd 参数及 `MGMT_NET=0` 关闭行为。
2. 新测试检查 rootfs 配置脚本不会把登录口令写入源码，且仅写入 `sshd` 所需文件。
3. 在 53 启动 QEMU 后，从同一宿主机通过 `127.0.0.1:2222` 运行 SSH 和 SCP，比较导入文件的 SHA-256。
4. 检查最终 zip 的 SHA-256 与 `unzip -t`，并用 `debugfs` 确认自定义 DPU 模块和自动加载文件均不存在。
