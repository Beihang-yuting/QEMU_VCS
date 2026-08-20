# 把 cosim 加进现有(已跑通的)pcie-tl-vip + xilinx-pcie 环境 —— 最小改动

前提:你的环境已集成 pcie-tl-vip + xilinx-pcie 且跑通。目标:**只做加法**,
一个命令行开关切换「环境自己收发包(原始功能)」vs「QEMU 收发包(cosim)」,
不改任何原始文件行为。

## 一句话

```
+COSIM 存在  → RC driver 换成 cosim_xrc_driver,收发包来自 QEMU(真 guest/驱动)
+COSIM 不存在 → 你原来的 driver + sequencer 驱动,原始功能,零改动
```

原理:`cosim_maybe_enable()` 只在 `+COSIM` 时对 UVM 工厂做一次
`pcie_tl_rc_driver → cosim_xrc_driver` 的 type override;不存在就直接 return,
工厂无任何改动 → 你的原 driver 照常 build。driver 自读 `+REMOTE_HOST/+PORT_BASE`
连 QEMU,不需要你写 init。

---

## 三步接入(改动 = 加文件 + 1 行)

### 1. filelist 加这些(SV)

```
<cosim>/bridge/vcs/bridge_vcs.sv       # cosim_bridge_pkg (DPI 声明)
<cosim>/vcs-tb/cosim_xrc_pkg.sv        # 含 driver + enable 开关(内部 include 其余)
```
> `cosim_xrc_pkg.sv` 内部 `include cosim_xrc_driver.sv` 并提供 `cosim_maybe_enable()`。
> +incdir 加 `<cosim>/bridge/vcs` 与 `<cosim>/vcs-tb`。顺序:在 pcie_tl_pkg +
> xilinx_pcie_adapter_pkg **之后**编。

### 2. C 库(二选一,见 [COSIM-C-BUILD.md](COSIM-C-BUILD.md))

```bash
# 方式 A:静态库
make cosim-lib                      # → build/lib/libcosim_bridge.a
# vcs 链接加:
#   -LDFLAGS "-L<cosim>/build/lib -lcosim_bridge -Wl,--no-as-needed -lrt -lpthread"

# 方式 C:inline(最省心,ABI 最稳)—— 把 bridge/vcs/*.c bridge/common/*.c 丢给 vcs
```

### 3. 你的 test 加 1 行(build_phase,建 env 之前)

```systemverilog
import cosim_xrc_pkg::*;                 // 文件头
...
function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cosim_xrc_pkg::cosim_maybe_enable();  // ← 唯一改动;无 +COSIM 时是 no-op
    // ... 你原来的 env 创建照旧
endfunction
```
> 你 env 已接 xilinx adapter → 用无参 `cosim_maybe_enable()`。
> 若 env 还在用基类 `pcie_tl_if_adapter` → `cosim_maybe_enable(1)`(顺带 override adapter)。

**不用改** env / driver / sequence / adapter 任何原始文件。

---

## 跑

```bash
# 原始功能(环境收发包)—— 什么都不加,和你现在一样
./simv +UVM_TESTNAME=<你的test> <你原来的 plusarg...>

# cosim(QEMU 收发包)—— 加 3 个 plusarg
./simv +UVM_TESTNAME=<你的test> \
       +COSIM +REMOTE_HOST=<QEMU机IP> +PORT_BASE=9100 \
       +BYPASS_CONFIG=1
```
QEMU 侧先起(见 [COSIM-ISOLATED-ENVS.md](COSIM-ISOLATED-ENVS.md) 的 `make run-qemu`)。
多 RC:每个 rc_agent_<N> 的 cosim driver 自动用 instance_id=N 连
`PORT_BASE + N*3`。

---

## 为什么这样最小 / 不影响原功能

| 关注 | 保证 |
|---|---|
| 原始功能 | 无 `+COSIM` → `cosim_maybe_enable` 直接 return,工厂零 override,原 driver 照跑 |
| 只加法 | 新增文件 + 1 行调用;不改 env/driver/seq/adapter |
| 切换 | 纯命令行 `+COSIM`,编一次 simv 两用 |
| 多 RC | driver 从层级名 `rc_agent_<N>` 自取 rc_index,per-RC 连独立 QEMU |
| init | driver 自初始化(读 plusarg 连 QEMU),你不用写 init 代码 |

---

## 边界(cosim 模式下)

- cosim 模式 driver 用 DPI polling 取代 sequencer:该模式下**别再起你的
  sequence**(driver 不 get_next_item)。原始模式不受影响。
- 收发包 = MMIO(QEMU 读写 DUT BAR)+ config bypass。DUT 主动 DMA(RQ 入向)+
  MSI 目前是占位(下一增量)。
- device 身份默认 1af4:1041;不同则加 `+CFG_VENDOR_ID=.. +CFG_DEVICE_ID=.. +CFG_BAR0_SIZE=..`
  (或从 `cosim-conn.json` 的 `device.*` 字段解析后自带,见 [COSIM-ISOLATED-ENVS.md](COSIM-ISOLATED-ENVS.md) §2)。

---

## 可选：语义表 backdoor

表 backdoor 仍采用“编译一次、运行时选择”。把生产 handler 与上述两个 SV
入口一起编进 `simv`；在 `build_phase` 中、RC driver 启动前注册每个 RC 的
handler。仓库中的 `vcs-tb/examples/vio_notify_mock_handler.sv` 只保存数组，适合
作为打包和多 RAM 选址参考，不包含任何 DUT 层次。

```systemverilog
cosim_xrc_pkg::cosim_maybe_enable();
handler[0] = new("vio_notify");
if (!cosim_table_runtime::register_handler(
        0, handler[0], COSIM_TABLE_PROTECTION_NONE))
  `uvm_fatal("TABLE", "RC0 handler registration failed")
```

多 DUT/多 RC 时，每个 RC 分别构造并用对应的 `rc` 参数注册；同一个 handler
名称可以在不同 RC 上独立存在。生产 handler 负责选择内建或自定义 codec、把
data/protection bits 打包成 DUT RAM 字宽、调用层次宏，并实现需要的 read backend。
索引、保护模式选择和完成状态仍由 VCS table runtime 管理。

启动顺序如下：

```bash
TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 make run-qemu
```

```bash
./simv \
  +COSIM \
  +REMOTE_HOST=<QEMU-host> \
  +PORT_BASE=9100 \
  +COSIM_TABLE_ENABLE=1 \
  +COSIM_TABLE_MAP=/absolute/routes.ini \
  +TABLE_PORT_BASE=10100 \
  +COSIM_TABLE_LOG=high \
  +COSIM_TABLE_PROTECT_vio_notify=none
```

```bash
insmod dpu_snd1.ko
insmod dpu_snd1.ko table_backdoor=1 table_frontdoor_flush_interval=100
insmod dpu_snd1.ko table_frontdoor_flush_interval=0
```

`table_frontdoor_flush_interval` 是只读模块参数，默认值为 100；因此第一条命令虽然
没有显式参数，仍默认开启每 100 次写一次的节流。计数只覆盖
`wr32_for_each`/`wr32_for_high_order` 进入 frontdoor fallback 后实际执行的 4-byte
MMIO 写。默认配置在第 100 次写之后（以后每 100 次）立即对刚写的 DWORD 地址执行
`readl`，丢弃返回值；它用于 posted-write pacing，不是数据校验。设为 0 会恢复原始
无节流循环。backdoor 成功和 hard error 都在 fallback 循环前返回，不会计数；每个
`dpu_hw` 分别维护独立计数器。

也可用 kernel cmdline 显式选择：

```text
dpu_snd1.table_frontdoor_flush_interval=100
dpu_snd1.table_frontdoor_flush_interval=0
```

`+COSIM_TABLE_ENABLE=1` 才启用表通道，且要求精确的 `+COSIM`；route map 必须
是 VCS 主机上的绝对可读路径。`+COSIM_TABLE_PROTECT_vio_notify=...` 只改变名为
`vio_notify` 的 handler 的运行时保护打包，不会启用表功能，也不会开放读取。

示例 route map 使用 PF0 的逻辑 BAR0/BAR1。省略 `operations` 等价于
`operations=write`；只有显式写成 `operations=write,read` 的 route 才允许一次
对齐的 4-byte read callback。Guest 仍按完整 buffer 提交，entry 按原顺序提交，
handler 返回成功后才计为 committed。`NOT_READY`/`NO_ROUTE`/`UNSUPPORTED` 和本地
slot busy 可安全回到原 MMIO 路径；执行错误、超时、目标消失、协议错误和任何
部分完成都是 hard error，绝不能通过 frontdoor 重放。
