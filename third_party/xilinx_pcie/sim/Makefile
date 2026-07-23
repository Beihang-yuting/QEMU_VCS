#=============================================================================
# Xilinx PCIe TL-Layer BFM - VCS 仿真 Makefile
# 使用方法：
#   make compile              编译所有源文件
#   make sim TEST=<test_name> 运行指定测试
#   make sanity               运行 sanity 测试（基本功能验证）
#   make straddle             运行 straddle 测试（跨 DW 边界传输验证）
#   make loopback             运行 loopback 测试（RC->EP->RC 回环验证）
#   make clean                清除所有编译和仿真产物
#=============================================================================

#-----------------------------------------------------------------------------
# 工具链配置
#-----------------------------------------------------------------------------
VCS     ?= vcs                    # VCS 仿真器可执行文件路径

#-----------------------------------------------------------------------------
# 仿真参数（可通过命令行覆盖）
#-----------------------------------------------------------------------------
TEST        ?= xilinx_pcie_sanity_test   # 默认测试用例名
DATA_WIDTH  ?= 256                        # AXI-Stream 数据位宽（64/128/256/512）
STRADDLE_EN ?= 0                          # 是否使能 straddle 模式（0=关闭，1=开启）
SEED        ?= 1                          # 随机种子（使用 random 表示随机种子）

#-----------------------------------------------------------------------------
# 目录配置
#-----------------------------------------------------------------------------
SIM_DIR     := $(shell pwd)
WORK_DIR    := $(SIM_DIR)/work
LOG_DIR     := $(SIM_DIR)/logs

#-----------------------------------------------------------------------------
# VCS 编译选项
#-----------------------------------------------------------------------------
VCS_COMPILE_OPTS  = -sverilog                  # 启用 SystemVerilog 语法
VCS_COMPILE_OPTS += -ntb_opts uvm-1.2          # 使用 UVM 1.2 库
VCS_COMPILE_OPTS += -timescale=1ns/1ps         # 仿真时间精度
VCS_COMPILE_OPTS += -full64                    # 64 位编译模式
VCS_COMPILE_OPTS += -l $(LOG_DIR)/compile.log  # 编译日志文件
VCS_COMPILE_OPTS += -o $(WORK_DIR)/simv        # 输出可执行文件
VCS_COMPILE_OPTS += -f filelist.f              # 编译文件列表
VCS_COMPILE_OPTS += +define+XILINX_DATA_W=$(DATA_WIDTH) # 数据位宽宏定义 (SV 宏名 XILINX_DATA_W)
VCS_COMPILE_OPTS += +define+STRADDLE_EN=$(STRADDLE_EN)  # Straddle 使能宏定义

#-----------------------------------------------------------------------------
# VCS 仿真选项
#-----------------------------------------------------------------------------
VCS_SIM_OPTS  = +UVM_TESTNAME=$(TEST)          # 指定 UVM test class 名
VCS_SIM_OPTS += +DATA_WIDTH=$(DATA_WIDTH)      # 传递数据位宽参数
VCS_SIM_OPTS += +STRADDLE_EN=$(STRADDLE_EN)   # 传递 straddle 使能参数
VCS_SIM_OPTS += +UVM_VERBOSITY=UVM_MEDIUM      # UVM 日志级别

# 处理随机种子：若 SEED=random 则使用 VCS 自动随机种子
ifeq ($(SEED),random)
VCS_SIM_OPTS += +ntb_random_seed_automatic
else
VCS_SIM_OPTS += +ntb_random_seed=$(SEED)
endif

VCS_SIM_OPTS += -l $(LOG_DIR)/$(TEST)_$(SEED).log   # 仿真日志文件

#=============================================================================
# Make 目标
#=============================================================================

.PHONY: all compile sim sanity straddle loopback clean help

# 默认目标：编译并运行 sanity 测试
all: sanity

#-----------------------------------------------------------------------------
# compile：编译所有 SV 源文件，生成 simv 可执行文件
#-----------------------------------------------------------------------------
compile: | $(WORK_DIR) $(LOG_DIR)
	@echo "=========================================="
	@echo " 编译 Xilinx PCIe BFM..."
	@echo " DATA_WIDTH  = $(DATA_WIDTH)"
	@echo " STRADDLE_EN = $(STRADDLE_EN)"
	@echo "=========================================="
	$(VCS) $(VCS_COMPILE_OPTS)
	@echo "编译完成，可执行文件：$(WORK_DIR)/simv"

#-----------------------------------------------------------------------------
# sim：运行仿真（依赖已编译的 simv）
#-----------------------------------------------------------------------------
sim: | $(LOG_DIR)
	@echo "=========================================="
	@echo " 运行测试：$(TEST)"
	@echo " DATA_WIDTH  = $(DATA_WIDTH)"
	@echo " STRADDLE_EN = $(STRADDLE_EN)"
	@echo " SEED        = $(SEED)"
	@echo "=========================================="
	$(WORK_DIR)/simv $(VCS_SIM_OPTS)

#-----------------------------------------------------------------------------
# sanity：编译并运行基本功能验证测试
#-----------------------------------------------------------------------------
sanity: TEST := xilinx_pcie_sanity_test
sanity: compile sim

#-----------------------------------------------------------------------------
# straddle：编译并运行 straddle 模式测试（强制使能 straddle）
#-----------------------------------------------------------------------------
straddle: TEST        := xilinx_pcie_straddle_test
straddle: STRADDLE_EN := 1
straddle: compile sim

#-----------------------------------------------------------------------------
# loopback：编译并运行 RC->EP->RC 回环测试
#-----------------------------------------------------------------------------
loopback: TEST := xilinx_pcie_loopback_test
loopback: compile sim

#-----------------------------------------------------------------------------
# clean：清除所有编译和仿真产物
#-----------------------------------------------------------------------------
clean:
	@echo "清除编译和仿真产物..."
	rm -rf $(WORK_DIR)
	rm -rf $(LOG_DIR)
	rm -rf csrc
	rm -rf ucli.key
	rm -rf vc_hdrs.h
	rm -rf .vcs_lib_lock
	rm -rf DVEfiles
	rm -rf novas.*
	rm -rf verdi_config_file
	@echo "清除完成"

#-----------------------------------------------------------------------------
# 目录创建规则
#-----------------------------------------------------------------------------
$(WORK_DIR):
	mkdir -p $(WORK_DIR)

$(LOG_DIR):
	mkdir -p $(LOG_DIR)

#-----------------------------------------------------------------------------
# help：显示使用帮助
#-----------------------------------------------------------------------------
help:
	@echo "Xilinx PCIe TL-Layer BFM 仿真 Makefile"
	@echo ""
	@echo "使用方法："
	@echo "  make compile              - 编译所有源文件"
	@echo "  make sim TEST=<name>      - 运行指定测试（需先 compile）"
	@echo "  make sanity               - 编译并运行 sanity 测试"
	@echo "  make straddle             - 编译并运行 straddle 测试"
	@echo "  make loopback             - 编译并运行 loopback 测试"
	@echo "  make clean                - 清除所有产物"
	@echo ""
	@echo "变量（可通过命令行覆盖）："
	@echo "  VCS         = $(VCS)"
	@echo "  TEST        = $(TEST)"
	@echo "  DATA_WIDTH  = $(DATA_WIDTH)   (可选: 64, 128, 256, 512)"
	@echo "  STRADDLE_EN = $(STRADDLE_EN)      (0=关闭, 1=开启)"
	@echo "  SEED        = $(SEED)      (整数或 'random')"
