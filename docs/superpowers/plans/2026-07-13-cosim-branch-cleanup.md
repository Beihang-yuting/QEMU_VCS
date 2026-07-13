# CoSim 分支精简为最小 kit — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `feature/qemu-vcs-isolated-tcp` 精简成最小 cosim 集成 kit,脚本收敛到 setup.sh + Makefile,删除老 stub 流/自测顶层/冗余脚本。

**Architecture:** 纯删除 + 少量编辑。kit 核心 = `bridge/` + `cosim_xrc_driver.sv` + `cosim_xrc_pkg.sv`。构建收进 Makefile(bridge/.so、qemu-device/ninja、cosim-lib/.a、run-qemu/N QEMU+描述符),setup.sh 剪掉 VCS 侧。

**Tech Stack:** SystemVerilog(UVM)、C(DPI 桥)、GNU Make、bash、QEMU/ninja/cmake。

**参考 spec:** `docs/superpowers/specs/2026-07-13-cosim-branch-cleanup-design.md`

**通用约定:** 全程在 `software/cosim-platform/` 下操作。每个 delete/edit 后跑
`grep -rn '<被删符号>' Makefile setup.sh vcs-tb bridge docs --include=*.sv --include=*.sh --include=*.md --include=Makefile`
确认无残留引用,再 commit。

---

### Task 1: 删除老 stub SV 流 + uvm-tb

**Files:**
- Delete: `vcs-tb/cosim_rc_driver.sv` `vcs-tb/cosim_test.sv` `vcs-tb/cosim_vip_top.sv` `vcs-tb/glue_if_to_stub.sv` `vcs-tb/pcie_ep_stub.sv` `vcs-tb/cosim_stub_cpl_if.sv` `vcs-tb/cosim_perf_monitor.sv` `vcs-tb/cosim_pkg.sv` `vcs-tb/tb_top.sv` `vcs-tb/tests/`
- Delete: `uvm-tb/`(整个目录)

- [ ] **Step 1: 删除文件**
```bash
cd software/cosim-platform
git rm vcs-tb/cosim_rc_driver.sv vcs-tb/cosim_test.sv vcs-tb/cosim_vip_top.sv \
       vcs-tb/glue_if_to_stub.sv vcs-tb/pcie_ep_stub.sv vcs-tb/cosim_stub_cpl_if.sv \
       vcs-tb/cosim_perf_monitor.sv vcs-tb/cosim_pkg.sv vcs-tb/tb_top.sv
git rm -r vcs-tb/tests uvm-tb
```

- [ ] **Step 2: 确认 kit 保留件不引用被删件**
Run:
```bash
grep -rnE "cosim_rc_driver|glue_if_to_stub|pcie_ep_stub|cosim_stub_cpl_if|cosim_perf_monitor|\bcosim_test\b|cosim_vip_top|tb_top\.sv" \
     vcs-tb/cosim_xrc_driver.sv vcs-tb/cosim_xrc_pkg.sv bridge/vcs/bridge_vcs.sv
```
Expected: 无输出(kit 三件不引用老 stub)。

- [ ] **Step 3: Commit**
```bash
git commit -m "chore(cosim): 删除老单RC stub 流 + uvm-tb"
```

---

### Task 2: cosim_xrc_pkg.sv 去掉 test/env_config include

**Files:**
- Modify: `vcs-tb/cosim_xrc_pkg.sv`

- [ ] **Step 1: 编辑 pkg —— 只留 driver include**
把 include 段改成(删掉 cosim_env_config + cosim_xrc_test 两行):
```systemverilog
    `include "cosim_xrc_driver.sv"    // cosim_xrc_driver extends pcie_tl_rc_driver
```
(保留其上的 `import` 段与其下的 `cosim_maybe_enable()` 函数不动。)

- [ ] **Step 2: 确认 pkg 不再引用 env_config/test**
Run: `grep -nE "cosim_env_config|cosim_xrc_test" vcs-tb/cosim_xrc_pkg.sv`
Expected: 无输出。

- [ ] **Step 3: Commit**
```bash
git add vcs-tb/cosim_xrc_pkg.sv
git commit -m "refactor(cosim): cosim_xrc_pkg 只留 driver + cosim_maybe_enable"
```

---

### Task 3: 删自测顶层 SV(依赖 Task 2 先做)

**Files:**
- Delete: `vcs-tb/cosim_xrc_test.sv` `vcs-tb/tb_cosim_multirc_top.sv` `vcs-tb/cosim_env_config.sv`

- [ ] **Step 1: 删除**
```bash
git rm vcs-tb/cosim_xrc_test.sv vcs-tb/tb_cosim_multirc_top.sv vcs-tb/cosim_env_config.sv
```

- [ ] **Step 2: 确认无残留引用**
Run: `grep -rnE "cosim_xrc_test|tb_cosim_multirc_top|cosim_env_config" vcs-tb Makefile scripts`
Expected: 无输出。

- [ ] **Step 3: 确认 vcs-tb 只剩 kit 两件**
Run: `ls vcs-tb`
Expected: `cosim_xrc_driver.sv  cosim_xrc_pkg.sv`

- [ ] **Step 4: Commit**
```bash
git commit -m "chore(cosim): 删自测顶层(cosim_xrc_test/tb_cosim_multirc_top/env_config)"
```

---

### Task 4: 删冗余脚本 + 老 py 工具

**Files:**
- Delete: `scripts/run_cosim.sh` `scripts/run_dual_vcs.sh` `scripts/run_tap_test.sh` `scripts/run_tcp_iperf_test.sh` `scripts/run_e2e_virtio.sh` `scripts/run_phase5_test.sh` `scripts/rebuild_vcs.sh` `scripts/build_cosim_multirc.sh` `scripts/run_cosim_vcs.sh` `scripts/cosim_cli.py` `scripts/gen_usage_doc.py` `scripts/launch_dual.py` `scripts/trace_analyzer.py`

> 注:`setup_qemu_env.sh` / `rebuild_qemu.sh` / `build_cosim_lib.sh` / `setup_cosim_qemu.sh`
> 留到 Task 9 删(等 Makefile 吸收其逻辑后)。

- [ ] **Step 1: 删除**
```bash
git rm scripts/run_cosim.sh scripts/run_dual_vcs.sh scripts/run_tap_test.sh \
       scripts/run_tcp_iperf_test.sh scripts/run_e2e_virtio.sh scripts/run_phase5_test.sh \
       scripts/rebuild_vcs.sh scripts/build_cosim_multirc.sh scripts/run_cosim_vcs.sh \
       scripts/cosim_cli.py scripts/gen_usage_doc.py scripts/launch_dual.py scripts/trace_analyzer.py
```

- [ ] **Step 2: 确认 setup.sh / Makefile / 保留脚本不引用被删脚本**
Run:
```bash
grep -rnE "run_cosim\.sh|run_dual_vcs|run_tap_test|run_tcp_iperf|run_e2e_virtio|run_phase5|rebuild_vcs|build_cosim_multirc|run_cosim_vcs|cosim_cli|gen_usage_doc|launch_dual|trace_analyzer" \
     setup.sh Makefile scripts docs
```
Expected: 仅 docs 里可能有引用(Task 11 处理);setup.sh/Makefile/scripts 无。若 setup.sh 有,记下留 Task 10 一并清。

- [ ] **Step 3: Commit**
```bash
git commit -m "chore(cosim): 删冗余运行脚本 + 老 py 工具"
```

---

### Task 5: Makefile 剪掉 VCS 目标

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: 删 VCS 编译/运行目标**
删除这些整段 target 及其专用变量:`vcs-vip`、`vcs-legacy`、`vcs-vip-perf`、`run-vcs`、`run-dual`、`run-tap`、`tap-check`、`tap-bridge`。
同时删只被它们用的变量:`VCS_FLAGS` `VCS_UVM` `VIP_SRC` `HOST_MEM_SRC` `VCS_CFLAGS`(注:`BRIDGE_C_SRCS`
留给 Task 6 的 cosim-lib 用)、`SIMV` `_VCS_TRANS` `_VCS_ARGS` `ETH_*` `MAC_LAST` `VCS_TEST`
`NUM_PFS/MAX_VFS/MSIX_VECTORS/VF_MSIX_VECS/TAG_WIDTH` `TAP_*` `SIM_TIMEOUT` `ROLE` `WAIT_SEC`。

- [ ] **Step 2: 更新 .PHONY**
把第 8-11 行 `.PHONY` 改为(去掉已删 target,加新 target):
```makefile
.PHONY: all help bridge cosim-lib qemu-device run-qemu \
        test-unit test-integration test \
        clean clean-logs clean-run clean-all info
```

- [ ] **Step 3: 确认无语法错**
Run: `make -n info 2>&1 | head` (或 `make -n bridge`)
Expected: 无 "missing separator" / "undefined" 类错误(引用已删变量会报错 → 补删)。

- [ ] **Step 4: Commit**
```bash
git add Makefile
git commit -m "chore(makefile): 剪掉 VCS/TAP 目标(stub 已删)"
```

---

### Task 6: Makefile 加 cosim-lib 目标(吸收 build_cosim_lib.sh)

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: 加 cosim-lib target**
在 `bridge:` target 之后加入(PCIe MMIO 通路 C 源,含 eth_shm 以满足 transport_shm 依赖):
```makefile
# ----- kit 静态库 libcosim_bridge.a(供外部 VCS flow 链接)-----
LIB_DIR    = $(BUILD_DIR)/lib
LIB_CC    ?= gcc
LIB_CFLAGS = -std=gnu11 -D_DEFAULT_SOURCE -O2 -fPIC -Wall
LIB_INCS   = -I $(CURDIR)/bridge/common -I $(CURDIR)/bridge/vcs -I $(CURDIR)/bridge/qemu -I $(CURDIR)/bridge/eth
LIB_SRCS   = bridge/vcs/bridge_vcs.c bridge/vcs/sock_sync_vcs.c \
             bridge/common/shm_layout.c bridge/common/ring_buffer.c \
             bridge/common/dma_manager.c bridge/common/trace_log.c \
             bridge/common/transport_shm.c bridge/common/transport_tcp.c \
             bridge/common/eth_shm.c

cosim-lib:
	@mkdir -p $(LIB_DIR)
	@for f in $(LIB_SRCS); do \
		echo "  CC  $$f"; \
		$(LIB_CC) $(LIB_CFLAGS) $(LIB_INCS) -c $$f -o $(LIB_DIR)/$$(basename $${f%.c}).o || exit 1; \
	done
	@ar rcs $(LIB_DIR)/libcosim_bridge.a $(LIB_DIR)/*.o
	@echo "[BUILD] $(LIB_DIR)/libcosim_bridge.a"
	@ar t $(LIB_DIR)/libcosim_bridge.a | sed 's/^/  - /'
```

- [ ] **Step 2: 校验**
Run: `make cosim-lib && nm build/lib/libcosim_bridge.a | grep -c bridge_vcs_poll_tlp_scalar_rc`
Expected: `libcosim_bridge.a` 生成,grep 计数 ≥1(_rc 符号在)。

- [ ] **Step 3: Commit**
```bash
git add Makefile
git commit -m "feat(makefile): cosim-lib 目标建 libcosim_bridge.a"
```

---

### Task 7: Makefile 加 qemu-device 目标(吸收 rebuild_qemu.sh device)

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: 加 qemu-device target**
```makefile
# ----- QEMU 设备模型重编(改 qemu-plugin/cosim_pcie_*.c 后)-----
QEMU_SRC_DIR = $(PROJECT_DIR)/third_party/qemu
QEMU_BUILD   = $(QEMU_SRC_DIR)/build

qemu-device:
	@[ -f "$(QEMU_BUILD)/build.ninja" ] || { echo "[错误] 无 qemu build: $(QEMU_BUILD)（先 ./setup.sh 建 QEMU）"; exit 1; }
	@touch $(QEMU_SRC_DIR)/hw/net/cosim_pcie_rc.c \
	       $(QEMU_SRC_DIR)/hw/net/cosim_pcie_pf.c \
	       $(QEMU_SRC_DIR)/hw/net/cosim_pcie_vf.c 2>/dev/null || true
	ninja -C $(QEMU_BUILD) qemu-system-x86_64
	@echo "[BUILD] $(QEMU_BUILD)/qemu-system-x86_64"
```

> 说明:改 `bridge/qemu/*.c`、`bridge/common/*.c` 用 `make bridge`(建 .so);
> 改 `qemu-plugin/cosim_pcie_*.c` 用 `make qemu-device`。两者互补(见 spec)。

- [ ] **Step 2: 校验(仅语法,不实际编)**
Run: `make -n qemu-device`
Expected: 打印 touch + ninja 命令,无 make 语法错。

- [ ] **Step 3: Commit**
```bash
git add Makefile
git commit -m "feat(makefile): qemu-device 目标 ninja 重编设备模型"
```

---

### Task 8: Makefile run-qemu 改为 N 实例 + 吐 cosim-conn.json(吸收 setup_qemu_env.sh)

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: 加参数变量**
在参数区加:
```makefile
NUM_RC         ?= 1
ADVERTISE_HOST ?= $(shell hostname -I 2>/dev/null | awk '{print $$1}')
CONN_JSON      ?= $(RUN_DIR)/cosim-conn.json
DEV_VENDOR     ?= 0x1af4
DEV_DEVICE     ?= 0x1041
DEV_BAR0_SIZE  ?= 0x10000
```

- [ ] **Step 2: 用下面的 run-qemu 整段替换旧 run-qemu target**
(起 NUM_RC 个 QEMU:transport=tcp,同 PORT_BASE,instance_id=r,端口=PORT_BASE+r*3;写描述符;前台守着 Ctrl-C 全清)
```makefile
run-qemu:
	@[ -f '$(QEMU)' ] || { echo "[错误] QEMU 未找到: $(QEMU)（先 ./setup.sh 建 QEMU）"; exit 1; }
	@[ -n '$(KERNEL)' ] && [ -f '$(KERNEL)' ] || { echo "[错误] Kernel 未找到 (GUEST_TYPE=$(GUEST_TYPE))"; exit 1; }
	@[ -n '$(ROOTFS)' ] && [ -f '$(ROOTFS)' ] || echo "[警告] 未找到 rootfs (GUEST_TYPE=$(GUEST_TYPE))"
	@mkdir -p $(LOG_DIR) $(RUN_DIR)
	@echo "[cosim] 起 $(NUM_RC) 个 QEMU(tcp, port_base=$(PORT_BASE), inst 0..$$(($(NUM_RC)-1)))"
	@PIDS=""; \
	cleanup() { echo; echo "[cosim] 停 QEMU..."; for p in $$PIDS; do kill $$p 2>/dev/null || true; done; wait 2>/dev/null || true; }; \
	trap cleanup INT TERM EXIT; \
	for r in $$(seq 0 $$(($(NUM_RC)-1))); do \
		$(_QEMU_LD_PATH) $(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 -snapshot \
			-kernel $(KERNEL) -drive file=$(ROOTFS),format=raw,if=none,id=rootdisk$$r \
			-device virtio-blk-pci,drive=rootdisk$$r,addr=0x10 \
			-append "console=ttyS0 root=/dev/vda rw guest_ip=10.0.0.$$((10+r))" \
			-device "cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=$$r" \
			-nographic -serial file:$(LOG_DIR)/qemu_rc$$r.log -monitor none \
			> $(LOG_DIR)/qemu_rc$$r.boot 2>&1 & \
		PIDS="$$PIDS $$!"; \
		echo "  RC$$r: port $$(($(PORT_BASE)+r*3))  log $(LOG_DIR)/qemu_rc$$r.log"; \
	done; \
	{ echo "{"; \
	  echo "  \"transport\": \"tcp\","; \
	  echo "  \"host\": \"$(ADVERTISE_HOST)\","; \
	  echo "  \"port_base\": $(PORT_BASE),"; \
	  echo "  \"num_rc\": $(NUM_RC),"; \
	  echo "  \"port_formula\": \"port = port_base + instance_id*3\","; \
	  printf "  \"rcs\": ["; \
	  for r in $$(seq 0 $$(($(NUM_RC)-1))); do [ $$r -gt 0 ] && printf ","; printf " {\"rc\": %d, \"instance_id\": %d, \"port\": %d}" $$r $$r $$(($(PORT_BASE)+r*3)); done; \
	  echo " ],"; \
	  echo "  \"device\": { \"vendor\": \"$(DEV_VENDOR)\", \"device\": \"$(DEV_DEVICE)\", \"bar0_size\": \"$(DEV_BAR0_SIZE)\" }"; \
	  echo "}"; } > $(CONN_JSON); \
	echo "[cosim] 描述符: $(CONN_JSON)"; cat $(CONN_JSON); \
	echo "[cosim] VCS 侧读它连过来;Ctrl-C 停。"; \
	wait
```

- [ ] **Step 3: 校验(语法 + dry-run)**
Run: `make -n run-qemu | head -5`
Expected: 无 make 语法错。
(真跑需 QEMU/镜像,留 Task 12 端到端。)

- [ ] **Step 4: Commit**
```bash
git add Makefile
git commit -m "feat(makefile): run-qemu 起 N QEMU + 吐 cosim-conn.json(吸收 setup_qemu_env)"
```

---

### Task 9: 删已被 Makefile 吸收的脚本

**Files:**
- Delete: `scripts/setup_qemu_env.sh` `scripts/rebuild_qemu.sh` `scripts/build_cosim_lib.sh` `scripts/setup_cosim_qemu.sh`

- [ ] **Step 1: 删除**
```bash
git rm scripts/setup_qemu_env.sh scripts/rebuild_qemu.sh scripts/build_cosim_lib.sh scripts/setup_cosim_qemu.sh
```

- [ ] **Step 2: 确认无残留引用**
Run: `grep -rnE "setup_qemu_env|rebuild_qemu\.sh|build_cosim_lib|setup_cosim_qemu" Makefile setup.sh scripts docs`
Expected: 仅 docs(Task 11 处理);Makefile/setup.sh/scripts 无。

- [ ] **Step 3: Commit**
```bash
git commit -m "chore(cosim): 删被 Makefile 吸收的脚本(setup_qemu_env/rebuild_qemu/build_cosim_lib/setup_cosim_qemu)"
```

---

### Task 10: setup.sh 剪掉 VCS 侧

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: 移除 vcs-only 模式 + NEED_VCS**
- 用法/菜单去掉 `vcs-only` 选项(usage 文本、interactive_menu 的 `3) vcs-only`、参数验证 `case` 里的 `vcs-only`)。
- 参数验证:`case "$SETUP_MODE" in local|qemu-only|vcs-only)` → `local|qemu-only)`;报错提示同步去掉 vcs-only。
- `NEED_VCS=false`(约 495 行)及所有 `[ "$NEED_VCS" = true ]` 分支/步骤删除(它建的是已删 stub simv)。
- 摘要行(约 532)去掉 `+ VCS` 拼接。
- 若 setup.sh 有引用已删脚本(见 Task 4 Step 2 记录),一并删对应行。

- [ ] **Step 2: 校验语法 + 无 VCS 残留**
Run:
```bash
bash -n setup.sh && echo "setup.sh syntax OK"
grep -nE "vcs-only|NEED_VCS|simv_vip|make vcs" setup.sh
```
Expected: syntax OK;grep 无输出(或仅注释)。

- [ ] **Step 3: Commit**
```bash
git add setup.sh
git commit -m "chore(setup): 剪掉 vcs-only 模式 + VCS 构建步骤(stub 已删)"
```

---

### Task 11: docs 更新引用

**Files:**
- Modify: `docs/COSIM-MINIMAL-INTEGRATION.md` `docs/COSIM-VCS-INTEGRATION.md` `docs/COSIM-ISOLATED-ENVS.md` `docs/COSIM-C-BUILD.md`

- [ ] **Step 1: COSIM-C-BUILD.md —— .a 改为 make cosim-lib**
把 `方式 A — 静态库` 里的 `./scripts/build_cosim_lib.sh` 命令替换为 `make cosim-lib`
(产物 `build/lib/libcosim_bridge.a`);保留手敲 gcc/ar 与 inline 方式说明。

- [ ] **Step 2: COSIM-ISOLATED-ENVS.md —— 启动改 make run-qemu + 内联描述符解析 recipe**
- QEMU 侧启动命令 `./scripts/setup_qemu_env.sh up` → `make run-qemu NUM_RC=2 PORT_BASE=9100 ADVERTISE_HOST=<ip>`。
- 删掉 `run_cosim_vcs.sh` 段;替换为「VCS 侧读 cosim-conn.json → plusargs」的参考 recipe:
```bash
# VCS 侧:解析描述符 → 传给你的 simv(或你 env 的 run 脚本)
HOST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["host"])' cosim-conn.json)
PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["port_base"])' cosim-conn.json)
NRC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["num_rc"])' cosim-conn.json)
./your_simv +COSIM +REMOTE_HOST=$HOST +PORT_BASE=$PORT +NUM_RC=$NRC +BYPASS_CONFIG=1
```

- [ ] **Step 3: COSIM-VCS-INTEGRATION.md —— 去掉自测顶层示例**
把引用 `cosim_xrc_test` / `tb_cosim_multirc_top` / `build_cosim_multirc.sh` 的示例段,改为
「在你自己的 test build_phase 调 `cosim_xrc_pkg::cosim_maybe_enable()` + 你自己的 top」。
指向 `COSIM-MINIMAL-INTEGRATION.md` 作为主入口。

- [ ] **Step 4: COSIM-MINIMAL-INTEGRATION.md —— 校订依赖**
确认「加文件」段只列 `bridge/vcs/bridge_vcs.sv` + `vcs-tb/cosim_xrc_pkg.sv`;
C 库改为 `make cosim-lib`(或 inline)。删除任何指向已删 test/top/脚本的行。

- [ ] **Step 5: 确认文档无已删项引用**
Run:
```bash
grep -rnE "cosim_xrc_test|tb_cosim_multirc_top|cosim_env_config|build_cosim_multirc|run_cosim_vcs|setup_qemu_env|rebuild_qemu|build_cosim_lib|setup_cosim_qemu" docs/*.md
```
Expected: 无输出。

- [ ] **Step 6: Commit**
```bash
git add docs/*.md
git commit -m "docs(cosim): 更新引用到精简后入口(make targets + kit)"
```

---

### Task 12: 终验(不破坏保留能力)

**Files:** 无(只验证)

- [ ] **Step 1: 全局残留引用扫描**
Run:
```bash
grep -rnE "cosim_rc_driver|glue_if_to_stub|pcie_ep_stub|cosim_perf_monitor|cosim_xrc_test|tb_cosim_multirc_top|cosim_env_config|vcs-vip|run-vcs|run-dual|run_cosim_vcs|build_cosim_multirc|setup_qemu_env|rebuild_qemu\.sh|build_cosim_lib" \
     Makefile setup.sh vcs-tb bridge scripts docs
```
Expected: 无输出(全清)。

- [ ] **Step 2: 编译能力仍在**
Run:
```bash
make bridge && ls build/bridge/libcosim_bridge.so
make cosim-lib && ls build/lib/libcosim_bridge.a
make -n qemu-device && make -n run-qemu
```
Expected: .so + .a 生成;qemu-device/run-qemu dry-run 无语法错。

- [ ] **Step 3: kit 编译冒烟(在有 VCS 的机器,如 61)**
把 `bridge/` + `vcs-tb/cosim_xrc_pkg.sv` + 三库编进一个临时 top(或使用者 env),
确认 `cosim_xrc_pkg` 编译通过、`cosim_maybe_enable` 可调。
> 若本机无 VCS,记为「待 61 验证」,不阻塞。

- [ ] **Step 4:(可选)端到端复现**
在 QEMU 机 `make run-qemu NUM_RC=1`;VCS 机用使用者 env `+COSIM +REMOTE_HOST=<qemu> +PORT_BASE=9100`,
确认 guest 枚举出 `[1af4:1041]`(复现本轮 smoke)。

- [ ] **Step 5: Commit(如有终验产生的小修)**
```bash
git commit -am "chore(cosim): 精简终验 + 收尾" || echo "无改动"
```

---

## 自查

- **spec 覆盖:** KEEP/DELETE/EDIT 各项均有对应 task(Task1-3 删SV+改pkg;Task4/9 删脚本;
  Task5-8 Makefile;Task10 setup.sh;Task11 docs)。✓
- **占位:** 无 TBD/TODO;每步给了确切命令/代码。✓
- **一致性:** cosim-lib 用 `LIB_SRCS`(含 eth_shm)与 spec「.a 必带 eth_shm」一致;
  run-qemu 端口 `PORT_BASE+r*3` 与 QEMU `instance_id*3` 一致;pkg 删 include 与 Task3 删文件顺序一致(先改 pkg 再删 env_config)。✓
