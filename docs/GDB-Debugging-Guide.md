# GDB 调试指南

本指南介绍如何使用 GDB 调试 QEMU-VCS CoSim Platform 的三类问题：
Guest 内核/驱动、Bridge 库、QEMU 自定义设备本身。

---

## 1. 调试 Guest 内核或驱动

### 1.1 启用 QEMU GDB Stub

`scripts/run_cosim.sh` 已内置 `GDB=1` 开关，启动 QEMU 时会加 `-s -S` 参数，
在 TCP `:1234` 监听 gdb 并暂停 CPU 等待接入。

```bash
GDB=1 ./scripts/run_cosim.sh
```

日志会提示：

```
GDB server enabled on :1234 (waiting for connection)
```

### 1.2 另一终端接入

假设你的 Guest 内核带调试符号（`vmlinux`）：

```bash
gdb /path/to/vmlinux
(gdb) target remote :1234
(gdb) hbreak start_kernel
(gdb) continue
```

### 1.3 调试驱动模块

驱动 `.ko` 的符号需要手动加载，先在 Guest 里 `insmod` 一次看 `sections`：

```bash
# Guest shell
cat /sys/module/cosim_drv/sections/.text       # 得到地址 0xffffffffa0XXXXXX
```

再在 gdb 里：

```gdb
(gdb) add-symbol-file /path/to/cosim_drv.ko 0xffffffffa0XXXXXX
(gdb) break cosim_drv_probe
(gdb) continue
```

### 1.4 常用技巧

- `lx-symbols` 命令可自动扫描所有模块（需 Linux 源码的 `scripts/gdb`）
- `info threads` 列出所有 vCPU；`thread 2` 切到 CPU1
- 若 VCS 端把仿真时间锁住，QEMU 的 gdb 仍可用，但 MMIO 访问会卡直到 VCS 恢复

---

## 2. 调试 Bridge 库

Bridge 是一个普通的 Linux 用户态共享库，标准 gdb 即可。

### 2.1 调试单元/集成测试

测试二进制默认带 `-g`（见顶层 `CMakeLists.txt`）。直接 attach：

```bash
gdb build/tests/integration/test_dma_roundtrip
(gdb) break bridge_complete_dma
(gdb) run
```

### 2.2 调试 QEMU 加载的 libcosim_bridge.so

在 QEMU 启动后，另开终端 attach：

```bash
pgrep -af qemu-system-x86_64        # 拿到 PID
gdb -p <PID>
(gdb) break bridge_send_tlp
(gdb) continue
```

注意：QEMU 通常运行多线程，断点触发后会 stop 全部线程。

### 2.3 调试 VCS 内的 libcosim_bridge_vcs.so

VCS 进程本身是 Synopsys 构建的，attach 流程相同：

```bash
pgrep -af simv
gdb -p <PID>
(gdb) break vcs_bridge_poll_tlp_dpi
```

---

## 3. 调试自定义 PCIe 设备 `cosim-pcie-rc`

`qemu-plugin/cosim_pcie_rc.c` 会被编入 QEMU 二进制。

### 3.1 确保 QEMU 带调试符号

```bash
cd $QEMU_SRC
./configure --target-list=x86_64-softmmu --enable-debug --enable-kvm
make -j$(nproc)
```

### 3.2 在 QEMU 启动后 attach

```bash
gdb $QEMU_SRC/build/qemu-system-x86_64
(gdb) attach $(pgrep qemu-system-x86_64)
(gdb) break cosim_pcie_rc_realize
(gdb) break cosim_mmio_read
(gdb) break cosim_dma_cb
(gdb) continue
```

### 3.3 常见断点

| 函数 | 用途 |
|---|---|
| `cosim_pcie_rc_realize` | 设备初始化、bridge 连接 |
| `cosim_mmio_read` / `cosim_mmio_write` | Guest 的 BAR 访问入口 |
| `cosim_dma_cb` | VCS 发起 DMA 时的回调 |
| `cosim_msi_cb` | VCS 触发 MSI 时的回调 |
| `cosim_pcie_rc_exit` | 关机/移除设备时 |

---

## 4. 同时调试 QEMU + VCS（进阶）

由于 QEMU 与 VCS 是两个独立进程，GDB 一次只能附一个。推荐工作流：

1. **先跑稳 Bridge 单元测试**（`test_bridge_loopback` 等），把 Bridge 层的 bug 压到最少
2. **Bridge 层有问题** → attach QEMU 或 VCS 进程做用户态 gdb
3. **Guest 内核/驱动有问题** → 用 QEMU GDB stub（端口 1234）
4. **RTL 时序问题** → 切到精确模式（`bridge_request_mode_switch`）+ 开 trace（`bridge_enable_trace`），再配合 VCS 波形（fsdb / vcd）

---

## 5. 常用的 GDB 命令速查

```gdb
# 控制
c / continue            # 继续
n / next                # 单步跳过函数
s / step                # 单步进入函数
fin / finish            # 跑完当前函数
up / down               # 切换栈帧

# 打印
p var                   # 打印变量
p *ctx                  # 打印结构体
p/x val                 # 十六进制
info locals             # 当前栈帧所有局部变量
info threads            # 所有线程
bt / backtrace          # 调用栈

# 断点
b func                  # 按函数名
b file.c:123            # 按行号
cond 1 i==100           # 条件断点
commands 1 ... end      # 断点自动动作

# 数据观察
watch var               # 写入时断
rwatch var              # 读取时断
x/16xw 0xADDR           # 查看内存 16 个 word
```

---

## 6. 故障排查

| 症状 | 原因 | 处理 |
|---|---|---|
| `target remote :1234` 连不上 | QEMU 没带 `-s` 或端口被占 | 确认 `GDB=1`；`lsof -i:1234` |
| attach 报 "Operation not permitted" | 内核 ptrace 限制 | `echo 0 \| sudo tee /proc/sys/kernel/yama/ptrace_scope` |
| 断点一触发就 segfault | 共享库符号未加载 | 先 `continue` 让进程跑到加载后再下断 |
| MMIO 单步后 Guest 冻结 | VCS 仿真仍在等 | 另一终端看 VCS 是否前进；必要时在 VCS 侧 `force stop` |

---

## 参考

- QEMU 官方 GDB 文档：[https://qemu-project.gitlab.io/qemu/system/gdb.html](https://qemu-project.gitlab.io/qemu/system/gdb.html)
- Linux 内核 GDB 脚本：`linux/scripts/gdb/`
- 本项目源码调试符号：`make bridge`（默认 `-DCMAKE_BUILD_TYPE=Debug`）
