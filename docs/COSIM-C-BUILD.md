# CoSim C 侧编库说明 — 编成库给你自己的 UVM/VCS flow 链接

cosim 桥的 C 侧(DPI 实现 + SHM/TCP transport)编成 `libcosim_bridge.a`(静态)+
`libcosim_bridge.so`(共享)。链进你自己的 VCS flow,两条路子(见 §2)。

> **别和 `make bridge` 搞混**:`make bridge` 走 CMake,产的是给 **QEMU** dlopen 的
> `libcosim_bridge.so`(qemu/ 侧)和一个**只含 `bridge_vcs.c`+`sock_sync_vcs.c`、不含
> eth/virtqueue DPI 的** `libcosim_bridge_vcs.so`。**给外部 UVM 集成用完整库,走下面的
> `make cosim-lib`**,不要用 `make bridge` 的产物 —— 否则 UVM 一旦 import
> `vcs_eth_mac_*` / `vcs_vq_*` 就会运行期找不到函数。

---

## 1. 编库 — 一条命令

```bash
make cosim-lib                                              # PCIe MMIO/DMA/MSI DPI(纯 gcc 可编)
make cosim-lib-eth COSIM_CC=$VCS_HOME/.../gcc               # 追加完整 ETH/virtqueue DPI
```

产物落在 `build/lib/libcosim_bridge.{a,so}`。改了 `bridge/*.c` 后重跑即重编。
底层是 `scripts/build_cosim_lib.sh`(想自定义 `OUT=`/`CC=` 可直接调它)。

> ⚠️ **`cosim-lib-eth` 需要 VCS 头**:`eth_mac_dpi.c` 用了 `svGetArrayPtr`(`svdpi.h`)。
> 必须设 `VCS_HOME` 并用 VCS 自带 gcc(`COSIM_CC=$VCS_HOME/.../gcc`),脚本会自动加
> `-I $VCS_HOME/include`。纯 gcc 编 eth 版会报 `svdpi.h: No such file`。基础 `make cosim-lib`
> 不涉 svdpi,任意 gcc 可编。

---

## 2. 链进 VCS — 两条路子(任选其一)

DPI 声明恒在 SV 侧:无论哪条,`bridge/vcs/bridge_vcs.sv`(`cosim_bridge_pkg`)都要编进 simv。

### 路子 1(推荐)—— `.so` + `-sv_lib`

```bash
vcs ... -sv_lib build/lib/libcosim_bridge \
        bridge/vcs/bridge_vcs.sv  <你的 uvm 文件...>
export LD_LIBRARY_PATH=build/lib:$LD_LIBRARY_PATH   # 跑 simv 前确保 .so 可被找到
```
`-sv_lib <path>/libcosim_bridge` 加载 `<path>/libcosim_bridge.so`(去 `.so` 后缀,留 `lib` 前缀)。
DPI 走 dlsym 全量导出,**无 strip 问题** —— 「运行期找不到 C 函数」最省心的解法。

### 路子 2(备选)—— `.a` + `--whole-archive`

```bash
vcs ... -CFLAGS "-I $PWD/bridge/common -I $PWD/bridge/vcs" \
        -LDFLAGS "-Wl,--whole-archive $PWD/build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \
        bridge/vcs/bridge_vcs.sv  <你的 uvm 文件...>
```
> ⚠️ **静态库必须 `--whole-archive`**。DPI-C 函数由 VCS 运行期查表调用,simv 链接阶段没有普通 C
> 符号引用它们,ld 会把 `bridge_vcs.o` 等归档成员当死代码丢掉 —— simv 照样编过,但**运行期报
> 「找不到 C 函数」**。普通 `-lcosim_bridge`(哪怕带 `--no-as-needed`)不解决 ——
> `--no-as-needed` 只管共享库,不管归档成员筛选。嫌麻烦就用路子 1。

---

## 3. 编译标志 & ABI(脚本已内置,手敲时照抄)

| 标志 | 为什么 |
|---|---|
| `-std=gnu11`(或 `c99`/`gnu99`) | 代码用 C99 `for(int i...)`;VCS gcc 默认 C89 报 `'for' loop initial declarations` |
| `-D_DEFAULT_SOURCE` | `usleep` 等 POSIX 声明(`-std=c11` 下默认关) |
| `-fPIC` | 进 DPI 共享对象 |
| 链接 `-lrt -lpthread` | POSIX SHM + 线程 |

> **ABI 关键**:编库的 gcc 要和 VCS 用的 gcc ABI 兼容。最稳 —— `COSIM_CC=$VCS_HOME/.../gcc`,
> 或让 VCS inline 编(§5)。

---

## 4. 手敲等价命令(不想用 make 时的参考)

要编的 `.c`(相对 `<cosim-platform>/`;`eth_shm.c` 必带,否则 `undefined reference to eth_shm_*`):

```bash
SRCS="bridge/vcs/bridge_vcs.c bridge/vcs/sock_sync_vcs.c
      bridge/common/shm_layout.c bridge/common/ring_buffer.c
      bridge/common/dma_manager.c bridge/common/trace_log.c
      bridge/common/transport_shm.c bridge/common/transport_tcp.c
      bridge/common/eth_shm.c"
INCS="-I bridge/common -I bridge/vcs -I bridge/qemu -I bridge/eth"
mkdir -p build/lib
gcc -std=gnu11 -D_DEFAULT_SOURCE -O2 -fPIC $INCS -c $SRCS && mv *.o build/lib/
ar    rcs build/lib/libcosim_bridge.a  build/lib/*.o          # .a
gcc -shared -o build/lib/libcosim_bridge.so build/lib/*.o -lrt -lpthread   # .so
```
> 完整 eth 数据面(`link_model` / `eth_mac_dpi` / `eth_port` / `virtqueue_dma`)MMIO-only 不需要;
> 需要时加进 `SRCS`,或直接 `make cosim-lib-eth`。

---

## 5. inline 让 VCS 编(不产库,ABI 最稳)

把 `.c` 直接丢给 `vcs`,VCS 用自己的 gcc 编+链,天然无 strip、无 ABI 问题:
```bash
vcs ... -cc gcc -CFLAGS "-std=gnu11 -D_DEFAULT_SOURCE $INCS" \
        -LDFLAGS "-Wl,--no-as-needed -lrt -lpthread" \
        bridge/vcs/bridge_vcs.sv $SRCS <你的 uvm 文件...>
```
`scripts/build_cosim_multirc.sh` 走的就是这条(2-RC over Xilinx-AXIS,已在 61 实测)。

---

## 6. 自检

```bash
# .so 里 DPI 符号导出(路子 1;应见 'T bridge_vcs_init')
nm -D build/lib/libcosim_bridge.so | grep -E " T (bridge_vcs_init|bridge_vcs_poll_tlp_scalar)$"
# .a 里符号齐(路子 2;应见 _rc 入口)
nm build/lib/libcosim_bridge.a | grep -E "bridge_vcs_(init_ex_rc|poll_tlp_scalar_rc)"
# 最终 simv 里 DPI 符号在不在(路子 2 漏 --whole-archive 时为空)
nm simv 2>/dev/null | grep -E " [Tt] bridge_vcs_init$"
```
- 链接期 `undefined reference to eth_shm_*` → 漏了 `eth_shm.c`
- 链接期 `'for' loop initial declarations` → 漏了 `-std=gnu11`
- 链接期 `usleep` 隐式声明 → 漏了 `-D_DEFAULT_SOURCE`
- **运行期**「找不到 C 函数 / cannot find DPI-C function」→ 路子 2 漏了 `--whole-archive`(§2),
  或库里根本没这函数(用了 `make bridge` 那个缺 eth/vq 的 `.so`,见文首告示)
