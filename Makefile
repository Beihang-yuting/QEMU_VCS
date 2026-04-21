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
VCS_FLAGS = -full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all
VCS_UVM   = -ntb_opts uvm-1.2

VIP_SRC_DIR = pcie_tl_vip/src

# C bridge 源文件（直接编译，避免跨 GLIBC 版本 .so 依赖）
BRIDGE_C_SRCS = \
	bridge/vcs/bridge_vcs.c \
	bridge/vcs/sock_sync_vcs.c \
	bridge/common/shm_layout.c \
	bridge/common/ring_buffer.c \
	bridge/common/dma_manager.c \
	bridge/common/trace_log.c \
	bridge/common/eth_shm.c \
	bridge/common/link_model.c \
	bridge/vcs/vq_eth_stub.c \
	bridge/common/transport_shm.c \
	bridge/common/transport_tcp.c

VCS_CFLAGS = -I $(CURDIR)/bridge/common -I $(CURDIR)/bridge/vcs -I $(CURDIR)/bridge/qemu -std=c99
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
