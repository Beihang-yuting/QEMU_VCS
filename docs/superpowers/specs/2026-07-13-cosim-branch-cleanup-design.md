# CoSim 分支精简为「最小集成 kit」— 设计

**分支:** `feature/qemu-vcs-isolated-tcp`
**日期:** 2026-07-13
**目标:** 把分支精简成最小 cosim 集成 kit + 保留 QEMU 构建/setup 能力,脚本收敛到
**一个 setup 流程脚本(setup.sh)+ 一个 Makefile(全部编译 + 重编 + 起 QEMU)**。只做减法,
不改 cosim 核心功能。cosim 只在使用者自己的 pcie-tl-vip + xilinx-pcie 环境里经 `+COSIM` 接入。

---

## 目标端态

- **kit 核心(SV+C)**:使用者 `import` 得到的最小件。
- **一个 setup 脚本** = `setup.sh`(建 Bridge+QEMU+Guest,含依赖/菜单/离线打包)。
- **一个 Makefile** = 所有编译 + 文件变更重编 QEMU + 起 QEMU(含吐 cosim-conn.json)。
- 不留:独立自测顶层 / 老单RC stub 流 / 老 VCS 运行脚本 / 冗余启动脚本 / 老 py 工具。

**非目标:** 不动 cosim 核心逻辑;不重构 bridge;MSI-X 等在 `feature/multi-function-sriov` 继续。

---

## KEEP

**SV(kit 核心):**
```
bridge/                          # 全部 C 桥 + bridge_vcs.sv(DPI 声明)
vcs-tb/cosim_xrc_driver.sv       # 转接层
vcs-tb/cosim_xrc_pkg.sv          # 改:只 include driver + cosim_maybe_enable(见 EDIT)
```

**setup 流程(一个入口 + 其内部积木):**
```
setup.sh                         # 唯一 setup 入口(建 Bridge+QEMU+Guest);剪 vcs-only/NEED_VCS
scripts/build_rootfs_debian.sh   # setup.sh 调用(建 guest)
scripts/build_rootfs_alpine.sh   # setup.sh 备选 guest
scripts/build_guest_tools.sh     # setup.sh 调用
scripts/build_cosim_nic.sh       # guest cosim_nic.ko
scripts/setup-ubuntu-kernel.sh   # setup.sh 调用
scripts/inject-modules.sh        # setup.sh 调用
scripts/rebuild_lts_initramfs.sh # guest initramfs
scripts/prepare-offline.sh       # setup.sh --prepare-offline 调用
config.env
```

**编译(一个 Makefile):** `Makefile`(见 EDIT — 收全部编译 + run-qemu)

**docs:** 全保留,按 EDIT 更新引用。

---

## DELETE

**vcs-tb/ 老 stub 流 + 自测顶层 + 仅测试用:**
```
cosim_rc_driver.sv  cosim_test.sv  cosim_vip_top.sv  glue_if_to_stub.sv
pcie_ep_stub.sv  cosim_stub_cpl_if.sv  cosim_perf_monitor.sv  cosim_pkg.sv
tb_top.sv  vcs-tb/tests/
cosim_xrc_test.sv  tb_cosim_multirc_top.sv  cosim_env_config.sv
```

**整个 `uvm-tb/`**

**scripts 冗余(启动/重复/老工具):**
```
setup_qemu_env.sh          # 起QEMU+描述符 → 并进 Makefile run-qemu
rebuild_qemu.sh            # 重编 → 并进 Makefile
build_cosim_lib.sh         # .a → 并进 Makefile(cosim-lib target)
setup_cosim_qemu.sh        # 建QEMU,与 setup.sh 重复
build_cosim_multirc.sh  run_cosim_vcs.sh   # 自测/运行(纯 kit 不留)
run_cosim.sh  run_dual_vcs.sh  run_tap_test.sh  run_tcp_iperf_test.sh
run_e2e_virtio.sh  run_phase5_test.sh  rebuild_vcs.sh
cosim_cli.py  gen_usage_doc.py  launch_dual.py  trace_analyzer.py   # 老 py 工具
```

---

## EDIT

### 1. `vcs-tb/cosim_xrc_pkg.sv`
去掉 `include "cosim_env_config.sv"` 与 `include "cosim_xrc_test.sv"`,只留
`include "cosim_xrc_driver.sv"` + `cosim_maybe_enable()`。kit 的唯一 import 入口。

### 2. `Makefile`(收全部编译 + 起 QEMU)
**新增/保留 target:**
- `bridge` — `make bridge` 建 `build/bridge/libcosim_bridge.so`(已有)。
- `qemu-device` — ninja 重编 QEMU 设备模型(qemu-plugin/cosim_pcie_*.c 改动后),
  等价 `touch hw/net/cosim_pcie_*.c && ninja -C third_party/qemu/build qemu-system-x86_64`。
- `cosim-lib` — 建 `libcosim_bridge.a`(吞掉 build_cosim_lib.sh 的逻辑)。
- `run-qemu` — **起 N 个 QEMU(per-RC instance_id,transport=tcp,同 port_base)+ 写
  cosim-conn.json**(吞掉 setup_qemu_env.sh 的 up/descriptor)。参数 `NUM_RC`/`PORT_BASE`/
  `ADVERTISE_HOST`/`DEV_*`。只起 QEMU(不再起 stub simv)。

**剪掉:** `vcs-vip` / `vcs-legacy` / `vcs-vip-perf` / `run-vcs` 及其 VCS 变量。
`run-dual`(起 2 QEMU + 2 stub simv)**删除,由 `run-qemu NUM_RC=2` 取代**(只起多 QEMU)。

### 3. `setup.sh`
剪掉 `vcs-only` 模式分支 + `NEED_VCS` 相关步骤(它建的是已删的 stub simv)。
保留 local/qemu-only 模式 + QEMU/guest/bridge 构建 + 离线打包 + 菜单。

### 4. docs 更新引用(不丢知识)
- `COSIM-MINIMAL-INTEGRATION.md` — 主入口;确认只依赖保留件(bridge_vcs.sv + cosim_xrc_pkg.sv + `make cosim-lib`)。
- `COSIM-VCS-INTEGRATION.md` — 去掉 cosim_xrc_test/tb_cosim_multirc_top 示例,指向使用者自己的 test/top。
- `COSIM-ISOLATED-ENVS.md` — 启动改为 `make run-qemu`;`run_cosim_vcs.sh` 删,其
  **cosim-conn.json → plusargs 解析 recipe** 内联进文档,作为使用者 env 里的实现参考。
- `COSIM-C-BUILD.md` — .a 改为 `make cosim-lib`(仍保留手敲 gcc/inline 说明)。

---

## 验证(删后不破坏保留能力)

- `make bridge` / `make qemu-device` / `make cosim-lib` / `make run-qemu` 均工作。
- `setup.sh --mode local` / `--mode qemu-only` 能建 QEMU+guest+bridge(vcs-only 已移除)。
- `grep -rn` 确认无保留件引用已删件(Makefile / setup.sh / SV / docs / 保留脚本)。
- kit 冒烟:`cosim_xrc_pkg` 编译通过、`cosim_maybe_enable` 可调(在使用者 env 或临时 harness)。
- QEMU-side 端到端仍可跑(`make run-qemu` 起 QEMU,使用者 env +COSIM 连)—— 复现本轮 smoke。

---

## 回滚

改动全在 `feature/qemu-vcs-isolated-tcp`、独立 commit;删除文件在 git 历史与
`feature/multi-function-sriov` 分支仍在。
