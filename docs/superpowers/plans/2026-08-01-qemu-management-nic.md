# QEMU 默认管理网卡 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 默认给每个 `make run-qemu` Guest 加一张仅宿主机可访问的 e1000e 管理网卡，并把宿主 SSH 端口转发到 Guest 22 端口。

**Architecture:** Makefile 维护两个参数：`MGMT_NET=1|0` 决定是否加入管理网卡，`MGMT_SSH_PORT_BASE` 决定 RC0 的回环端口。单实例使用固定的 RC0 参数；多实例在现有 shell 循环中按 RC 编号生成唯一的网卡 ID、MAC 和端口。管理网络用 QEMU user-mode NAT，不进入 cosim PCIe、VCS 或 DUT 数据面。

**Tech Stack:** GNU Make、Bash、QEMU x86_64 `e1000e` 与 user-mode NAT、CTest。

---

## 文件结构

- `Makefile`：定义并验证管理网卡参数，在三种 `CONSOLE` 启动路径加入 QEMU 参数，并在帮助文本中说明使用方式。
- `tests/integration/test_qemu_management_nic.sh`：通过 `/bin/echo` 代替 QEMU，执行每种启动路径并检查真实展开后的参数。
- `tests/integration/CMakeLists.txt`：把脚本注册为 CTest。

### Task 1: 编写管理网卡启动参数的失败测试

**Files:**

- Create: `tests/integration/test_qemu_management_nic.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: 新建失败测试脚本**

```bash
#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "[qemu-management-nic] FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" <<<"$2" || fail "missing: $1"; }
assert_not_contains() { ! grep -Fq -- "$1" <<<"$2" || fail "unexpected: $1"; }

run_login() {
    make -s -C "$repo" run-qemu CONSOLE=login QEMU=/bin/echo KERNEL=/bin/true ROOTFS=/bin/true \
        LOG_DIR="$tmp/logs-login" RUN_DIR="$tmp/run-login" "$@"
}

for console in login-multi file; do
    logs="$tmp/logs-$console"
    make -s -C "$repo" run-qemu CONSOLE="$console" NUM_RC=2 QEMU=/bin/echo KERNEL=/bin/true ROOTFS=/bin/true \
        LOG_DIR="$logs" RUN_DIR="$tmp/run-$console"
    rc0="$(<"$logs/qemu_rc0.boot")"
    rc1="$(<"$logs/qemu_rc1.boot")"
    assert_contains 'id=mgmtnet0,hostfwd=tcp:127.0.0.1:2222-:22' "$rc0"
    assert_contains 'e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01' "$rc0"
    assert_contains 'id=mgmtnet1,hostfwd=tcp:127.0.0.1:2223-:22' "$rc1"
    assert_contains 'e1000e,netdev=mgmtnet1,mac=52:54:00:53:00:02' "$rc1"
done

login="$(run_login)"
assert_contains 'id=mgmtnet0,hostfwd=tcp:127.0.0.1:2222-:22' "$login"
assert_contains 'e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01' "$login"

disabled="$(run_login MGMT_NET=0)"
assert_not_contains 'mgmtnet' "$disabled"

make -s -C "$repo" validate-mgmt-net MGMT_NET=0
make -s -C "$repo" validate-mgmt-net MGMT_NET=1 MGMT_SSH_PORT_BASE=65535
if make -s -C "$repo" validate-mgmt-net MGMT_NET=2 >/dev/null 2>&1; then fail 'MGMT_NET=2 accepted'; fi
if make -s -C "$repo" validate-mgmt-net MGMT_SSH_PORT_BASE=0 >/dev/null 2>&1; then fail 'port 0 accepted'; fi
if make -s -C "$repo" validate-mgmt-net MGMT_SSH_PORT_BASE=65536 >/dev/null 2>&1; then fail 'port 65536 accepted'; fi
if injected_output="$(make -s -C "$repo" validate-mgmt-net 'MGMT_NET=1; echo MGMT_NET_INJECTED' 2>&1)"; then fail 'shell-injected MGMT_NET accepted'; fi
if [[ "$injected_output" == *MGMT_NET_INJECTED* ]]; then fail 'MGMT_NET executed injected shell content'; fi
if injected_output="$(make -s -C "$repo" validate-mgmt-net 'MGMT_SSH_PORT_BASE=2222; echo MGMT_PORT_INJECTED' 2>&1)"; then fail 'shell-injected MGMT_SSH_PORT_BASE accepted'; fi
if [[ "$injected_output" == *MGMT_PORT_INJECTED* ]]; then fail 'MGMT_SSH_PORT_BASE executed injected shell content'; fi

echo '[qemu-management-nic] PASS'
```

- [ ] **Step 2: 在 CTest 中注册该脚本**

在 `tests/integration/CMakeLists.txt` 的 `test_qemu_time_mode` 后加入：

```cmake
add_test(NAME test_qemu_management_nic
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_management_nic.sh)
set_tests_properties(test_qemu_management_nic PROPERTIES TIMEOUT 10)
```

- [ ] **Step 3: 执行测试，确认其因缺少功能而失败**

Run:

```bash
bash tests/integration/test_qemu_management_nic.sh
```

Expected: 失败并报出缺少 `id=mgmtnet0,hostfwd=tcp:127.0.0.1:2222-:22`；此时 Makefile 尚未定义管理网卡参数。

### Task 2: 在 Makefile 中实现默认管理网卡

**Files:**

- Modify: `Makefile:8-10, 54-74, 136-154, 166, 181-182, 216-217, 318-322`
- Test: `tests/integration/test_qemu_management_nic.sh`

- [ ] **Step 1: 增加变量和网卡参数模板**

在 `CONSOLE` 定义后加入下列文本。字面量覆盖避免 Make 函数执行；导出变量让验证 recipe 用安全的 shell 参数读取值。

```makefile
# 独立管理网卡：user-mode NAT，只允许 QEMU 宿主机经 127.0.0.1 SSH 到 guest。
# MGMT_NET=0 可关闭；RC r 的端口为 MGMT_SSH_PORT_BASE+r。
MGMT_NET           ?= 1
MGMT_SSH_PORT_BASE ?= 2222
override MGMT_NET := $(value MGMT_NET)
override MGMT_SSH_PORT_BASE := $(value MGMT_SSH_PORT_BASE)
export MGMT_NET MGMT_SSH_PORT_BASE
ifeq ($(MGMT_NET),1)
MGMT_NET_ARGS_RC0 := -netdev user,id=mgmtnet0,hostfwd=tcp:127.0.0.1:$(MGMT_SSH_PORT_BASE)-:22 -device e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01
MGMT_NET_ARGS_LOOP = -netdev user,id=mgmtnet$$r,hostfwd=tcp:127.0.0.1:$$(( $(MGMT_SSH_PORT_BASE) + r ))-:22 -device e1000e,netdev=mgmtnet$$r,mac=52:54:00:53:$$(printf '%02x:%02x' $$(( (r + 1) / 256 )) $$(( (r + 1) % 256 )))
else
MGMT_NET_ARGS_RC0 :=
MGMT_NET_ARGS_LOOP :=
endif
```

- [ ] **Step 2: 加入启动前验证并声明为依赖**

将 `.PHONY` 中的 `validate-qemu-time-mode` 改为 `validate-qemu-time-mode validate-mgmt-net`；在 `validate-qemu-time-mode` 后加入：

```makefile
validate-mgmt-net:
	@if ! printf '%s\n' "$$MGMT_NET" | grep -Eq '^[01]$$'; then \
		echo "[错误] MGMT_NET 必须是 0 或 1" >&2; \
		exit 1; \
	fi
	@if ! printf '%s\n' "$$MGMT_SSH_PORT_BASE" | grep -Eq '^[0-9]+$$' || \
		[ "$$MGMT_SSH_PORT_BASE" -lt 1 ] || [ "$$MGMT_SSH_PORT_BASE" -gt 65535 ]; then \
		echo "[错误] MGMT_SSH_PORT_BASE 必须是 1..65535" >&2; \
		exit 1; \
	fi
```

并把 target 声明改为：

```makefile
run-qemu: validate-pcie-pref64-reserve validate-qemu-time-mode validate-mgmt-net
```

- [ ] **Step 3: 在三种启动路径插入网卡参数**

在 `CONSOLE=login` 的 `-append ...` 行后插入：

```makefile
		$(MGMT_NET_ARGS_RC0) \
```

在 `CONSOLE=login-multi` 与 `CONSOLE=file` 各自循环中的 `-append ...` 行后插入：

```makefile
			$(MGMT_NET_ARGS_LOOP) \
```

不要改变原有 `pcie-root-port` 或 `cosim-pcie-rc` 参数的顺序和内容。

- [ ] **Step 4: 更新帮助文本**

在 `help` target 的参数区加入：

```makefile
	@echo "  MGMT_NET=1              默认加 e1000e 管理网卡；0=关闭（不经过 DUT/VCS）"
	@echo "  MGMT_SSH_PORT_BASE=2222 管理 SSH 端口基数；RC r 使用 127.0.0.1:(base+r)"
```

- [ ] **Step 5: 再次运行新增测试，确认通过**

Run:

```bash
bash tests/integration/test_qemu_management_nic.sh
```

Expected: `[qemu-management-nic] PASS`。两条多实例启动记录分别含端口 2222/2223、唯一的网卡 ID 和 MAC；关闭选项不含 `mgmtnet`。

### Task 3: 回归、实机验证与提交

**Files:**

- Modify: `Makefile`, `tests/integration/CMakeLists.txt`, `tests/integration/test_qemu_management_nic.sh`

- [ ] **Step 1: 运行本地启动参数回归**

Run:

```bash
bash tests/integration/test_qemu_management_nic.sh
bash tests/integration/test_qemu_time_mode.sh
bash tests/integration/test_pcie_launch_topology.sh
make -n run-qemu QEMU=/bin/true KERNEL=/bin/true ROOTFS=/bin/true
```

Expected: 三个脚本打印 `PASS`；最后一个命令只产生默认管理网卡的 QEMU 命令，不实际启动 QEMU。

- [ ] **Step 2: 在 53 上验证 QEMU 接受管理网卡参数**

Run on `10.11.10.53` in a bash login shell:

```bash
cd /home/ubuntu/test_cosim/qemu-icount-validate-20260731
QEMU=third_party/qemu/build/qemu-system-x86_64
"$QEMU" -M q35 -display none -nodefaults -S \
  -netdev user,id=mgmtnet0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01 \
  -monitor stdio
```

At the QEMU monitor, run `quit`.

Expected: QEMU starts without an unknown `netdev`/`e1000e` property error and exits cleanly.

- [ ] **Step 3: 检查差异并提交实现**

Run:

```bash
git diff --check
git status --short
git add Makefile tests/integration/CMakeLists.txt tests/integration/test_qemu_management_nic.sh
git commit -m "feat: add default qemu management NIC"
```

Expected: 无空白错误，提交仅包含三个实现文件；设计与计划文档维持独立提交。
