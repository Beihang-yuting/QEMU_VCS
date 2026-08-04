# Guest 管理网 SCP 导入

`make run-qemu` 默认启用独立管理网卡：`MGMT_NET=1`。它是 QEMU 的 e1000e
user-NAT 网卡，不经过 DUT、VCS、PCIe 配置面或 DMA 数据面。RC0 的 SSH 端口固定为
QEMU 宿主机回环地址 `127.0.0.1:2222`；多 RC 时端口为
`MGMT_SSH_PORT_BASE + RC 编号`。

启动单 RC：

```bash
make run-qemu MGMT_NET=1 MGMT_SSH_PORT_BASE=2222
```

管理网只允许 QEMU 宿主机访问，导入文件示例：

```bash
scp -P 2222 ./dpu_snd1.ko ryan@127.0.0.1:/tmp/
ssh -p 2222 ryan@127.0.0.1
```

不需要管理口时关闭它：

```bash
make run-qemu MGMT_NET=0
```

## 手动加载自定义驱动

离线包默认不包含或自动加载 DPU 自定义驱动。导入后先确认模块与 Guest 内核完全匹配：

```bash
uname -r
modinfo -F vermagic /tmp/dpu_snd1.ko
```

本项目的 DPU 驱动 bundle 使用私有 `bonding.ko` 时，先加载它，再加载主模块：

```bash
sudo insmod /tmp/bonding.ko
sudo insmod /tmp/dpu_snd1.ko
lsmod | grep -E 'bonding|dpu_snd1'
dmesg -T | tail -n 100
```

不要创建 `/etc/modules-load.d/`、`cosim-driver.service` 或 `/etc/cosim/driver.conf`，
除非明确需要开机自动加载。保持手动加载时，Guest 重启会回到无自定义驱动的基线。
