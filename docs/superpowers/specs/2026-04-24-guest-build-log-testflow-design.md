# Guest 构建集成 + 目录统一 + 测试流程完善 设计文档

## 目标

1. 集成 buildroot 到 setup.sh，支持在线/离线构建
2. 统一镜像路径 `guest/images/`
3. 日志从 `/tmp/` 改到项目内 `logs/`
4. VCS 仿真产物独立到 `vcs_sim/`
5. 完善 eth_tap_bridge 构建和端到端测试流程

**约束：不影响已调通的 TCP 跨机模式。**

---

## 1. 目录结构

```
cosim-platform/
├── build/                       ← Bridge CMake 产物（不变）
│   └── bridge/libcosim_bridge.so
├── guest/
│   ├── images/                  ← 统一镜像存放
│   │   ├── bzImage
│   │   ├── rootfs.ext4
│   │   └── initramfs-*.gz
│   ├── overlay/                 ← 现有 init 脚本
│   └── buildroot_defconfig      ← 自定义精简 defconfig
├── vcs_sim/                     ← VCS 仿真专用（替代 build/simv_vip）
│   ├── simv_vip                 ← 编译产物
│   ├── simv_vip.daidir/         ← VCS 编译缓存
│   ├── cosim_wave.fsdb          ← 波形文件
│   ├── compile.log              ← VCS 编译日志
│   └── sim_*.log                ← 仿真运行日志
├── logs/                        ← QEMU/TAP/测试运行日志
│   ├── phase1_20260424_100000/
│   │   ├── qemu.log
│   │   ├── vcs.log
│   │   └── tap_bridge.log
│   └── ...
├── third_party/
│   ├── qemu/
│   ├── glib-2.66.8/
│   └── buildroot-2024.02.1/     ← 新增
├── config.env                   ← 新增 KERNEL_PATH / ROOTFS_PATH
└── .gitignore                   ← 新增 logs/ vcs_sim/ guest/images/ third_party/
```

## 2. Makefile 变更

```makefile
# 旧
BUILD_DIR := build

# 新：Bridge 和 VCS 分离
BUILD_DIR   := build
VCS_SIM_DIR := vcs_sim

# vcs-vip 目标产出到 vcs_sim/
vcs-vip:
    mkdir -p $(VCS_SIM_DIR)
    vcs ... -o $(VCS_SIM_DIR)/simv_vip
```

## 3. setup.sh Guest 构建流程

### 3.1 交互式选择

```
[步骤] 准备 Guest 环境

选择 Guest 构建方式:
  1) 快速构建 — buildroot 默认配置 (qemu_x86_64_defconfig)
     完整 Linux + 常用工具，编译约 30-60 分钟
  2) 精简构建 — 自定义配置，仅 virtio + 测试工具（推荐）
     含 virtio_net, iperf3, netcat, arping，编译约 10-20 分钟
  3) 跳过 — 手动准备镜像到 guest/images/

请选择 [1/2/3]:
```

命令行：`--guest-build quick|minimal|skip`

### 3.2 buildroot 源码获取

```
检测网络 → 有网: wget tarball → third_party/
           无网: 检测 third_party/buildroot-*.tar.gz
                 ├─ 存在: 解压
                 └─ 不存在: 打印地址提示手动放置
```

### 3.3 编译 + 产出拷贝

```bash
cd third_party/buildroot-2024.02.1
make <defconfig>
make -j$(nproc)
cp output/images/bzImage ../../guest/images/
cp output/images/rootfs.ext4 ../../guest/images/
```

## 4. 路径统一变更

### 4.1 config.env

```bash
KERNEL_PATH=""      # 留空自动搜索 guest/images/bzImage
ROOTFS_PATH=""      # 留空自动搜索 guest/images/rootfs.ext4
```

### 4.2 cosim.sh resolve_kernel

```
1. $KERNEL 环境变量
2. config.env KERNEL_PATH
3. ${PROJECT_DIR}/guest/images/bzImage         ← 主路径
4. ${PROJECT_DIR}/guest/bzImage                ← 兼容
5. ~/workspace/buildroot/output/images/bzImage ← 兼容
6. ~/workspace/alpine-vmlinuz-new              ← 兼容
```

### 4.3 cosim.sh resolve_simv

```
1. $SIMV 环境变量
2. ${PROJECT_DIR}/vcs_sim/simv_vip             ← 新主路径
3. ${PROJECT_DIR}/build/simv_vip               ← 兼容旧
4. ${PROJECT_DIR}/vcs-tb/sim_build/simv        ← 兼容 legacy
5. ~/cosim-platform/vcs_sim/simv_vip           ← 兼容
```

### 4.4 setup.sh IMAGES_DIR

```bash
IMAGES_DIR="${PROJECT_DIR}/guest/images"
```

### 4.5 setup.sh VCS 产物检查

```bash
check_artifact "simv_vip (VCS)" "${PROJECT_DIR}/vcs_sim/simv_vip"
```

## 5. 日志统一

### 5.1 cosim.sh

```bash
# 旧
LOGDIR="/tmp/cosim_${phase}_$(date +%Y%m%d_%H%M%S)"
# 新
LOGDIR="${PROJECT_DIR}/logs/${phase}_$(date +%Y%m%d_%H%M%S)"
```

涉及函数：run_single_phase, run_dual_phase, run_tap_test, cmd_log

### 5.2 .gitignore

```
logs/
vcs_sim/
guest/images/
third_party/qemu/
third_party/glib-*/
third_party/buildroot-*/
*.fsdb
```

## 6. eth_tap_bridge 完善

setup.sh 编译后增强检查：
- 编译失败 → 打印依赖说明
- setcap 失败 → 明确提示"TAP 设备创建将失败"
- cosim.sh start tap 前检查 ETH SHM 是否存在

## 7. 端到端测试手册

### 7.1 Local SHM 模式

```
前置: ./setup.sh --mode local 完成

步骤 1: 启动 QEMU (终端 1)
  ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock \
      --serial-sock /tmp/qemu-serial.sock \
      --drive guest/images/rootfs.ext4
  预期: SHM /dev/shm/cosim0 创建

步骤 2: 启动 VCS (终端 2)
  ./cosim.sh start vcs --shm /cosim0 --sock /tmp/cosim0.sock
  预期: TLP polling 开始，波形 dump 到 vcs_sim/cosim_wave.fsdb

步骤 3: 启动 TAP bridge (终端 3)
  ./cosim.sh start tap --eth-shm /cosim_eth0
  前置: VCS 已创建 /dev/shm/cosim_eth0
  预期: TAP cosim0 IP 10.0.0.1/24

步骤 4: Guest 串口交互 (终端 4)
  python3 连接 /tmp/qemu-serial.sock
  执行: root → ip addr add 10.0.0.2/24 dev eth0 → ip link set eth0 up
       → arp -s 10.0.0.1 <TAP MAC>

步骤 5: 功能验证
  ping -c 5 -W 600 10.0.0.1  → 验证端到端数据面
  arping -c 3 -I eth0 10.0.0.1 → 验证 L2

步骤 6: 清理
  ./cosim.sh clean
```

### 7.2 TCP 跨机模式

```
步骤 1: QEMU 机器 → ./cosim.sh start qemu --transport tcp --port-base 9100 ...
步骤 2: VCS 机器  → ./cosim.sh start vcs --transport tcp --remote-host <IP> ...
步骤 3: VCS 机器  → ./cosim.sh start tap --eth-shm /cosim_eth0
步骤 4-6: 同 Local
```

## 8. 文件变更清单

| 文件 | 变更 |
|------|------|
| Makefile | VCS_SIM_DIR := vcs_sim, -o 路径变更 |
| setup.sh | buildroot 构建流程, IMAGES_DIR, VCS 产物路径 |
| cosim.sh | resolve_kernel/simv 路径, 日志改 logs/, log 命令 |
| config.env | 新增 KERNEL_PATH / ROOTFS_PATH |
| .gitignore | logs/ vcs_sim/ guest/images/ third_party/* |
| guest/buildroot_defconfig | 新建 |
| docs/SETUP-GUIDE.md | 更新所有路径和测试流程 |

## 9. 不影响 TCP 模式保证

- 不修改 bridge/ qemu-plugin/ vcs-tb/ pcie_tl_vip/ 的任何代码
- resolve 函数新增路径但保留所有旧路径兼容
- Makefile VCS_SIM_DIR 只影响 simv_vip 输出位置
- 日志路径变更只影响输出位置
