.PHONY: all bridge test-unit test-integration clean

BUILD_DIR := build

all: bridge

bridge:
	cmake -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Debug
	cmake --build $(BUILD_DIR) -j$$(nproc)

test-unit: bridge
	cd $(BUILD_DIR) && ctest --test-dir tests/unit --output-on-failure -V

test-integration: bridge
	cd $(BUILD_DIR) && ctest --test-dir tests/integration --output-on-failure -V

test: test-unit test-integration

clean:
	rm -rf $(BUILD_DIR)

# ===== VCS 仿真目标 =====
# -cc gcc: 强制用 gcc（C 编译器）编译 DPI-C .c 文件，避免 g++ 的 C++ 严格类型检查
VCS_FLAGS = -full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all -cc gcc
VCS_UVM   = -ntb_opts uvm-1.2

VIP_SRC_DIR = pcie_tl_vip/src

# C bridge 源文件（直接编译，避免跨 GLIBC 版本 .so 依赖）
# 注：P3 TAP 模式需要真实 virtqueue 处理（virtqueue_dma.c）和 ETH MAC DPI
# （eth_mac_dpi.c + eth_port.c）。P5 曾把 BRIDGE_C_SRCS 简化成 vq_eth_stub.c
# 仅供 VIP smoke test 链接，但那会让 TAP/Phase3 完整路径失效。此处还原真实实现
# 以支持 Guest Linux virtio-net driver → vring → DMA → ETH SHM → TAP 闭环。
BRIDGE_C_SRCS = \
	bridge/vcs/bridge_vcs.c \
	bridge/vcs/sock_sync_vcs.c \
	bridge/common/shm_layout.c \
	bridge/common/ring_buffer.c \
	bridge/common/dma_manager.c \
	bridge/common/trace_log.c \
	bridge/common/eth_shm.c \
	bridge/common/link_model.c \
	bridge/vcs/virtqueue_dma.c \
	bridge/eth/eth_mac_dpi.c \
	bridge/eth/eth_port.c \
	bridge/common/transport_shm.c \
	bridge/common/transport_tcp.c

VCS_CFLAGS = -I $(CURDIR)/bridge/common -I $(CURDIR)/bridge/vcs -I $(CURDIR)/bridge/qemu -I $(CURDIR)/bridge/eth -std=c99 -D_POSIX_C_SOURCE=200112L
VCS_LDFLAGS = -lrt -lpthread

# Legacy 模式
.PHONY: vcs-legacy
vcs-legacy:
	vcs $(VCS_FLAGS) $(VCS_UVM) \
		-CFLAGS "$(VCS_CFLAGS)" \
		-LDFLAGS "$(VCS_LDFLAGS)" \
		+incdir+bridge/vcs \
		bridge/vcs/bridge_vcs.sv \
		vcs-tb/tb_top.sv vcs-tb/pcie_ep_stub.sv \
		$(BRIDGE_C_SRCS) \
		-o $(BUILD_DIR)/simv_legacy

# VIP 模式
.PHONY: vcs-vip
vcs-vip:
	vcs $(VCS_FLAGS) $(VCS_UVM) \
		+define+COSIM_VIP_MODE \
		-CFLAGS "$(VCS_CFLAGS)" \
		-LDFLAGS "$(VCS_LDFLAGS)" \
		+incdir+bridge/vcs \
		+incdir+$(VIP_SRC_DIR) \
		+incdir+vcs-tb \
		bridge/vcs/bridge_vcs.sv \
		$(VIP_SRC_DIR)/pcie_tl_if.sv \
		$(VIP_SRC_DIR)/pcie_tl_pkg.sv \
		vcs-tb/tb_top.sv vcs-tb/pcie_ep_stub.sv \
		vcs-tb/glue_if_to_stub.sv \
		vcs-tb/cosim_pkg.sv \
		vcs-tb/cosim_vip_top.sv \
		$(BRIDGE_C_SRCS) \
		-o $(BUILD_DIR)/simv_vip

# VIP + 性能统计
.PHONY: vcs-vip-perf
vcs-vip-perf:
	vcs $(VCS_FLAGS) $(VCS_UVM) \
		+define+COSIM_VIP_MODE +define+COSIM_PERF_EN \
		-CFLAGS "$(VCS_CFLAGS)" \
		-LDFLAGS "$(VCS_LDFLAGS)" \
		+incdir+bridge/vcs \
		+incdir+$(VIP_SRC_DIR) \
		+incdir+vcs-tb \
		bridge/vcs/bridge_vcs.sv \
		$(VIP_SRC_DIR)/pcie_tl_if.sv \
		$(VIP_SRC_DIR)/pcie_tl_pkg.sv \
		vcs-tb/tb_top.sv vcs-tb/pcie_ep_stub.sv \
		vcs-tb/glue_if_to_stub.sv \
		vcs-tb/cosim_pkg.sv \
		vcs-tb/cosim_vip_top.sv \
		$(BRIDGE_C_SRCS) \
		-o $(BUILD_DIR)/simv_vip_perf

# 运行目标
.PHONY: run-legacy run-vip
run-legacy: vcs-legacy
	$(BUILD_DIR)/simv_legacy +SHM_NAME=/cosim0 +SOCK_PATH=/tmp/cosim.sock

run-vip: vcs-vip
	$(BUILD_DIR)/simv_vip +SHM_NAME=/cosim0 +SOCK_PATH=/tmp/cosim.sock \
		+UVM_TESTNAME=cosim_test

# ===== TCP 跨机模式 =====
# QEMU 侧 (server, listen)
.PHONY: run-vip-tcp-server
run-vip-tcp-server: vcs-vip
	$(BUILD_DIR)/simv_vip +transport=tcp +LISTEN=0.0.0.0 +PORT_BASE=9100 +INSTANCE_ID=0 \
		+UVM_TESTNAME=cosim_test

# VCS 侧 (client, connect) — 用法: make run-vip-tcp-client REMOTE_HOST=192.168.1.100
.PHONY: run-vip-tcp-client
run-vip-tcp-client: vcs-vip
	$(BUILD_DIR)/simv_vip +transport=tcp +REMOTE_HOST=$(REMOTE_HOST) +PORT_BASE=9100 +INSTANCE_ID=0 \
		+UVM_TESTNAME=cosim_test
