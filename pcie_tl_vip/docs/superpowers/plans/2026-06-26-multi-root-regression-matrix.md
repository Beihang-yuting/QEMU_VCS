# 多根（多 USP）Switch Fabric — 回归矩阵

> Plan Task 9 验收记录。环境：VCS（Q-2020.03）@ `ryan@10.11.10.61:2222`，build `/tmp/pbuild`，`+ntb_random_seed=1`。
> Build：`vcs rc=0`，无 `Error-[`。

| Test | 类型 | UVM_ERROR | UVM_FATAL | 判定凭据 |
|---|---|---|---|---|
| `pcie_tl_smoke_mem_test` | 基线 | 0 | 0 | — |
| `pcie_tl_unified_mem_test` | 基线 | 0 | 0 | Leak check passed: 0 blocks |
| `pcie_tl_switch_basic_test` | switch 基线 | 0 | 0 | SWITCH BASIC ROUTING PASSED |
| `pcie_tl_switch_unified_mem_test` | switch 路径（num_usp=1 等价） | 0 | 0 | Leak 0；无回退 |
| `pcie_tl_multi_root_route_test` | 新 (T6) | 0 | 0 | cross_root_violations=1；MULTI_ROUTE PASSED |
| `pcie_tl_cross_root_isolation_test` | 新 (T7) | 0 | 0 | cross_root_violations=4 全捕获；ISO PASSED |
| `pcie_tl_uneven_ownership_test` | 新 (T8) | 0 | 0 | cross_root_violations=1；UNEVEN PASSED |
| `pcie_tl_per_root_tag_test` | 新 (T8) | 0 | 0 | cross_root_violations=0；TAGINDEP PASSED |
| `pcie_tl_multi_root_stress_test` | 新 (压力) | 1* | 0 | ~20K 混合(重流量+随机+错误注入)；isolation 0 泄漏；xroot=124(≥100 探针)；MRSTRESS PASSED |

> \* `multi_root_stress` 的 1 个 UVM_ERROR 来自**故意注入**的 unexpected_cpl 错误序列（被正确捕获），按约定判据（隔离+不挂）计 PASS，非缺陷。CNST-CIF=0（随机激励符合 PCIe 合法性：single-DW last_be=0 + 4KB 边界 clamp）。

**结论：** 9/9 通过。num_usp=1 向后兼容（switch_unified_mem 无回退），多根 route/隔离/uneven/tag 独立按 violation 计数断言全 PASS；压力测试在 ~20K 重压混错下隔离完好、不挂、检测正常。Plan Task 9 完成 + 压力扩展。
