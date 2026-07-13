# CoSim C 侧编库说明 — 编成库直接吃

cosim 桥的 C 侧(DPI 实现 + SHM/TCP transport)编成静态库 `libcosim_bridge.a`
或共享库 `.so`,链进你自己的 VCS flow;也可 inline 让 VCS 直接编。

---

## 1. 要编哪些 .c(PCIe MMIO 通路)

相对 `<cosim-platform>/`:

```
bridge/vcs/bridge_vcs.c          # DPI 实现(含全部 _rc 多 RC 入口)
bridge/vcs/sock_sync_vcs.c       # 时钟步同步 socket(内含 ../qemu/sock_sync.c)
bridge/common/shm_layout.c
bridge/common/ring_buffer.c
bridge/common/dma_manager.c
bridge/common/trace_log.c
bridge/common/transport_shm.c    # SHM transport
bridge/common/transport_tcp.c    # TCP transport(跨机)
bridge/common/eth_shm.c          # 必带:transport_shm.c 依赖 eth_shm_* 符号
```

> `eth_shm.c` 必须带,否则链接期 `undefined reference to eth_shm_*`。
> 完整 eth 数据面(link_model / eth_mac_dpi / eth_port / virtqueue_dma)MMIO-only 不需要。

**头文件包含路径:**
```
-I bridge/common  -I bridge/vcs  -I bridge/qemu  -I bridge/eth
```

---

## 2. 编译标志(必须)

| 标志 | 为什么 |
|---|---|
| `-std=gnu11`(或 `-std=c99`/`gnu99`) | 代码用 C99 的 `for(int i...)`;VCS 自带 gcc 默认 C89 会报 `'for' loop initial declarations` |
| `-D_DEFAULT_SOURCE` | `usleep` 等 POSIX 声明(`-std=c11` 下默认关) |
| `-fPIC` | 进 DPI 共享对象 |
| 链接:`-lrt -lpthread` | POSIX SHM + 线程 |
| 链接:`-Wl,--no-as-needed` | 防 librt 被优化掉 |

> **ABI 关键**:编库的 gcc 要和 VCS 用的 gcc ABI 兼容。最稳 —— 用 VCS 自带 gcc,或让 VCS inline 编(方式 C)。

---

## 3. 方式 A — 静态库 `.a`(推荐,最贴合你自己的 flow)

一条脚本(已在仓里,基础集含 eth_shm):
```bash
cd <cosim-platform>
CC=gcc OUT=./build/lib ./scripts/build_cosim_lib.sh          # 默认 PCIe MMIO
./scripts/build_cosim_lib.sh --with-eth                       # 追加完整 eth
```

或手敲等价命令:
```bash
cd <cosim-platform>
mkdir -p build/lib
CFLAGS="-std=gnu11 -D_DEFAULT_SOURCE -O2 -fPIC -Wall"
INCS="-I bridge/common -I bridge/vcs -I bridge/qemu -I bridge/eth"
for f in bridge/vcs/bridge_vcs.c bridge/vcs/sock_sync_vcs.c \
         bridge/common/shm_layout.c bridge/common/ring_buffer.c \
         bridge/common/dma_manager.c bridge/common/trace_log.c \
         bridge/common/transport_shm.c bridge/common/transport_tcp.c \
         bridge/common/eth_shm.c; do
  gcc $CFLAGS $INCS -c "$f" -o "build/lib/$(basename ${f%.c}).o"
done
ar rcs build/lib/libcosim_bridge.a build/lib/*.o
```

**链进 VCS:**
```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    -CFLAGS "-I <cosim-platform>/bridge/common -I <cosim-platform>/bridge/vcs" \
    -LDFLAGS "-L<cosim-platform>/build/lib -lcosim_bridge -Wl,--no-as-needed -lrt -lpthread" \
    <cosim-platform>/bridge/vcs/bridge_vcs.sv  <你的 uvm 文件...>
```

---

## 4. 方式 B — 共享库 `.so` + DPI 标准加载

```bash
cd <cosim-platform>
gcc -std=gnu11 -D_DEFAULT_SOURCE -shared -fPIC \
    -I bridge/common -I bridge/vcs -I bridge/qemu -I bridge/eth \
    bridge/vcs/bridge_vcs.c bridge/vcs/sock_sync_vcs.c \
    bridge/common/shm_layout.c bridge/common/ring_buffer.c \
    bridge/common/dma_manager.c bridge/common/trace_log.c \
    bridge/common/transport_shm.c bridge/common/transport_tcp.c \
    bridge/common/eth_shm.c \
    -lrt -lpthread -o build/lib/libcosim_bridge.so
```
```bash
vcs ... -sv_lib build/lib/cosim_bridge   -LDFLAGS "-lrt -lpthread"   # 注意 -sv_lib 去掉 lib/.so
# 运行时确保 libcosim_bridge.so 在 LD_LIBRARY_PATH
```

---

## 5. 方式 C — inline 让 VCS 编(ABI 最稳,不产库)

把 .c 直接丢给 `vcs`,VCS 用它自己的 gcc 编 + 链:
```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -cc gcc \
    -CFLAGS "-std=gnu11 -D_DEFAULT_SOURCE -I <c>/bridge/common -I <c>/bridge/vcs -I <c>/bridge/qemu" \
    -LDFLAGS "-Wl,--no-as-needed -lrt -lpthread" \
    <c>/bridge/vcs/bridge_vcs.sv \
    <c>/bridge/vcs/bridge_vcs.c <c>/bridge/vcs/sock_sync_vcs.c \
    <c>/bridge/common/shm_layout.c <c>/bridge/common/ring_buffer.c \
    <c>/bridge/common/dma_manager.c <c>/bridge/common/trace_log.c \
    <c>/bridge/common/transport_shm.c <c>/bridge/common/transport_tcp.c \
    <c>/bridge/common/eth_shm.c \
    <你的 uvm 文件...>
```
`scripts/build_cosim_multirc.sh` 走的就是这条(已在 61 实测编过)。

---

## 6. 三种方式怎么选

| 方式 | 何时用 | 注意 |
|---|---|---|
| A `.a` | 想把 cosim 当库丢进你现有 flow | 编库 gcc 要与 VCS gcc ABI 兼容 |
| B `.so` | 想运行时解耦、多 simv 共享 | 管好 `-sv_lib` + `LD_LIBRARY_PATH` |
| C inline | 最省心、ABI 最稳 | 不产库文件,每次随 simv 编 |

DPI 声明恒在 SV 侧:无论哪种,`bridge/vcs/bridge_vcs.sv`(`cosim_bridge_pkg`)都要编进 simv。

---

## 7. 自检

```bash
# 库里符号都在(应见 bridge_vcs_poll_tlp_scalar_rc 等 _rc 入口)
nm build/lib/libcosim_bridge.a | grep -E "bridge_vcs_(init_ex_rc|poll_tlp_scalar_rc|send_cpl_scalar_rc)"
```
链接期若报 `undefined reference to eth_shm_*` → 漏了 `eth_shm.c`。
若报 `'for' loop initial declarations` → 漏了 `-std=gnu11`。
若报 `usleep` 隐式声明 → 漏了 `-D_DEFAULT_SOURCE`。
