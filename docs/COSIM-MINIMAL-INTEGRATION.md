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
> `cosim_xrc_pkg.sv` 已 `include cosim_env_config/cosim_xrc_driver/cosim_xrc_test`。
> +incdir 加 `<cosim>/bridge/vcs` 与 `<cosim>/vcs-tb`。顺序:在 pcie_tl_pkg +
> xilinx_pcie_adapter_pkg **之后**编。

### 2. C 库(二选一,见 [COSIM-C-BUILD.md](COSIM-C-BUILD.md))

```bash
# 方式 A:静态库
./scripts/build_cosim_lib.sh
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
QEMU 侧先起(见 [COSIM-ISOLATED-ENVS.md](COSIM-ISOLATED-ENVS.md) 的 `setup_qemu_env.sh`)。
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
  (或用 `run_cosim_vcs.sh` 从 cosim-conn.json 自动带)。
