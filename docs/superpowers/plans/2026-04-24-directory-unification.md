# 目录统一 + 日志路径 + Buildroot 集成 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 统一项目目录结构：VCS 仿真产物到 `vcs_sim/`，镜像到 `guest/images/`，日志到 `logs/`，集成 buildroot 构建。

**Architecture:** 分 3 个 Task 依次交付——Task 1 改 Makefile + resolve 函数（目录统一），Task 2 改日志路径，Task 3 加 buildroot 集成 + 更新文档。每个 Task 独立可用不破坏 TCP 模式。

**Tech Stack:** Bash (Makefile, cosim.sh, setup.sh, config.env)

---

### Task 1: Makefile VCS_SIM_DIR + resolve 函数路径统一

**Files:**
- Modify: `Makefile`
- Modify: `cosim.sh`
- Modify: `setup.sh`
- Modify: `config.env`
- Modify: `.gitignore`

- [ ] **Step 1: Makefile 新增 VCS_SIM_DIR，VCS 产物路径改为 vcs_sim/**

- [ ] **Step 2: cosim.sh resolve_simv 搜索路径加 vcs_sim/simv_vip 为第一优先级**

- [ ] **Step 3: cosim.sh resolve_kernel 搜索路径加 guest/images/bzImage 为第一优先级**

- [ ] **Step 4: setup.sh IMAGES_DIR 改为 guest/images，VCS 产物检查路径改为 vcs_sim/simv_vip**

- [ ] **Step 5: config.env 新增 KERNEL_PATH / ROOTFS_PATH**

- [ ] **Step 6: .gitignore 更新**

- [ ] **Step 7: 语法检查 + 61 上验证 make vcs-vip + 提交**

---

### Task 2: 日志从 /tmp/ 改到 logs/

**Files:**
- Modify: `cosim.sh`

- [ ] **Step 1: run_single_phase / run_dual_phase / run_tap_test 的 LOGDIR 改为 ${PROJECT_DIR}/logs/**

- [ ] **Step 2: cmd_log 搜索路径改为 ${PROJECT_DIR}/logs/**

- [ ] **Step 3: 语法检查 + 提交**

---

### Task 3: Buildroot 集成 + 文档更新

**Files:**
- Modify: `setup.sh`
- Create: `guest/buildroot_defconfig`
- Modify: `docs/SETUP-GUIDE.md`

- [ ] **Step 1: setup.sh Guest 构建交互菜单（1=快速/2=精简/3=跳过）**

- [ ] **Step 2: buildroot 源码获取（网络检测 + 在线下载 / 离线 tarball）**

- [ ] **Step 3: buildroot 编译 + 产出拷贝到 guest/images/**

- [ ] **Step 4: 创建 guest/buildroot_defconfig**

- [ ] **Step 5: 更新 SETUP-GUIDE.md（路径统一 + 完整测试手册）**

- [ ] **Step 6: 提交**
