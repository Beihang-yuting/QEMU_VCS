# ============================================================
# CoSim Platform Makefile
# 统一编译 + 运行 + 测试入口
# 用法: make help
# ============================================================
SHELL := /bin/bash

.PHONY: all help bridge cosim-lib qemu-device run-qemu \
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
GUEST_TYPE    ?= ubuntu
# 镜像路径: guest/images/<GUEST_TYPE>/
KERNEL        ?= $(firstword $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/bzImage) \
                              $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/vmlinuz))
ROOTFS        ?= $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/rootfs.ext4)
INITRD        ?= $(wildcard $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/initramfs.gz)

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
# Guest（TAP Host=10.0.0.1，Guest 默认 10.0.0.2）
GUEST_IP      ?= 10.0.0.2
PEER_IP       ?= 10.0.0.1
ifeq ($(GUEST_TYPE),debian)
  GUEST_MEMORY  ?= 512M
else
  GUEST_MEMORY  ?= 256M
endif

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
VERBOSE       ?= 0

ifeq ($(VERBOSE),1)
  _LOGLEVEL    = loglevel=7
  _COSIM_DEBUG = ,debug=on
else
  _LOGLEVEL    = quiet loglevel=1
  _COSIM_DEBUG =
endif

# 运行时库路径（确保源码编译的 glib 等库可被找到）
_QEMU_LD_PATH = LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:$(BRIDGE_LIB_DIR):$${LD_LIBRARY_PATH:-}

_COSIM_DEV_TYPE = cosim-pcie-rc

ifeq ($(TRANSPORT),tcp)
  _QEMU_DEV = $(_COSIM_DEV_TYPE),transport=tcp,port_base=$(PORT_BASE),instance_id=$(INSTANCE_ID)$(_COSIM_DEBUG)
else
  _QEMU_DEV = $(_COSIM_DEV_TYPE),shm_name=$(SHM_NAME),sock_path=$(SOCK_PATH)$(_COSIM_DEBUG)
endif

ifneq ($(ROOTFS),)
  _GUEST_ARGS  = -drive file=$(ROOTFS),format=raw,if=none,id=rootdisk -device virtio-blk-pci,drive=rootdisk,addr=0x10 $(if $(INITRD),-initrd $(INITRD))
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
	@MISSING=$$($(_QEMU_LD_PATH) ldd '$(QEMU)' 2>/dev/null | grep 'not found' || true); \
	if [ -n "$$MISSING" ]; then \
		echo "[错误] QEMU 动态库缺失:"; \
		echo "$$MISSING" | sed 's/^/  /'; \
		echo "  解决方法: 在本机重新编译 QEMU: ./setup.sh"; \
		echo "  或设置: export LD_LIBRARY_PATH=/path/to/libs"; \
		exit 1; \
	fi
	@if ! $(_QEMU_LD_PATH) '$(QEMU)' --version >/dev/null 2>&1; then \
		echo "[错误] QEMU 无法运行: $(QEMU)"; \
		ERR=$$($(_QEMU_LD_PATH) '$(QEMU)' --version 2>&1 || true); \
		echo "$$ERR" | head -3 | sed 's/^/  /'; \
		if echo "$$ERR" | grep -q 'undefined symbol'; then \
			SYM=$$(echo "$$ERR" | grep -oP 'undefined symbol: \K\S+'); \
			echo "  缺少符号: $$SYM"; \
			if echo "$$SYM" | grep -q '^g_'; then \
				echo "  原因: 本机 glib 版本过低（QEMU 9.2 需要 glib >= 2.66）"; \
				echo "  解决: 在本机运行 ./setup.sh 编译 QEMU，或升级 glib"; \
			fi; \
		fi; \
		exit 1; \
	fi
	@if [ -z '$(KERNEL)' ] || [ ! -f '$(KERNEL)' ]; then \
		echo "[错误] Kernel 未找到 (GUEST_TYPE=$(GUEST_TYPE))"; \
		echo "  查找路径: $(PROJECT_DIR)/guest/images/$(GUEST_TYPE)/bzImage"; \
		echo "  可用镜像:"; \
		ls -d $(PROJECT_DIR)/guest/images/*/bzImage 2>/dev/null | sed 's|.*/images/||;s|/bzImage||;s|^|    |' || echo "    (无)"; \
		echo "  解决方法:"; \
		echo "    make run-qemu GUEST_TYPE=debian    # 切换 Guest 类型"; \
		echo "    make run-qemu KERNEL=/path/to/bzImage"; \
		exit 1; \
	fi
	@if [ -z '$(ROOTFS)' ] || [ ! -f '$(ROOTFS)' ]; then \
		echo "[警告] 未找到 rootfs (GUEST_TYPE=$(GUEST_TYPE))"; \
		echo "  请构建或指定: ROOTFS=/path/to/rootfs.ext4"; \
	fi
	@mkdir -p $(LOG_DIR) $(RUN_DIR)
	@echo ""
	@echo -e "\033[0;36m╔══════════════════════════════════════════════╗\033[0m"
	@echo -e "\033[0;36m║\033[1;36m  CoSim QEMU — $(TRANSPORT) 模式\033[0m\033[0;36m                        ║\033[0m"
	@echo -e "\033[0;36m╠══════════════════════════════════════════════╣\033[0m"
ifeq ($(TRANSPORT),tcp)
	@echo -e "\033[0;36m║\033[0;32m  监听:  $(PORT_BASE)-$$(($(PORT_BASE)+2))  Instance: $(INSTANCE_ID)\033[0m\033[0;36m              ║\033[0m"
else
	@echo -e "\033[0;36m║\033[0;32m  SHM:   $(SHM_NAME)\033[0m\033[0;36m                                  ║\033[0m"
endif
	@echo -e "\033[0;36m║\033[0;32m  Guest: $(GUEST_IP) → Peer: $(PEER_IP)\033[0m\033[0;36m              ║\033[0m"
	@echo -e "\033[0;36m║\033[0m  日志:  $(LOG_DIR)/qemu.log\033[0;36m               ║\033[0m"
	@echo -e "\033[0;36m╠══════════════════════════════════════════════╣\033[0m"
	@echo -e "\033[0;36m║\033[0;33m  调试:  make run-qemu VERBOSE=1\033[0m\033[0;36m             ║\033[0m"
	@echo -e "\033[0;36m║\033[0;33m  超时:  COSIM_CONNECT_TIMEOUT=180（秒）\033[0m\033[0;36m      ║\033[0m"
	@echo -e "\033[0;36m║\033[0;33m  退出:  Ctrl+C 取消 / Ctrl+A X 退出 Guest\033[0m\033[0;36m  ║\033[0m"
	@echo -e "\033[0;36m╚══════════════════════════════════════════════╝\033[0m"
	@echo ""
	@QEMU_PID=""; \
	cleanup() { \
		if [ -n "$$QEMU_PID" ] && kill -0 $$QEMU_PID 2>/dev/null; then \
			echo ""; \
			echo "[cosim] 正在停止 QEMU (PID $$QEMU_PID)..."; \
			kill -TERM $$QEMU_PID 2>/dev/null; \
			wait $$QEMU_PID 2>/dev/null; \
		fi; \
		echo "[cosim] 已清理退出"; \
	}; \
	trap cleanup INT TERM; \
	$(_QEMU_LD_PATH) \
	$(QEMU) -M q35 -m $(GUEST_MEMORY) -smp 1 \
		-kernel $(KERNEL) $(_GUEST_ARGS) \
		-append '$(strip $(_QEMU_APPEND))' \
		-device '$(strip $(_QEMU_DEV))' \
		-nographic -no-reboot -action panic=shutdown \
		-d unimp -D $(LOG_DIR)/qemu_debug.log \
		2>&1 | tee $(LOG_DIR)/qemu.log & \
	QEMU_PID=$$!; \
	wait $$QEMU_PID 2>/dev/null; \
	EXIT_CODE=$$?; \
	trap - INT TERM; \
	if [ $$EXIT_CODE -ne 0 ]; then \
		echo "[cosim] QEMU 退出码: $$EXIT_CODE"; \
	fi

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
	@echo ""
	@echo "运行 QEMU:"
	@echo "    make run-qemu                  SHM 本地模式"
	@echo "    make run-qemu TRANSPORT=tcp    TCP 模式（可跨机）"
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
	@echo "  GUEST_IP / PEER_IP     Guest IP 地址"
	@echo "  VERBOSE=0|1            日志级别（默认 0 安静，1 详细+debug）"
	@echo "  GUEST_TYPE=ubuntu|debian  Guest 系统（默认 ubuntu）"
	@echo "  QEMU= KERNEL= ROOTFS=  路径覆盖"
	@echo ""
