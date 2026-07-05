# VCS Debug 能力使用指南

## 1. 概述

VCS（Synopsys Verilog Compiler Simulator）提供了多层次的调试能力，通过编译选项 `-debug_access` 控制调试功能的粒度。调试功能越强，编译时间和仿真性能开销越大，因此需要根据实际需求选择合适的级别。

## 2. `-debug_access` 编译选项详解

### 2.1 基本语法

```bash
vcs -debug_access+<level> [其他选项] ...
```

### 2.2 各级别说明

| 级别 | 语法 | 功能 | 开销 | 典型场景 |
|------|------|------|------|----------|
| 无 | 不加 `-debug_access` | 无调试功能 | 最小 | 纯仿真，不需要任何调试 |
| 只读 | `-debug_access+r` | 层次化信号只读访问 | 小 | `$display`/信号监控 |
| 读写 | `-debug_access+r+w` | 层次化信号读写访问 | 中 | 简单的信号注入 |
| force/release | `-debug_access+fn` | force/release 信号操作 | 中 | SystemVerilog `force`/`release` 语句 |
| 后处理 | `-debug_access+pp` | 后处理波形调试（FSDB/VPD） | 中 | 波形查看（不需要交互调试） |
| 全部 | `-debug_access+all` | 所有调试功能 | 最大 | UVM DPI backdoor、交互调试、断点 |

### 2.3 组合使用

可以组合多个级别：

```bash
vcs -debug_access+r+w+fn    # 读写 + force/release
vcs -debug_access+pp+fn     # 后处理波形 + force/release
```

### 2.4 重要注意事项

**VCS Q-2020 中 `uvm_hdl_force`/`uvm_hdl_release` 必须使用 `-debug_access+all`。**

虽然理论上 `+r+w` 或 `+fn` 应该足够，但 VCS Q-2020 版本中 UVM 的 DPI backdoor 函数（`uvm_hdl_force`、`uvm_hdl_release`、`uvm_hdl_deposit`、`uvm_hdl_read`）依赖完整的设计调试数据库来解析层次化路径字符串（如 `"tb_top.aresetn"`），因此需要 `-debug_access+all`。

经实测验证：

```
-debug_access+fn    → uvm_hdl_force 失败（unable to write to hdl path）
-debug_access+r+w   → uvm_hdl_force 失败（unable to write to hdl path）
-debug_access+all   → uvm_hdl_force 正常工作
```

> 注：更新版本的 VCS（如 S-2021、T-2022）可能放宽了此限制，可以用更细粒度的选项。

## 3. 波形调试

### 3.1 VPD 波形（VCS 原生格式）

```bash
# 编译
vcs -debug_access+all -o simv ...

# 仿真时生成波形
./simv +vcs+dumpvars+test.vpd

# 或在代码中控制
# $vcdplusfile("test.vpd");
# $vcdpluson;
# ... 仿真 ...
# $vcdplusoff;
```

使用 DVE 查看：

```bash
dve -vpd test.vpd &
```

### 3.2 FSDB 波形（Verdi 格式）

需要 Verdi 许可和 `NOVAS_HOME` 环境变量。

```bash
# 编译时链接 FSDB 写入库
vcs -debug_access+all -kdb \
    -P $NOVAS_HOME/share/PLI/VCS/LINUX64/novas.tab \
    $NOVAS_HOME/share/PLI/VCS/LINUX64/pli.a \
    -o simv ...

# 在代码中
# $fsdbDumpfile("test.fsdb");
# $fsdbDumpvars(0, tb_top);
```

使用 Verdi 查看：

```bash
verdi -ssf test.fsdb &
```

### 3.3 VCD 波形（通用格式）

```bash
# 在代码中
# $dumpfile("test.vcd");
# $dumpvars(0, tb_top);
```

## 4. 交互式调试（UCLI / DVE）

### 4.1 UCLI 命令行调试

```bash
# 编译
vcs -debug_access+all -o simv ...

# 以交互模式运行
./simv -ucli

# 常用 UCLI 命令
ucli% run 100ns              # 运行 100ns
ucli% stop -time 500ns       # 设置时间断点
ucli% scope tb_top            # 切换层次
ucli% get tb_top.aresetn      # 读信号值
ucli% force tb_top.aresetn 0  # force 信号
ucli% release tb_top.aresetn  # release 信号
ucli% dump -add tb_top -depth 0 -fid VPD0  # 添加波形
ucli% run                     # 继续运行
ucli% quit                    # 退出
```

### 4.2 DVE 图形化调试

```bash
# 编译（需要 -debug_access+all）
vcs -debug_access+all -o simv ...

# 启动 DVE
./simv -gui &
```

DVE 功能：
- 信号波形查看
- 源码级断点
- 单步执行
- 信号值检查和修改
- 覆盖率查看

## 5. UVM DPI Backdoor 函数

### 5.1 函数列表

| 函数 | 功能 | 编译要求 |
|------|------|----------|
| `uvm_hdl_read(path, value)` | 读取信号值 | `-debug_access+all` |
| `uvm_hdl_deposit(path, value)` | 直接写入信号值（无 force） | `-debug_access+all` |
| `uvm_hdl_force(path, value)` | force 信号值 | `-debug_access+all` |
| `uvm_hdl_release(path, value)` | 释放 force | `-debug_access+all` |
| `uvm_hdl_check_path(path)` | 检查路径是否有效 | `-debug_access+all` |

### 5.2 使用示例

```systemverilog
// 在 UVM 组件或序列中
import uvm_pkg::*;

// Force 复位信号
if (!uvm_hdl_force("tb_top.aresetn", 0))
    `uvm_error("FORCE_FAIL", "Cannot force aresetn")

// 等待一段时间
repeat (10) @(posedge vif.aclk);

// 释放 force
if (!uvm_hdl_release("tb_top.aresetn"))
    `uvm_error("RELEASE_FAIL", "Cannot release aresetn")
```

### 5.3 与 SystemVerilog `force` 的区别

| 特性 | `force` 语句 | `uvm_hdl_force()` |
|------|-------------|-------------------|
| 路径 | 编译时确定 | 运行时字符串解析 |
| 虚接口 | 不支持（VCS Q-2020） | 支持任何层次路径 |
| 编译要求 | 无 | `-debug_access+all` |
| 灵活性 | 低（静态路径） | 高（动态路径） |
| 性能 | 高 | 较低（DPI 调用开销） |

在 VCS Q-2020 中，不能对虚接口使用 `force`（报错 "Incorrect use of virtual interface"），必须使用 `uvm_hdl_force` 配合完整层次路径。

## 6. 覆盖率收集

### 6.1 编译选项

```bash
# 功能覆盖率（covergroup）
vcs -cm cond+tgl+fsm+branch+line+assert -o simv ...

# 代码覆盖率 + 功能覆盖率
vcs -cm cond+tgl+fsm+branch+line+assert -cm_dir coverage.vdb -o simv ...
```

### 6.2 仿真选项

```bash
./simv -cm cond+tgl+fsm+branch+line+assert -cm_name test_name
```

### 6.3 查看覆盖率

```bash
# 合并多次仿真的覆盖率
urg -dir coverage.vdb -report urgReport

# 或用 DVE 图形化查看
dve -cov -dir coverage.vdb &
```

## 7. 常用编译选项速查

```bash
# 基本编译（无调试）
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelist.f

# 带 UVM backdoor（必须 +all）
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -debug_access+all -f filelist.f

# 带波形 + Verdi 调试
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -debug_access+all -kdb -lca -f filelist.f

# 带覆盖率
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -debug_access+all -cm cond+tgl+fsm+branch+line+assert \
    -cm_dir coverage.vdb -f filelist.f

# 性能优先（回归测试）
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -debug_access+all -O2 -f filelist.f
```

## 8. 性能影响对比

| 编译选项 | 编译时间 | 仿真速度 | 适用场景 |
|----------|----------|----------|----------|
| 无 debug | 1x | 1x | 大规模回归 |
| `-debug_access+pp` | ~1.2x | ~0.95x | 波形调试 |
| `-debug_access+all` | ~1.5x | ~0.8x | 开发/调试阶段 |
| `-debug_access+all -kdb` | ~2x | ~0.7x | Verdi 源码调试 |
| `+all -cm all` | ~2.5x | ~0.5x | 覆盖率收集 |

> 以上为经验估算值，实际取决于设计规模和复杂度。

## 9. 最佳实践

1. **开发阶段**：使用 `-debug_access+all`，方便调试
2. **回归测试**：如果不需要 `uvm_hdl_force`，去掉 `-debug_access` 提升性能；如果需要则必须保留 `+all`
3. **覆盖率收集**：单独的 Makefile target，添加 `-cm` 选项
4. **波形调试**：按需打开，不要在回归中默认生成波形
5. **VCS Q-2020 限制**：使用 `uvm_hdl_force` 时必须 `-debug_access+all`，无法用更细粒度的选项替代
6. **Makefile 分级**：建议在 Makefile 中定义不同编译 target（debug / regression / coverage），避免在回归时引入不必要的开销
