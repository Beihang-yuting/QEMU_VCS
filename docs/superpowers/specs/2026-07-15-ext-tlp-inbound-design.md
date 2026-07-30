# DUT 入向扩展 TLP(DMA/Atomic/IO)+ per-RC 设计

**日期:** 2026-07-15
**分支:** `feature/ext-tlp-inbound`(off `main`/sriov)
**状态:** 设计草案,待用户 review

---

## Goal

让 **DUT(RTL)作为 requester** 在 RQ 通道产生扩展 TLP —— **入向 DMA MRd/MWr + AtomicOp(FetchAdd/Swap/CAS)+ IO(IORd/IOWr)** —— 经 cosim_xrc 适配层 → DPI → QEMU 服务(读写 / 原子 RMW / IO)→ 把结果(读值 / 原子原值)作为 **Completion(CplD/Cpl)回投给 DUT**。整条路径 **per-RC**(配现有 2-RC cosim_xrc)。**Msg 不在本轮**(需补 RQ 编解码,难,另起)。

## 决策(已定)

| 项 | 定论 |
|---|---|
| 结构方案 | **选项 A** —— 扩 `dma_req_t` 加 op-code + op_size + space;operand/返回值走现成 `DMA_DATA` 帧(不塞进定长结构) |
| 激励源 | **真 VIP RQ sequence**(pcie_tl_atomic_seq / io_seq / mem_seq 挂 RQ driver 产真 AtomicOp/IO/MRd/MWr) |
| 验证 | **C 单测 + SV e2e 两层**;atomic 原值由 **SV scoreboard** 对,guest 不需可见 |
| 范围 | **阶段0(DMA MRd/MWr)+ 阶段1(Atomic + IO)**,per-RC;Msg 阶段2 另起 spec |
| atomic 目标 | guest **RAM**(device bus-master AS);MMIO/IO 区原子语义不覆盖 |
| 路由 | **per-RC**(每 `-device cosim-pcie-rc` 一条),先不做 per-function(requester_id)路由 |

## 背景:入向现状(已复核)

- **入向 DMA MRd/MWr 服务链路今天已跑通**:`dma_req_t{tag,direction=READ/WRITE,host_addr,len,dma_offset}`(cosim_types.h:118-129,`_Static_assert==32B`)→ `irq_poller` 后台线程收 `SYNC_MSG_DMA_REQ` → `cosim_dma_cb`(cosim_pcie_rc.c:129-182):WRITE→`recv_dma_data`+`pci_dma_write`(device AS,触发 MSI);READ→`cpu_physical_memory_read`(raw RAM AS)→`bridge_complete_dma_with_data`(bridge_qemu.c:168-185)经 `DMA_DATA` 帧回数据。VCS 侧 `dma_read_sync`(bridge_vcs.c:545)阻塞等 `DMA_CPL`,`recv_dma_cpl`+`recv_dma_data` 拿回字节。**"completion 带 payload 回投"在入向 READ 已验证** —— `DMA_DATA` 帧就是现成"回值"载体,可直接复用回 atomic 原值。
- **唯一断流点:** `cosim_xrc_driver.sv:228-234` rx_loop 把所有非-Cpl 请求 `inbound_req_count++` 后**直接丢弃**打印 "DMA path TODO, dropping"。
- **解码已够(除 Msg):** `xilinx_desc_codec::decode_rq` 从 `req_type[3:0]` 正确解出 `.kind`(TLP_MEM_RD/WR/IO_RD/WR/ATOMIC_FETCHADD/SWAP/CAS,codec:49-69),`xilinx_req_type_e` 已定义 FETCH_ADD/SWAP/CAS/IORD/IOWR(types:51-64)。**但 decode_rq 一律返回 `pcie_tl_mem_tlp`**(codec:295,305)—— 即 atomic/IO 回来的对象 `.kind` 对但**不是** `pcie_tl_atomic_tlp`/`io_tlp`,`$cast` 会失败;operand 数据在 `mem_tlp.payload`。**driver 必须按 `.kind` 分派,不能靠 `$cast` 子类型。**
- **完成回投链路已通:** RC 角色下 RC-AXIS 是 AXIS_MASTER,`router.get_tx_channel(Cpl)→XILINX_CH_RC`,`encode_rc` 已完整编 CplD(lower_addr/byte_count/cpl_status/回显 requester_id+tag)。driver 只要 build `pcie_tl_cpl_tlp` 再 `send_tlp` 即把 CplD 打回 DUT。**入向完成在 SV 侧构建,不经 C 的 `cpl_entry_t`**(那是出向 QEMU-read 的完成),故 `send_completion_ctx` 硬编码 TLP_CPL 的限制**不阻塞入向**。
- **per-RC 缺口:** 入向 DMA 全硬编码 `g_rc[0]`(bridge_vcs.c:480/552/581/696…),只 RC0 能入向。需新 `_rc` 发起 DPI 用 `g_rc[rc].transport` + `tlp_cache_push_ctx(&g_rc[rc],…)`。

## 架构(选项 A,入向)

```
 DUT(RTL, requester) ──AtomicOp/IO/MRd/MWr TLP──▶ RQ AXIS 通道
   │ (真 VIP RQ sequence 产)
   ▼
 xilinx_pcie_if_adapter: decode_rq → pcie_tl_mem_tlp(.kind 已对)→ rx_queue
   ▼
 cosim_xrc_driver.rx_loop(替换 228-234 的 drop):
   按 rx_tlp.kind 分派:
     MEM_WR → 取 payload → bridge_vcs_dma_write_rc(rc,addr,data,len)   [posted, 不回]
     MEM_RD → bridge_vcs_dma_read_rc(rc,addr,len)→data → build CplD → send_tlp  [回 CplD]
     ATOMIC_* → 按 kind+len 解 operand(FetchAdd/Swap:1;CAS:compare+swap)
                → bridge_vcs_atomic_request_rc(rc,op,op_size,addr,operands)→old
                → build CplD(old value)→ send_tlp                         [回 CplD]
     IO_RD  → bridge_vcs_io_request_rc(rc,0,io_addr,first_be)→data → CplD  [回 CplD]
     IO_WR  → bridge_vcs_io_request_rc(rc,1,io_addr,data,first_be)         → 回 Cpl(status) [non-posted]
   ▼ DPI(_rc, 阻塞式,照 dma_read_sync 骨架)
 bridge_vcs.c: 组扩展 dma_req_t(op-code/op_size/space)+ operand 走 DMA_DATA
   → g_rc[rc].transport.send → 等 DMA_CPL + DMA_DATA(返回值)
   ▼ transport(TCP 9100 / SHM)
 QEMU cosim_dma_cb(按 op-code 分派):
   PLAIN RW → 今天的 pci_dma_write / cpu_physical_memory_read(不变)
   ATOMIC   → QEMU 原子访问器 在 device AS 上 4B/8B RMW:读 old→算 new→写回→回 old
   IO       → address_space_io 服务(或 sink+固定 Cpl)
   → bridge_complete_dma_with_data(DMA_DATA 回读值/原值)+ dma_cpl(tag/status)
```

## 组件 / 逐层改动

### 1. `bridge/common/cosim_types.h` —— 扩 `dma_req_t`(选项 A)
在 `dma_req_t` 加字段(破坏现 32B `_Static_assert`,**双端重编红线**):
- `uint8_t  op;`      // DMA_OP_PLAIN / FETCHADD / SWAP / CAS / IORD / IOWR
- `uint8_t  op_size;` // 原子操作数宽(4/8B);IO first_be
- `uint8_t  space;`   // MEM / IO
- 调整 `_Static_assert` 到新大小(如 40B),保持 packed。
新增枚举 `dma_op_t`。operand(入)与返回值(出)**不塞结构** —— 走现成 `DMA_DATA` 帧(`tcp_dma_data_hdr_t`)。

### 2. `bridge/vcs/bridge_vcs.c` —— per-RC 入向发起 DPI
新增(照 `dma_read_sync`/`dma_write_sync` 骨架,但用 `g_rc[rc].transport` + `tlp_cache_push_ctx(&g_rc[rc],…)`):
- `int bridge_vcs_dma_read_rc(int rc, longint host_addr, int len, /*out*/ data[])`
- `int bridge_vcs_dma_write_rc(int rc, longint host_addr, data[], int len)`
- `int bridge_vcs_atomic_request_rc(int rc, int op, int op_size, longint host_addr, operand_in[], /*out*/ old_value[])` —— 发 op=FETCHADD/SWAP/CAS + operand(DMA_DATA)→ 阻塞等 old value(DMA_DATA)
- `int bridge_vcs_io_request_rc(int rc, int is_write, int io_addr, data_in/out[], int first_be)`
全部 `_rc(rc)`,内部用 `g_rc[rc]`。DPI import 声明加进 `bridge_vcs.sv` 的 `cosim_bridge_pkg`。

### 3. `qemu-plugin/cosim_pcie_rc.c` —— `cosim_dma_cb` 按 op-code 分派
- `PLAIN`(op=0):今天的 READ/WRITE 分支不变。
- `ATOMIC`:新分支。**红线正确性** —— 在**同一 device bus-master AS** 上用 QEMU 原子内存原语做 RMW(4B/8B):`old = 原子读`;`new = op(old, operand)`(FetchAdd=old+operand / Swap=operand / CAS=(old==compare?swap:old));`原子写回`;`old` 经 `bridge_complete_dma_with_data` 回投。**不得用 raw-RAM-read + device-AS-write 两条拼**(AS 不一致且非原子)。2-RC 并发同 GPA 靠原子访问器保证。
- `IO`:`address_space_io` 服务(IORD 回读值,IOWR 回 status);若无真实 IO 目标,退化 sink + 固定 Cpl(设计里明确)。
- 服务后一律 `bridge_complete_dma_with_data`(有数据)/ `bridge_complete_dma`(仅 status)。

### 4. `qemu-plugin/bridge_qemu.c` + `bridge/qemu/*` —— 原子原语 + IO helper
提供 device-AS 上的 4B/8B 原子 RMW 访问器(封装 QEMU `address_space_*` 原子/`cmpxchg` 型),供 cosim_dma_cb 调用。

### 5. `vcs-tb/cosim_xrc_driver.sv` —— rx_loop 分派(替换 228-234 drop)
- 按 `rx_tlp.kind` 分派(不 `$cast` 子类型,因 decode 全返 mem_tlp)。
- operand 解析:从 `rx_tlp.payload` 按 kind+length 取(FetchAdd/Swap:1×op_size;CAS:compare+swap 各 op_size);op_size 由 length 推(FetchAdd/Swap len=1→4B/len=2→8B;CAS len=2→4B/len=4→8B)。
- `build_cpld_tlp()` 辅助:建 `pcie_tl_cpl_tlp`(kind=TLP_CPLD,回显 `requester_id`/`tag`,填 lower_addr/byte_count/cpl_status=SC,payload=返回值)→ `send_tlp`。IOWR 回 status-only Cpl(kind=TLP_CPL 无 payload)。MEM_WR posted 不回。

## 数据结构与协议

- `dma_req_t` +op/op_size/space(见 §1);operand 与返回值走 `DMA_DATA` 帧(复用,tag 空间与普通 DMA 隔离:同帧加 op 标志区分)。
- 不新增 SYNC_MSG/TCP_MSG 类型 → `irq_poller` poller 循环**不用加分支**(不堵 aux 队头)。

## 正确性红线

- **原子性:** atomic RMW 必须同一 device AS + QEMU 原子访问器,禁止 read-raw + write-device 拼接。
- **per-RC 隔离:** RC0 的 DUT atomic 只命中 RC0 内存、CplD 回 RC0 requester,不串 RC1;host 内存模型天然 per-device(2-RC 各自 QEMU),但新 DPI 必须 `g_rc[rc]`。
- **tag 回显:** CplD 的 requester_id/tag 必须回显入向请求的值,否则 DUT 匹配不上。

## 测试

- **C 单测(优先,ctest,不需 VCS/QEMU):** `tests/integration/test_atomic_roundtrip.c`(镜像 `test_dma_roundtrip.c`),dma_callback 换成做 RMW,断言:FetchAdd 返回旧值 + 内存 +operand;Swap 返回旧值 + 内存=operand;CAS 命中(old==compare→写 swap)/ 不命中(old≠compare→不写)两分支;CplD data 回投正确。IO round-trip 类似。
- **SV e2e(53 QEMU + 61 VCS,TCP 9100):** VIP RQ sequence 产真 AtomicOp/IO/MRd/MWr → per-RC(2-RC)→ QEMU 服务 → CplD 回 DUT;SV scoreboard 对原值/读值。

## 范围

- **本 spec + plan:** 阶段0(入向 DMA MRd/MWr per-RC)+ 阶段1(AtomicOp + IO per-RC)。
- **不在本轮:** Msg/VendorMsg(需补 `xilinx_req_type_e` Msg 编码 + `decode_rq` Msg 分支 + 服务,难)—— 阶段2 另 spec;per-function(requester_id)路由;出向扩展 TLP 的 per-RC getter(`poll_tlp_ext_rc` 等,入向不依赖);guest 可见 atomic 原值。

## 多机构建(红线)

任何改 `dma_req_t` 的步骤必须**双端同步重编**:**61** `make vcs-vip`(VCS 侧 C)+ **53** 把 device .c 拷进 QEMU `hw/net/` 后 `ninja qemu-system-x86_64` **且** `make bridge`(重编 `libcosim_bridge.so`,见记忆 build-topology —— ninja 不重编 bridge)。否则 `_Static_assert` 失败或线上字节错位。

## 遗留默认(非阻塞)

- IO 若 DUT 侧无真实目标 → 先走 `address_space_io` 真服务;确认无目标再退化 sink。
- atomic 只覆盖 RAM 目标(MMIO/MSI 区不覆盖)。
- 阶段0 先零线格式改动通 DMA;阶段1 再一次性破 32B 断言做 atomic+IO。
