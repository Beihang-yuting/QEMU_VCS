# QEMU 侧 TCP 启动流程集成 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `cosim.sh start qemu` 支持 TCP transport 和磁盘镜像启动，使 setup.sh 提示的跨机命令能实际执行。

**Architecture:** 修改 `cosim.sh` 的 `cmd_start_qemu` 函数，新增 `--transport`/`--port-base`/`--instance-id`/`--drive` 参数，根据 transport 类型切换 `-device` 属性；同步更新帮助文本和 `setup.sh` 安装摘要中的使用提示。

**Tech Stack:** Bash (cosim.sh, setup.sh)

---

## 文件变更清单

| 操作 | 文件 | 变更内容 |
|------|------|---------|
| Modify | `cosim.sh:982-1031` | `cmd_start_qemu` 新增 TCP + drive 参数和分支逻辑 |
| Modify | `cosim.sh:306-309` | `show_help` 更新 start qemu 选项说明 |
| Modify | `cosim.sh:324-329` | `show_help` 更新示例 |
| Modify | `setup.sh:1093-1124` | 安装摘要中的使用方法提示 |

---

### Task 1: `cmd_start_qemu` 支持 TCP transport 和磁盘镜像

**Files:**
- Modify: `cosim.sh:982-1031`

- [ ] **Step 1: 替换 `cmd_start_qemu` 函数**

将 `cosim.sh` 第 982-1031 行的 `cmd_start_qemu` 函数替换为以下实现：

```bash
cmd_start_qemu() {
    local transport="shm"
    local shm_name="/cosim0"
    local sock_path="/tmp/cosim0.sock"
    local port_base="9100"
    local instance_id="0"
    local initrd_file=""
    local drive_file=""
    local extra_append=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --transport)   transport="$2"; shift 2 ;;
            --shm)         shm_name="$2"; shift 2 ;;
            --sock)        sock_path="$2"; shift 2 ;;
            --port-base)   port_base="$2"; shift 2 ;;
            --instance-id) instance_id="$2"; shift 2 ;;
            --initrd)      initrd_file="$2"; shift 2 ;;
            --drive)       drive_file="$2"; shift 2 ;;
            --append)      extra_append="$2"; shift 2 ;;
            *) log_err "未知选项: $1"; return 1 ;;
        esac
    done

    # 参数校验
    case "$transport" in
        shm|tcp) ;;
        *) log_err "无效 transport: $transport（可选: shm, tcp）"; return 1 ;;
    esac

    local qemu_bin
    qemu_bin="$(resolve_qemu)" || { log_err "找不到 QEMU"; return 1; }

    # ---- 构建 -device 参数 ----
    local device_arg
    if [ "$transport" = "tcp" ]; then
        device_arg="cosim-pcie-rc,transport=tcp,port_base=$port_base,instance_id=$instance_id"
    else
        device_arg="cosim-pcie-rc,shm_name=$shm_name,sock_path=$sock_path"
    fi

    # ---- 构建 QEMU 命令行 ----
    local QEMU_ARGS=(
        -M q35 -m "${GUEST_MEMORY}" -smp 1
        -device "$device_arg"
        -nographic -no-reboot
    )

    # ---- Guest 启动方式: drive 模式 vs initramfs 模式 ----
    local append_str="console=ttyS0"

    if [ -n "$drive_file" ]; then
        # 磁盘镜像模式 (full guest)
        if [ ! -f "$drive_file" ]; then
            log_err "磁盘镜像不存在: $drive_file"
            return 1
        fi
        # 自动检测格式
        local drive_fmt="raw"
        case "$drive_file" in
            *.qcow2) drive_fmt="qcow2" ;;
            *.img)   drive_fmt="qcow2" ;;
        esac
        QEMU_ARGS+=(-drive "file=$drive_file,format=$drive_fmt,if=virtio")
        append_str="${append_str} root=/dev/vda"

        # kernel 可选：有则用，无则依赖镜像内置引导
        local kernel_bin
        kernel_bin="$(resolve_kernel 2>/dev/null)" || true
        if [ -n "$kernel_bin" ]; then
            QEMU_ARGS+=(-kernel "$kernel_bin")
        fi
    else
        # initramfs 模式 (minimal guest)
        local kernel_bin
        kernel_bin="$(resolve_kernel)" || { log_err "找不到 kernel"; return 1; }
        QEMU_ARGS+=(-kernel "$kernel_bin")

        if [ -z "$initrd_file" ]; then
            initrd_file="$(resolve_initrd "")" || true
        fi
        if [ -n "$initrd_file" ] && [ -f "$initrd_file" ]; then
            QEMU_ARGS+=(-initrd "$initrd_file")
        fi
        append_str="${append_str} init=/init"
    fi

    # 附加 append 参数
    [ -n "$extra_append" ] && append_str="${append_str} ${extra_append}"
    QEMU_ARGS+=(-append "$append_str")

    # ---- KVM 检测 ----
    if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
        QEMU_ARGS+=(-cpu host -enable-kvm)
        log_info "KVM 加速已启用"
    else
        QEMU_ARGS+=(-cpu max)
        log_warn "KVM 不可用，使用 TCG（较慢）"
    fi

    # ---- 启动信息 ----
    log_info "启动 QEMU..."
    log_info "  Transport: $transport"
    if [ "$transport" = "tcp" ]; then
        log_info "  端口基数: $port_base (占用 ${port_base}-$((port_base + 2)))"
        log_info "  实例 ID:  $instance_id"
        log_info "  提示: QEMU 将监听端口等待 VCS 连接，启动后终端无输出是正常的"
    else
        log_info "  SHM:    $shm_name"
        log_info "  Socket: $sock_path"
    fi
    if [ -n "$drive_file" ]; then
        log_info "  磁盘:   $drive_file"
    fi
    [ -n "${kernel_bin:-}" ] && log_info "  Kernel: $kernel_bin"
    [ -n "$initrd_file" ] && [ -f "$initrd_file" ] && log_info "  Initrd: $initrd_file"

    exec "$qemu_bin" "${QEMU_ARGS[@]}"
}
```

- [ ] **Step 2: 验证 SHM 模式不受影响**

```bash
cd /home/ubuntu/ryan/software/cosim-platform
bash -n cosim.sh && echo "语法检查通过"
```

Expected: `语法检查通过`

---

### Task 2: 更新 `show_help` 帮助文本

**Files:**
- Modify: `cosim.sh:306-329`

- [ ] **Step 1: 更新 start qemu 选项说明**

将 `cosim.sh` 第 306-309 行：

```
  start <组件>      启动单个组件
    qemu [--shm NAME] [--sock PATH] [--initrd FILE]
    vcs  [--role A|B] [--eth-shm NAME] [--mac-last N]
    tap  [--eth-shm NAME] [--ip ADDR] [--tap-dev NAME]
```

替换为：

```
  start <组件>      启动单个组件
    qemu [选项]       SHM: --shm NAME --sock PATH
                      TCP: --transport tcp [--port-base N] [--instance-id N]
                      Guest: --initrd FILE 或 --drive FILE [--append ARGS]
    vcs  [--role A|B] [--eth-shm NAME] [--mac-last N]
    tap  [--eth-shm NAME] [--ip ADDR] [--tap-dev NAME]
```

- [ ] **Step 2: 更新示例部分**

将 `cosim.sh` 第 324-329 行：

```
示例:
  ./cosim.sh test phase1              # 运行 Phase 1 测试
  ./cosim.sh test all                 # 运行所有测试
  ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock
  ./cosim.sh status                   # 查看运行状态
  ./cosim.sh clean                    # 清理所有资源
```

替换为：

```
示例:
  ./cosim.sh test phase1              # 运行 Phase 1 测试
  ./cosim.sh test all                 # 运行所有测试
  ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock     # SHM 本地模式
  ./cosim.sh start qemu --transport tcp --port-base 9100           # TCP 跨机模式
  ./cosim.sh start qemu --transport tcp --drive rootfs.ext4        # TCP + 磁盘镜像
  ./cosim.sh status                   # 查看运行状态
  ./cosim.sh clean                    # 清理所有资源
```

- [ ] **Step 3: 语法检查**

```bash
bash -n cosim.sh && echo "语法检查通过"
```

---

### Task 3: 更新 `setup.sh` 安装摘要中的使用提示

**Files:**
- Modify: `setup.sh:1093-1124`

- [ ] **Step 1: 替换使用方法部分**

将 `setup.sh` 第 1093-1124 行替换为：

```bash
echo ""
echo -e "${BOLD}-------- 使用方法 --------${NC}"
case "$SETUP_MODE" in
    local)
        echo "  运行仿真（自动编排 QEMU + VCS）:"
        echo "    ./cosim.sh test phase4     # Phase 4: 双向 Ping 测试"
        echo "    ./cosim.sh test phase5     # Phase 5: iperf 吞吐测试"
        echo "    ./cosim.sh test tap        # TAP 桥接测试"
        echo ""
        echo "  手动启动单个组件:"
        echo "    ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock"
        echo "    ./cosim.sh start vcs  --shm /cosim0 --sock /tmp/cosim0.sock --role A"
        ;;
    qemu-only)
        echo "  启动 QEMU 侧（TCP server，监听等待 VCS 连接）:"
        if [ "$GUEST_TYPE" = "minimal" ]; then
            echo "    ./cosim.sh start qemu --transport tcp --port-base 9100"
        else
            echo "    ./cosim.sh start qemu --transport tcp --port-base 9100 \\"
            echo "        --drive ${IMAGES_DIR}/cosim-guest.qcow2"
        fi
        echo ""
        echo "  提示:"
        echo "    - QEMU 启动后阻塞等待 VCS 连接（端口 9100-9102），终端无输出是正常的"
        echo "    - 确认防火墙已放行 TCP 9100-9102"
        echo "    - 本机 TCP 测试: VCS 用 --remote-host 127.0.0.1"
        echo ""
        echo "  远程 VCS 机器需运行:"
        echo "    ./setup.sh --mode vcs-only"
        echo "    ./cosim.sh start vcs --transport tcp --remote-host <本机IP> --port-base 9100"
        ;;
    vcs-only)
        echo "  启动 VCS 侧（TCP client，连接远程 QEMU）:"
        echo "    ./cosim.sh start vcs --transport tcp --remote-host <QEMU机器IP> --port-base 9100"
        echo ""
        echo "  远程 QEMU 机器需先启动:"
        echo "    ./setup.sh --mode qemu-only --guest minimal"
        echo "    ./cosim.sh start qemu --transport tcp --port-base 9100"
        echo ""
        echo "  提示:"
        echo "    - VCS 侧 connect 会自动重试 15 秒，请确保 QEMU 已在监听"
        echo "    - 启动顺序: 先 QEMU（listen）→ 再 VCS（connect）"
        ;;
esac
echo ""
echo "  重新编译:"
echo "    make bridge             # 仅重编译 bridge 库"
echo "    make test-unit          # 运行单元测试"
echo "    ./setup.sh              # 重新运行安装向导"
echo ""
```

- [ ] **Step 2: 语法检查**

```bash
bash -n setup.sh && echo "语法检查通过"
```

---

### Task 4: 验证完整流程

- [ ] **Step 1: 验证语法 + 帮助输出**

```bash
cd /home/ubuntu/ryan/software/cosim-platform
bash -n cosim.sh && echo "cosim.sh 语法OK"
bash -n setup.sh && echo "setup.sh 语法OK"
./cosim.sh help 2>&1 | head -30
```

确认帮助信息中包含 `--transport tcp` 和 `--drive` 选项。

- [ ] **Step 2: 验证参数校验（无效 transport）**

```bash
./cosim.sh start qemu --transport invalid 2>&1
```

Expected: `[错误] 无效 transport: invalid（可选: shm, tcp）`

- [ ] **Step 3: 验证 TCP 模式参数打印**

```bash
QEMU=/bin/false ./cosim.sh start qemu --transport tcp --port-base 9200 2>&1 | head -10
```

确认输出包含:
- `Transport: tcp`
- `端口基数: 9200`
- `提示: QEMU 将监听端口等待 VCS 连接`

- [ ] **Step 4: 提交**

```bash
git add cosim.sh setup.sh
git commit -m "feat: cosim.sh start qemu 支持 TCP transport 和磁盘镜像启动

- cmd_start_qemu 新增 --transport tcp/shm, --port-base, --instance-id, --drive, --append 参数
- TCP 模式: -device cosim-pcie-rc,transport=tcp,port_base=N,instance_id=N
- drive 模式: -drive file=X,format=raw/qcow2,if=virtio（支持 full guest）
- 更新 show_help 帮助文本，补充 TCP 和 drive 示例
- 更新 setup.sh 安装摘要，qemu-only/vcs-only 模式提示关键注意事项"
```
