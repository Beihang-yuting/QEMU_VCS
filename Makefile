# ============================================================
# CoSim Platform Makefile
# 统一编译 + 运行 + 测试入口
# 用法: make help
# ============================================================
SHELL := /bin/bash

.PHONY: all help bridge vcs-vip vcs-legacy vcs-vip-perf tap-bridge \
        run-qemu run-vcs run-dual run-tap tap-check \
        test-unit test-integration test \
        clean clean-logs clean-run clean-all info

# ============================================================
# 路径配置（可通过环境变量覆盖）
# ============================================================
PROJECT_DIR   := $(CURDIR)
BUILD_DIR     := $(PROJECT_DIR)/build
VCS_SIM_DIR   := $(PROJECT_DIR)/vcs_sim
LOG_DIR       := $(PROJECT_DIR)/logs
RUN_DIR       := $(PROJECT_DIR)/run

# 二进制路径（优先环境变量）
QEMU          ?= $(firstword $(wildcard $(PROJECT_DIR)/third_party/qemu/build/qemu-system-x86_64) \
                              $(wildcard $(HOME)/workspace/qemu-9.2.0/build/qemu-system-x86_64))
SIMV          ?= $(VCS_SIM_DIR)/simv_vip
KERNEL        ?= $(firstword $(wildcard $(PROJECT_DIR)/guest/images/bzImage) \
                              $(wildcard $(HOME)/workspace/alpine-vmlinuz-new))
ROOTFS        ?= $(firstword $(wildcard $(PROJECT_DIR)/guest/images/rootfs.ext4) \
                              $(wildcard $(HOME)/workspace/rootfs.ext4))
TAP_BRIDGE    ?= $(PROJECT_DIR)/tools/eth_tap_bridge

# ============================================================
# 运行参数（通过 make xxx KEY=VALUE 传入）
# ============================================================
TRANSPORT     ?= shm
# SHM 模式
SHM_NAME      ?= /cosim0
SOCK_PATH     ?= $(RUN_DIR)/cosim0.sock
# TCP 模式
PORT_BASE     ?= 9100
INSTANCE_ID   ?= 0
REMOTE_HOST   ?= 127.0.0.1
# Guest
GUEST_IP      ?= 10.0.0.1
PEER_IP       ?= 10.0.0.2
ROLE          ?= server
WAIT_SEC      ?= 60
GUEST_MEMORY  ?= 256M
# VCS
ETH_SHM       ?= /cosim_eth_dual
ETH_ROLE      ?= 0
ETH_CREATE    ?= 1
MAC_LAST      ?= 1
SIM_TIMEOUT   ?= 600000
VCS_TEST      ?= cosim_test
# TAP
TAP_DEV       ?= cosim0
TAP_IP        ?= 10.0.0.1
TAP_ETH_SHM   ?= /cosim_eth0

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

# ----- VCS 编译 -----
VCS_FLAGS  = -full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all -cc gcc
VCS_UVM    = -ntb_opts uvm-1.2
VIP_SRC    = pcie_tl_vip/src

BRIDGE_C_SRCS = \
	bridge/vcs/bridge_vcs.c bridge/vcs/sock_sync_vcs.c \
	bridge/common/shm_layout.c bridge/common/ring_buffer.c \
	bridge/common/dma_manager.c bridge/common/trace_log.c \
	bridge/common/eth_shm.c bridge/common/link_model.c \
	bridge/vcs/virtqueue_dma.c \
	bridge/eth/eth_mac_dpi.c bridge/eth/eth_port.c \
	bridge/common/transport_shm.c bridge/common/transport_tcp.c

VCS_CFLAGS  = -I $(CURDIR)/bridge/common -I $(CURDIR)/bridge/vcs \
              -I $(CURDIR)/bridge/qemu -I $(CURDIR)/bridge/eth \
              -std=c99 -D_POSIX_C_SOURCE=200112L
VCS_LDFLAGS = -Wl,--no-as-needed -lrt -lpthread

vcs-vip:
	@echo "[BUILD] 编译 VCS VIP 模式..."
	@mkdir -p $(VCS_SIM_DIR)
	vcs $(VCS_FLAGS) $(VCS_UVM) \
		+define+COSIM_VIP_MODE \
		-Mdir=$(VCS_SIM_DIR)/csrc \
		-CFLAGS "$(VCS_CFLAGS)" \
		-LDFLAGS "$(VCS_LDFLAGS)" \
		+incdir+bridge/vcs +incdir+$(VIP_SRC) +incdir+vcs-tb \
		bridge/vcs/bridge_vcs.sv \
		$(VIP_SRC)/pcie_tl_if.sv $(VIP_SRC)/pcie_tl_pkg.sv \
		vcs-tb/tb_top.sv vcs-tb/pcie_ep_stub.sv \
		vcs-tb/glue_if_to_stub.sv vcs-tb/cosim_pkg.sv vcs-tb/cosim_vip_top.sv \
		$(BRIDGE_C_SRCS) \
		-o $(VCS_SIM_DIR)/simv_vip
	@echo "[BUILD] simv_vip: $(VCS_SIM_DIR)/simv_vip"

vcs-legacy:
	@mkdir -p $(VCS_SIM_DIR)
	vcs $(VCS_FLAGS) $(VCS_UVM) \
		-Mdir=$(VCS_SIM_DIR)/csrc_legacy \
		-CFLAGS "$(VCS_CFLAGS)" -LDFLAGS "$(VCS_LDFLAGS)" \
		+incdir+bridge/vcs \
		bridge/vcs/bridge_vcs.sv \
		vcs-tb/tb_top.sv vcs-tb/pcie_ep_stub.sv \
		$(BRIDGE_C_SRCS) \
		-o $(VCS_SIM_DIR)/simv_legacy

vcs-vip-perf:
	@mkdir -p $(VCS_SIM_DIR)
	vcs $(VCS_FLAGS) $(VCS_UVM) \
		+define+COSIM_VIP_MODE +define+COSIM_PERF_EN \
		-Mdir=$(VCS_SIM_DIR)/csrc_perf \
		-CFLAGS "$(VCS_CFLAGS)" -LDFLAGS "$(VCS_LDFLAGS)" \
		+incdir+bridge/vcs +incdir+$(VIP_SRC) +incdir+vcs-tb \
		bridge/vcs/bridge_vcs.sv \
		$(VIP_SRC)/pcie_tl_if.sv $(VIP_SRC)/pcie_tl_pkg.sv \
		vcs-tb/tb_top.sv vcs-tb/pcie_ep_stub.sv \
		vcs-tb/glue_if_to_stub.sv vcs-tb/cosim_pkg.sv vcs-tb/cosim_vip_top.sv \
		$(BRIDGE_C_SRCS) \
		-o $(VCS_SIM_DIR)/simv_vip_perf

tap-bridge: bridge
	@echo "[BUILD] 编译 eth_tap_bridge..."
	$(MAKE) -C tools
	@echo "[BUILD] eth_tap_bridge: $(TAP_BRIDGE)"

# ============================================================
# 运行 — QEMU
# ============================================================
VERBOSE       ?= 0

ifeq ($(VERBOSE),1)
  _LOGLEVEL    = loglevel=7
  _COSIM_DEBUG = ,debug=on
else
  _LOGLEVEL    = quiet loglevel=1
  _COSIM_DEBUG =
endif

ifeq ($(TRANSPORT),tcp)
  _QEMU_DEV = cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=$(INSTANCE_ID)$(_COSIM_DEBUG)
else
  _QEMU_DEV = cosim-pcie-rc,shm_name=$(SHM_NAME),sock_path=$(SOCK_PATH)$(_COSIM_DEBUG)
endif

ifneq ($(ROOTFS),)
  _GUEST_ARGS  = -drive file=$(ROOTFS),format=raw,if=virtio
  _QEMU_APPEND = console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=$(GUEST_IP) peer_ip=$(PEER_IP)
else
  _GUEST_ARGS  =
  _QEMU_APPEND = console=ttyS0 $(_LOGLEVEL) guest_ip=$(GUEST_IP) peer_ip=$(PEER_IP)
endif

run-qemu:
	@if [ ! -f '$(QEMU)' ]; then \
		echo "[错误] QEMU 未找到: $(QEMU)"; \
		echo "  请指定: make run-qemu QEMU=/path/to/qemu-system-x86_64"; \
		exit 1; \
	fi
	@if [ ! -f '$(KERNEL)' ]; then \
		echo "[错误] Kernel 未找到: $(KERNEL)"; \
		echo "  请指定: make run-qemu KERNEL=/path/to/bzImage"; \
		exit 1; \
	fi
	@if [ -z '$(ROOTFS)' ]; then \
		echo "[警告] 未找到 rootfs，内核可能无法挂载根文件系统"; \
		echo "  请提供: ROOTFS=/path/to/rootfs.ext4"; \
	fi
	@mkdir -p $(LOG_DIR) $(RUN_DIR)
	@echo "============================================"
	@echo " QEMU ($(TRANSPORT) 模式)"
ifeq ($(TRANSPORT),tcp)
	@echo "  监听: $(PORT_BASE)-$$(($(PORT_BASE)+2))  Instance: $(INSTANCE_ID)"
else
	@echo "  SHM: $(SHM_NAME)  Sock: $(SOCK_PATH)"
endif
	@echo "  Guest: $(GUEST_IP)  Peer: $(PEER_IP)"
	@echo "  日志: $(LOG_DIR)/qemu.log"
	@echo "  调试: make run-qemu VERBOSE=1"
	@echo "  退出: Ctrl+A X 或 Guest 内 cosim-stop"
	@echo "============================================"
	$(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 \
		-kernel $(KERNEL) $(_GUEST_ARGS) \
		-append '$(strip $(_QEMU_APPEND))' \
		-device '$(strip $(_QEMU_DEV))' \
		-nographic -no-reboot -action panic=shutdown \
		-d unimp -D $(LOG_DIR)/qemu_debug.log \
		2>&1 | tee $(LOG_DIR)/qemu.log

# ============================================================
# 运行 — VCS
# ============================================================
ifeq ($(TRANSPORT),tcp)
  _VCS_TRANS = +transport=tcp +REMOTE_HOST=$(REMOTE_HOST) +PORT_BASE=$(PORT_BASE) +INSTANCE_ID=$(INSTANCE_ID)
else
  _VCS_TRANS = +SHM_NAME=$(SHM_NAME) +SOCK_PATH=$(SOCK_PATH)
endif

_VCS_ARGS = $(_VCS_TRANS) \
	+ETH_SHM=$(ETH_SHM) +ETH_ROLE=$(ETH_ROLE) +ETH_CREATE=$(ETH_CREATE) \
	+MAC_LAST=$(MAC_LAST) +SIM_TIMEOUT_MS=$(SIM_TIMEOUT) \
	+UVM_TESTNAME=$(VCS_TEST) +NO_WAVE

run-vcs:
	@mkdir -p $(LOG_DIR)
	@echo "============================================"
	@echo " VCS ($(TRANSPORT) 模式)"
ifeq ($(TRANSPORT),tcp)
	@echo "  连接: $(REMOTE_HOST):$(PORT_BASE)  Instance: $(INSTANCE_ID)"
else
	@echo "  SHM: $(SHM_NAME)  Sock: $(SOCK_PATH)"
endif
	@echo "  MAC: de:ad:be:ef:00:0$(MAC_LAST)  ETH Role: $(ETH_ROLE)"
	@echo "  日志: $(LOG_DIR)/vcs.log"
	@echo "============================================"
	cd $(VCS_SIM_DIR) && ./simv_vip $(_VCS_ARGS) 2>&1 | tee $(LOG_DIR)/vcs.log

# ============================================================
# 运行 — 双实例对打
# ============================================================
run-dual:
	@if [ ! -f '$(QEMU)' ]; then \
		echo "[错误] QEMU 未找到: $(QEMU)"; exit 1; \
	fi
	@if [ ! -f '$(KERNEL)' ]; then \
		echo "[错误] Kernel 未找到: $(KERNEL)"; exit 1; \
	fi
	@mkdir -p $(RUN_DIR)
	@LOGDIR=$(LOG_DIR)/dual_$$(date +%Y%m%d_%H%M%S); \
	mkdir -p $$LOGDIR; \
	PIDS=""; \
	trap 'echo ""; echo "清理进程..."; kill $$PIDS 2>/dev/null; wait 2>/dev/null' INT TERM; \
	echo "============================================"; \
	echo " 双实例对打 ($(TRANSPORT))  日志: $$LOGDIR/"; \
	echo "============================================"; \
	echo "[1/4] QEMU1 (10.0.0.1, server)..."; \
	if [ "$(TRANSPORT)" = "tcp" ]; then \
		DEV1="cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=0"; \
		DEV2="cosim-pcie-rc,transport=tcp,port_base=$(PORT_BASE),instance_id=1"; \
		VT1="+transport=tcp +REMOTE_HOST=$(REMOTE_HOST) +PORT_BASE=$(PORT_BASE) +INSTANCE_ID=0"; \
		VT2="+transport=tcp +REMOTE_HOST=$(REMOTE_HOST) +PORT_BASE=$(PORT_BASE) +INSTANCE_ID=1"; \
	else \
		DEV1="cosim-pcie-rc,shm_name=/cosim_d0,sock_path=$(RUN_DIR)/cosim_d0.sock"; \
		DEV2="cosim-pcie-rc,shm_name=/cosim_d1,sock_path=$(RUN_DIR)/cosim_d1.sock"; \
		VT1="+SHM_NAME=/cosim_d0 +SOCK_PATH=$(RUN_DIR)/cosim_d0.sock"; \
		VT2="+SHM_NAME=/cosim_d1 +SOCK_PATH=$(RUN_DIR)/cosim_d1.sock"; \
	fi; \
	$(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 -kernel $(KERNEL) $(_GUEST_ARGS) \
		-append 'console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=10.0.0.1 peer_ip=10.0.0.2' \
		-device "$$DEV1" -nographic -no-reboot \
		-d unimp -D $$LOGDIR/qemu1_debug.log > $$LOGDIR/qemu1.log 2>&1 & \
	PIDS="$$PIDS $$!"; sleep 2; \
	echo "[2/4] QEMU2 (10.0.0.2, client)..."; \
	$(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 -kernel $(KERNEL) $(_GUEST_ARGS) \
		-append 'console=ttyS0 root=/dev/vda rw $(_LOGLEVEL) guest_ip=10.0.0.2 peer_ip=10.0.0.1' \
		-device "$$DEV2" -nographic -no-reboot \
		-d unimp -D $$LOGDIR/qemu2_debug.log > $$LOGDIR/qemu2.log 2>&1 & \
	PIDS="$$PIDS $$!"; sleep 2; \
	echo "[3/4] VCS1 (RoleA, MAC=01)..."; \
	cd $(VCS_SIM_DIR) && ./simv_vip $$VT1 \
		+ETH_SHM=$(ETH_SHM) +ETH_ROLE=0 +ETH_CREATE=1 +MAC_LAST=1 \
		+SIM_TIMEOUT_MS=$(SIM_TIMEOUT) +UVM_TESTNAME=cosim_test +NO_WAVE \
		> $$LOGDIR/vcs1.log 2>&1 & \
	PIDS="$$PIDS $$!"; sleep 3; \
	echo "[4/4] VCS2 (RoleB, MAC=02)..."; \
	cd $(VCS_SIM_DIR) && ./simv_vip $$VT2 \
		+ETH_SHM=$(ETH_SHM) +ETH_ROLE=1 +ETH_CREATE=0 +MAC_LAST=2 \
		+SIM_TIMEOUT_MS=$(SIM_TIMEOUT) +UVM_TESTNAME=cosim_test +NO_WAVE \
		> $$LOGDIR/vcs2.log 2>&1 & \
	PIDS="$$PIDS $$!"; \
	echo "已启动 4 个进程，等待完成 (Ctrl+C 终止)..."; \
	wait; \
	echo ""; \
	echo "========== 结果 =========="; \
	echo "--- QEMU1 ---"; \
	grep -E "eth0|ping|iperf|PASS|FAIL|Mbits|error" $$LOGDIR/qemu1.log 2>/dev/null | grep -v "hash\|kfence\|Dentry" | tail -8; \
	echo "--- QEMU2 ---"; \
	grep -E "eth0|ping|iperf|PASS|FAIL|Mbits|error" $$LOGDIR/qemu2.log 2>/dev/null | grep -v "hash\|kfence\|Dentry" | tail -8; \
	echo "--- VCS1 ---"; \
	grep -E "TX notify|RX inject" $$LOGDIR/vcs1.log 2>/dev/null | tail -5; \
	echo "--- VCS2 ---"; \
	grep -E "TX notify|RX inject" $$LOGDIR/vcs2.log 2>/dev/null | tail -5; \
	echo "日志: $$LOGDIR/"

# ============================================================
# 运行 — TAP 桥接
# ============================================================
tap-check:
	@if [ ! -f "$(TAP_BRIDGE)" ]; then \
		echo "[错误] eth_tap_bridge 未编译"; \
		echo "  请先运行: make tap-bridge"; \
		exit 1; \
	fi
	@if /sbin/getcap "$(TAP_BRIDGE)" 2>/dev/null | grep -q cap_net_admin; then \
		echo "[OK] CAP_NET_ADMIN 已设置"; \
	else \
		echo ""; \
		echo "[错误] eth_tap_bridge 缺少 CAP_NET_ADMIN 权限"; \
		echo ""; \
		echo "  TAP 模式需要创建虚拟网卡，请让管理员执行:"; \
		echo "  sudo setcap cap_net_admin+ep $(TAP_BRIDGE)"; \
		echo ""; \
		echo "  执行后重新运行: make run-tap"; \
		exit 1; \
	fi

run-tap: tap-check
	@mkdir -p $(LOG_DIR)
	@echo "============================================"
	@echo " TAP 桥接"
	@echo "  TAP: $(TAP_DEV) ($(TAP_IP))  ETH SHM: $(TAP_ETH_SHM)"
	@echo "  日志: $(LOG_DIR)/tap_bridge.log"
	@echo "============================================"
	$(TAP_BRIDGE) -s $(TAP_ETH_SHM) -t $(TAP_DEV) 2>&1 | tee $(LOG_DIR)/tap_bridge.log

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
	rm -rf $(VCS_SIM_DIR)/csrc* $(VCS_SIM_DIR)/*.daidir

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
	@echo "  SIMV:   $(SIMV)  $$(test -f '$(SIMV)' && echo [OK] || echo [缺失])"
	@echo "  Kernel: $(KERNEL)  $$(test -f '$(KERNEL)' && echo [OK] || echo [缺失])"
	@echo "  Rootfs: $(if $(ROOTFS),$(ROOTFS)  $$(test -f '$(ROOTFS)' && echo [OK] || echo [缺失]),(未找到))"
	@echo "  VERBOSE: $(VERBOSE)"
	@echo "  TAP:    $(TAP_BRIDGE)  $$(test -f '$(TAP_BRIDGE)' && echo [OK] || echo [缺失])"
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
	@echo "  make bridge          Bridge 库"
	@echo "  make vcs-vip         VCS VIP 模式（需 VCS 工具链）"
	@echo "  make vcs-legacy      VCS Legacy 模式"
	@echo "  make tap-bridge      eth_tap_bridge"
	@echo ""
	@echo "单实例运行（2 个终端，先 QEMU 再 VCS）:"
	@echo ""
	@echo "  SHM 本地模式:"
	@echo "    终端1: make run-qemu"
	@echo "    终端2: make run-vcs"
	@echo ""
	@echo "  TCP 模式（可跨机）:"
	@echo "    终端1: make run-qemu TRANSPORT=tcp"
	@echo "    终端2: make run-vcs  TRANSPORT=tcp REMOTE_HOST=<IP>"
	@echo ""
	@echo "双实例对打（自动 4 进程，Guest↔Guest 网络验证）:"
	@echo "  make run-dual                    SHM 模式"
	@echo "  make run-dual TRANSPORT=tcp      TCP 模式"
	@echo ""
	@echo "TAP 桥接（Guest↔主机网络，需 CAP_NET_ADMIN）:"
	@echo "  make tap-check                   检查权限"
	@echo "  make run-tap                     启动 bridge"
	@echo "  首次: sudo setcap cap_net_admin+ep tools/eth_tap_bridge"
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
	@echo "  TRANSPORT=shm|tcp      传输模式（默认 shm）"
	@echo "  PORT_BASE=9100         TCP 端口基数"
	@echo "  INSTANCE_ID=0          实例 ID（端口=BASE+ID*3）"
	@echo "  REMOTE_HOST=127.0.0.1  VCS 连接目标"
	@echo "  GUEST_IP / PEER_IP     Guest IP 地址"
	@echo "  ROLE=server|client     Guest 角色"
	@echo "  MAC_LAST=1             MAC 末字节"
	@echo "  ETH_SHM                ETH 共享内存名"
	@echo "  SIM_TIMEOUT=600000     VCS 超时(ms)"
	@echo "  VERBOSE=0|1            日志级别（默认 0 安静，1 详细+debug）"
	@echo "  QEMU= SIMV= KERNEL= ROOTFS=  路径覆盖"
	@echo ""
	@echo "示例:"
	@echo "  make run-dual                            # 本机 SHM"
	@echo "  make run-dual TRANSPORT=tcp              # 本机 TCP"
	@echo "  make run-qemu TRANSPORT=tcp PORT_BASE=9100"
	@echo "  make run-vcs  TRANSPORT=tcp REMOTE_HOST=10.11.10.53"
	@echo ""
