# ============================================================
# CoSim Platform Makefile
# 统一编译 + 运行 + 测试入口
# 用法: make help
# ============================================================
SHELL := /bin/bash

.PHONY: all help bridge cosim-lib cosim-lib-eth qemu-device run-qemu \
        test-unit test-integration test \
        clean clean-logs clean-run clean-all info

# ============================================================
# 路径配置（可通过环境变量覆盖）
# ============================================================
PROJECT_DIR   := $(CURDIR)
BUILD_DIR     := $(PROJECT_DIR)/build
BRIDGE_LIB_DIR := $(BUILD_DIR)/bridge
LOG_DIR       := $(PROJECT_DIR)/logs
RUN_DIR       := $(PROJECT_DIR)/run

# 二进制路径（优先环境变量）
QEMU          ?= $(firstword $(wildcard $(PROJECT_DIR)/third_party/qemu/build/qemu-system-x86_64) \
                              $(wildcard $(HOME)/workspace/qemu-9.2.0/build/qemu-system-x86_64))
GUEST_TYPE    ?= ubuntu
# 镜像路径: guest/images/<GUEST_TYPE>/
KERNEL        ?= $(firstword $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/bzImage) \
                              $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/vmlinuz))
ROOTFS        ?= $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/rootfs.ext4)

# ============================================================
# 运行参数（通过 make xxx KEY=VALUE 传入）
# ============================================================
# TCP 模式
PORT_BASE     ?= 9100
ifeq ($(GUEST_TYPE),debian)
  GUEST_MEMORY  ?= 512M
else
  GUEST_MEMORY  ?= 256M
endif
# 多 QEMU 实例 + 连接描述符
NUM_RC         ?= 1
# 控制台模式: login       = 单 RC0 交互控制台(前台, 可登录, 输出同时进日志)
#             login-multi = NUM_RC 个后台 QEMU, 每 RC 一个控制台 socket(可登录)+独立日志
#             file        = 无人值守, NUM_RC 个后台 QEMU, 串口只写日志文件
CONSOLE        ?= login
# MMIO 读超时(ms): >0 时 BAR MMIO 读等 VCS 应答超时即返 0xFFFFFFFF, 设备无响应也能启动到登录;
#                  0=禁用(永久阻塞,旧行为)。默认 180000(3min)。传给 cosim-pcie-rc 设备属性。
MMIO_TIMEOUT_MS ?= 180000
ADVERTISE_HOST ?= $(shell hostname -I 2>/dev/null | awk '{print $$1}')
CONN_JSON      ?= $(RUN_DIR)/cosim-conn.json
DEV_VENDOR     ?= 0x1af4
DEV_DEVICE     ?= 0x1041
DEV_BAR0_SIZE  ?= 0x10000

# ============================================================
# 默认目标
# ============================================================
all: bridge

# ============================================================
# 编译目标
# ============================================================
bridge:
	@echo "[BUILD] 编译 Bridge 库..."
	@cmake -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Debug 2>&1 | tail -3
	@cmake --build $(BUILD_DIR) -j$$(nproc) 2>&1 | tail -5
	@echo "[BUILD] Bridge 库编译完成"

# ----- cosim 外部集成库(给你自己的 UVM/VCS flow 链接)-----
# 产 $(COSIM_LIB_DIR)/libcosim_bridge.{a,so};改了 bridge/*.c 后 `make cosim-lib` 即重编。
# ABI: 想与 VCS gcc 对齐 —— make cosim-lib COSIM_CC=$$VCS_HOME/gnu/linux/gcc-*/bin/gcc
# 用法: -sv_lib $(COSIM_LIB_DIR)/libcosim_bridge (推荐,详见 docs/COSIM-C-BUILD.md)
COSIM_LIB_DIR ?= $(BUILD_DIR)/lib
COSIM_CC      ?= gcc

cosim-lib:
	@echo "[BUILD] 编译 cosim 集成库 (.a + .so, PCIe MMIO) -> $(COSIM_LIB_DIR)"
	@CC=$(COSIM_CC) OUT=$(COSIM_LIB_DIR) ./scripts/build_cosim_lib.sh

cosim-lib-eth:
	@echo "[BUILD] 编译 cosim 集成库 (.a + .so, 含完整 ETH DPI) -> $(COSIM_LIB_DIR)"
	@CC=$(COSIM_CC) OUT=$(COSIM_LIB_DIR) ./scripts/build_cosim_lib.sh --with-eth

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

# host_mem 统一内存模型信息（供 cosim-lib / 外部 VCS flow 参考）
BRIDGE_C_SRCS = \
	bridge/vcs/bridge_vcs.c bridge/vcs/sock_sync_vcs.c \
	bridge/common/shm_layout.c bridge/common/ring_buffer.c \
	bridge/common/dma_manager.c bridge/common/trace_log.c \
	bridge/common/eth_shm.c bridge/common/link_model.c \
	bridge/vcs/virtqueue_dma.c \
	bridge/eth/eth_mac_dpi.c bridge/eth/eth_port.c \
	bridge/common/transport_shm.c bridge/common/transport_tcp.c

# ============================================================
# 运行 — QEMU
# ============================================================
# 运行时库路径（确保源码编译的 glib 等库可被找到）
_QEMU_LD_PATH = LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:$(BRIDGE_LIB_DIR):$${LD_LIBRARY_PATH:-}

run-qemu:
	@[ -f '$(QEMU)' ] || { echo "[错误] QEMU 未找到: $(QEMU)（先 ./setup.sh 建 QEMU）"; exit 1; }
	@[ -n '$(KERNEL)' ] && [ -f '$(KERNEL)' ] || { echo "[错误] Kernel 未找到 (GUEST_TYPE=$(GUEST_TYPE))"; exit 1; }
	@[ -n '$(ROOTFS)' ] && [ -f '$(ROOTFS)' ] || echo "[警告] 未找到 rootfs (GUEST_TYPE=$(GUEST_TYPE))"
	@mkdir -p $(LOG_DIR) $(RUN_DIR)
ifeq ($(CONSOLE),login)
	@echo "[cosim] 登录模式(交互控制台,可登录; 控制台输出同时写日志): RC0 port $(PORT_BASE)"
	@{ echo "{"; \
	  echo "  \"transport\": \"tcp\","; \
	  echo "  \"host\": \"$(ADVERTISE_HOST)\","; \
	  echo "  \"port_base\": $(PORT_BASE),"; \
	  echo "  \"num_rc\": 1,"; \
	  echo "  \"port_formula\": \"port = port_base + instance_id*3\","; \
	  echo "  \"rcs\": [ {\"rc\": 0, \"instance_id\": 0, \"port\": $(PORT_BASE)} ],"; \
	  echo "  \"device\": { \"vendor\": \"$(DEV_VENDOR)\", \"device\": \"$(DEV_DEVICE)\", \"bar0_size\": \"$(DEV_BAR0_SIZE)\" }"; \
	  echo "}"; } > $(CONN_JSON)
	@echo "[cosim] 描述符: $(CONN_JSON)"; cat $(CONN_JSON)
	@echo "[cosim] 本终端即 guest 控制台(可登录); Ctrl-A C 切 QEMU monitor, Ctrl-A X 退出; VCS 读描述符连过来。"
	@$(_QEMU_LD_PATH) $(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 -snapshot \
		-kernel $(KERNEL) -drive file=$(ROOTFS),format=raw,if=none,id=rootdisk0 \
		-device virtio-blk-pci,drive=rootdisk0,addr=0x10 \
		-append "console=ttyS0 root=/dev/vda rw guest_ip=10.0.0.10" \
		-device "cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=0,mmio_timeout_ms=$(MMIO_TIMEOUT_MS)" \
		-display none \
		-chardev stdio,id=cons0,mux=on,signal=off,logfile=$(LOG_DIR)/qemu_rc0.log \
		-serial chardev:cons0 -mon chardev=cons0,mode=readline
else ifeq ($(CONSOLE),login-multi)
	@echo "[cosim] 多控制台登录模式: $(NUM_RC) 个后台 QEMU, 每 RC 一个控制台 socket + 独立日志"
	@PIDS=""; \
	cleanup() { echo; echo "[cosim] 停 QEMU..."; for p in $$PIDS; do kill $$p 2>/dev/null || true; done; wait 2>/dev/null || true; }; \
	trap cleanup INT TERM EXIT; \
	for r in $$(seq 0 $$(($(NUM_RC)-1))); do \
		$(_QEMU_LD_PATH) $(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 -snapshot \
			-kernel $(KERNEL) -drive file=$(ROOTFS),format=raw,if=none,id=rootdisk$$r \
			-device virtio-blk-pci,drive=rootdisk$$r,addr=0x10 \
			-append "console=ttyS0 root=/dev/vda rw guest_ip=10.0.0.$$((10+r))" \
			-device "cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=$$r,mmio_timeout_ms=$(MMIO_TIMEOUT_MS)" \
			-display none \
			-chardev socket,id=cons$$r,path=$(RUN_DIR)/console_rc$$r.sock,server=on,wait=off,logfile=$(LOG_DIR)/qemu_rc$$r.log \
			-serial chardev:cons$$r \
			-monitor unix:$(RUN_DIR)/monitor_rc$$r.sock,server=on,wait=off \
			> $(LOG_DIR)/qemu_rc$$r.boot 2>&1 & \
		PIDS="$$PIDS $$!"; \
		echo "  RC$$r: TCP $$(($(PORT_BASE)+r*3))  控制台 $(RUN_DIR)/console_rc$$r.sock  日志 $(LOG_DIR)/qemu_rc$$r.log"; \
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
	echo "[cosim] 登录各 RC 控制台(每个开一个终端): socat -,raw,echo=0 unix-connect:$(RUN_DIR)/console_rc<N>.sock"; \
	echo "[cosim] QEMU monitor: socat -,raw,echo=0 unix-connect:$(RUN_DIR)/monitor_rc<N>.sock ; Ctrl-C 停全部。"; \
	wait
else
	@echo "[cosim] 起 $(NUM_RC) 个 QEMU(tcp, port_base=$(PORT_BASE), inst 0..$$(($(NUM_RC)-1)))"
	@PIDS=""; \
	cleanup() { echo; echo "[cosim] 停 QEMU..."; for p in $$PIDS; do kill $$p 2>/dev/null || true; done; wait 2>/dev/null || true; }; \
	trap cleanup INT TERM EXIT; \
	for r in $$(seq 0 $$(($(NUM_RC)-1))); do \
		$(_QEMU_LD_PATH) $(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 -snapshot \
			-kernel $(KERNEL) -drive file=$(ROOTFS),format=raw,if=none,id=rootdisk$$r \
			-device virtio-blk-pci,drive=rootdisk$$r,addr=0x10 \
			-append "console=ttyS0 root=/dev/vda rw guest_ip=10.0.0.$$((10+r))" \
			-device "cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=$$r,mmio_timeout_ms=$(MMIO_TIMEOUT_MS)" \
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
endif

# ============================================================
# 测试
# ============================================================
test-unit: bridge
	cd $(BUILD_DIR) && ctest --test-dir tests/unit --output-on-failure -V

test-integration: bridge
	cd $(BUILD_DIR) && ctest --test-dir tests/integration --output-on-failure -V

test: test-unit test-integration

# ============================================================
# 清理
# ============================================================
clean:
	rm -rf $(BUILD_DIR)

clean-logs:
	rm -rf $(LOG_DIR)/*

clean-run:
	rm -f $(RUN_DIR)/*.sock
	rm -f /dev/shm/cosim*

clean-all: clean clean-logs clean-run

# ============================================================
# 信息
# ============================================================
info:
	@echo "=== CoSim 环境 ==="
	@echo "  QEMU:   $(QEMU)  $$(test -f '$(QEMU)' && echo [OK] || echo [缺失])"
	@echo "  Kernel: $(KERNEL)  $$(test -f '$(KERNEL)' && echo [OK] || echo [缺失])"
	@echo "  Rootfs: $(if $(ROOTFS),$(ROOTFS)  $$(test -f '$(ROOTFS)' && echo [OK] || echo [缺失]),(未找到))"
	@echo "  日志:   $(LOG_DIR)/"
	@echo "  运行:   $(RUN_DIR)/"

# ============================================================
# 帮助
# ============================================================
help:
	@echo ""
	@echo "CoSim Platform Makefile"
	@echo "======================"
	@echo ""
	@echo "编译:"
	@echo "  make bridge          Bridge 库(.so, cmake)"
	@echo "  make cosim-lib       外部集成库 .a+.so(供外部 VCS flow 链接;-sv_lib 推荐)"
	@echo "  make cosim-lib-eth   同上,含完整 ETH DPI;ABI 对齐加 COSIM_CC=<vcs-gcc>"
	@echo "  make qemu-device     重编 QEMU 设备模型(改 cosim_pcie_*.c 后, ninja)"
	@echo ""
	@echo "运行 QEMU(tcp, 供外部 VCS 连过来) — CONSOLE 三模式:"
	@echo "  make run-qemu                        [默认] login: 单 RC 前台交互控制台(可登录)+同时写日志"
	@echo "  make run-qemu CONSOLE=login-multi NUM_RC=2"
	@echo "                                       多 RC: 每 RC 后台 + 独立控制台/monitor socket(可登录) + 独立日志"
	@echo "                                       登录:  socat -,raw,echo=0 unix-connect:$(RUN_DIR)/console_rc<N>.sock"
	@echo "  make run-qemu CONSOLE=file NUM_RC=4  无人值守: NUM_RC 个后台 QEMU, 串口只写日志文件"
	@echo "  控制台内容同时写 $(LOG_DIR)/qemu_rc<N>.log; 连接描述符写 $(CONN_JSON)"
	@echo "  login 模式登录后: Ctrl-A C 切 QEMU monitor, Ctrl-A X 退出"
	@echo "  设备无响应也能进登录: MMIO 读默认 3min 超时(见下 MMIO_TIMEOUT_MS)"
	@echo ""
	@echo "测试:"
	@echo "  make test-unit        单元测试"
	@echo "  make test-integration 集成测试"
	@echo "  make test             全部"
	@echo ""
	@echo "清理:"
	@echo "  make clean       编译产物"
	@echo "  make clean-logs  日志"
	@echo "  make clean-run   sock/shm"
	@echo "  make clean-all   全部"
	@echo ""
	@echo "参数（KEY=VALUE）:"
	@echo "  NUM_RC=1               QEMU 实例数"
	@echo "  PORT_BASE=9100         TCP 端口基数（端口=BASE+instance_id*3）"
	@echo "  CONSOLE=login|login-multi|file  控制台模式(默认 login)"
	@echo "  MMIO_TIMEOUT_MS=180000  MMIO 读等 VCS 应答超时 ms(默认 3min; 0=禁用,永久阻塞)"
	@echo "  ADVERTISE_HOST         写入描述符的 host（默认本机 IP）"
	@echo "  GUEST_TYPE=ubuntu|debian  Guest 系统（默认 ubuntu）"
	@echo "  QEMU= KERNEL= ROOTFS=  路径覆盖"
	@echo ""
