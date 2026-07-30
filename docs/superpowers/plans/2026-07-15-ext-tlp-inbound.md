# DUT 入向扩展 TLP(DMA/Atomic/IO)+ per-RC 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development(推荐)或 executing-plans。步骤用 checkbox(`- [ ]`)。

**Goal:** DUT(RTL,requester)在 RQ 通道产入向 **DMA MRd/MWr + AtomicOp(FetchAdd/Swap/CAS)+ IO(IORd/IOWr)** → per-RC DPI → QEMU 服务(原子 RMW)→ CplD 回投 DUT。

**Architecture:** 复用已跑通的入向 DMA 服务链(`cosim_dma_cb` + `DMA_DATA` 回投),补 rx_loop 转发 + per-RC 发起 DPI + QEMU atomic/io 分支。**分两阶段**:阶段0(DMA,零线格式改动,仅 61 重编)→ 阶段1(Atomic+IO,扩 `direction`+复用 `_pad_rid`,双端重编)。

**Tech Stack:** C(bridge_vcs/bridge_qemu/cosim_pcie_rc)、SV/UVM、QEMU 9.2.0、VCS Q-2020(61)、QEMU(53)。

**基线:** `feature/ext-tlp-inbound`(off main)。VCS@61(`~/QEMU_VCS-sriov`,env 见 [[cosim-eth-adapter]]),QEMU device@53(ninja),bridge C@本机/53(`make bridge`)。

**决策(spec 已定):** 选项 A;真 VIP RQ sequence 激励;C 单测 + SV e2e;阶段0+1(Msg 不做);atomic 目标 RAM;per-RC(非 per-function)。

---

## 关键事实(recon 已确认,照抄源)

- **RQ 激励全现成**(`pcie_tl_pkg`):`pcie_tl_atomic_seq`/`io_rd_seq`/`io_wr_seq`/`mem_rd_seq`/`mem_wr_seq`。确定操作数用 `pcie_tl_atomic_fixed_seq`(在 `tests/pcie_tl_unified_mem_test.sv:13-44`,需提到 pkg 或 test include)。
- **VIP rc_driver 完整入向参考** `pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv`:dispatch(76-96)、build CplD(133-154)、atomic operand 解析(173-220)、atomic CplD(230-250)。**port 进 rx_loop**。
- **C DMA 骨架** `bridge_vcs.c` dma_read_sync(543-617)/dma_write_sync(684-759)。mirror 为 `_rc`:`g_transport`→`g_rc[rc].transport`,`tlp_cache_push_ctx(&g_rc[0],..)`→`(&g_rc[rc],..)`,删 SHM 分支,守卫 `if(!rc_ok(rc)||!g_rc[rc].transport) return -1`。
- **QEMU 服务** `cosim_dma_cb`(cosim_pcie_rc.c:129-182)按 `req->direction` 分 READ/WRITE。`bridge_complete_dma_with_data(ctx,tag,status,direction,host_addr,data,len)`(bridge_qemu.c:168)回数据。
- **QEMU 原子(红线)**:9.2.0 **无 AddressSpace 原子 RMW**;`ldl_le_dma`/`stl_le_dma`(dma.h)是普通读写。正解 = `pci_dma_map(dev,addr,&len,DMA_DIRECTION_FROM_DEVICE)` 拿 host 指针 → `qatomic_fetch_add/xchg/cmpxchg`(`qemu/atomic.h`,4B/8B)→ `pci_dma_unmap`。map 返回 NULL(非 RAM)则退化 plain RMW + 告警(spec:RAM only)。BQL 已改名 `bql_lock()`。
- **dma_req_t**(cosim_types.h:118-129,32B packed):`requester_id/_pad_rid/tag/direction/host_addr/len/dma_offset/timestamp`。**扩法(保持 32B,不破断言)**:`direction`(uint32)扩枚举当 op-code;`_pad_rid`(2B)拆 `uint8_t op_size; uint8_t space;`。SV 侧 `bridge_vcs.sv:115-118` 有 `dma_direction_e` 复本,同步改。
- **AtomicOp CplD 回旧值(pre-op)**,payload 存 LE。

---

## File Structure

| 文件 | 改 | 阶段 |
|---|---|---|
| `bridge/vcs/bridge_vcs.c` | +`dma_read_rc`/`dma_write_rc`(P0)、`atomic_request_rc`/`io_request_rc`(P1) | 0,1 |
| `bridge/vcs/bridge_vcs.sv` | + `_rc` DPI import;`dma_direction_e` 扩枚举(P1) | 0,1 |
| `bridge/common/cosim_types.h` | `dma_direction_t` 扩 + `_pad_rid` 拆 op_size/space(P1) | 1 |
| `bridge/common/atomic_rmw.h` | 新:纯 C 原子 RMW 计算 helper(test + QEMU 共用) | 1 |
| `qemu-plugin/cosim_pcie_rc.c` | `cosim_dma_cb` 加 atomic/io 分支 | 1 |
| `vcs-tb/cosim_xrc_driver.sv` | rx_loop kind 分派 + `build_cpld_tlp` + atomic/io | 0,1 |
| `tests/integration/test_atomic_roundtrip.c` + CMake | 新 C 单测 | 1 |

---

# 阶段 0 —— 入向 DMA MRd/MWr per-RC(零线格式改动,仅 61 重编)

## Task 0.1: C per-RC DMA 发起 DPI

**Files:** Modify `bridge/vcs/bridge_vcs.c`、`bridge/vcs/bridge_vcs.sv`

- [ ] **Step 1: 加 `bridge_vcs_dma_read_rc` / `dma_write_rc`(mirror sync 版)**

在 bridge_vcs.c 现有 `dma_read_sync`(543)/`dma_write_sync`(684)**之后**新增(整体 copy 对应函数的 **TCP 分支**,按下述 transform):
```c
/* per-RC 入向 DMA 发起(照 dma_read_sync TCP 路径;g_transport→g_rc[rc].transport,
 * tlp_cache_push_ctx(&g_rc[0])→(&g_rc[rc]),删 SHM 分支,守卫改 g_rc[rc].transport) */
int bridge_vcs_dma_read_rc(int rc, unsigned long long host_addr,
                           unsigned int *data, int len) {
    if (!rc_ok(rc) || len <= 0) return -1;
    cosim_transport_t *tr = g_rc[rc].transport;
    if (!tr) return -1;
    static uint32_t next_tag = 3000;
    uint32_t tag = next_tag++;
    dma_req_t req = { .tag = tag, .direction = DMA_DIR_READ, .host_addr = host_addr,
                      .len = (uint32_t)len, .dma_offset = 0, .timestamp = 0 };
    if (tr->send_dma_req(tr, &req) < 0) return -1;
    for (int i = 0; i < 1000; i++) {
        sync_msg_t msg;
        if (tr->recv_sync(tr, &msg) < 0) return -1;
        if (msg.type == SYNC_MSG_SHUTDOWN) return -1;
        if (msg.type == SYNC_MSG_TLP_READY) {
            tlp_entry_t cached;
            if (tr->recv_tlp(tr, &cached) == 0) tlp_cache_push_ctx(&g_rc[rc], &cached);
            continue;
        }
        if (msg.type == SYNC_MSG_DMA_CPL) {
            dma_cpl_t cpl;
            if (tr->recv_dma_cpl(tr, &cpl) < 0) return -1;
            if (cpl.tag != tag || cpl.status != 0) return -1;
            uint32_t rx_tag, rx_dir, rx_len = (uint32_t)len; uint64_t rx_addr;
            uint8_t tmp[64];
            if (tr->recv_dma_data(tr, &rx_tag, &rx_dir, &rx_addr, tmp, &rx_len) < 0) return -1;
            int words = (len + 3) / 4; if (words > 16) words = 16;
            for (int w = 0; w < words; w++)
                data[w] = tmp[w*4] | (tmp[w*4+1]<<8) | (tmp[w*4+2]<<16) | (tmp[w*4+3]<<24);
            return 0;
        }
    }
    return -1;
}
```
`dma_write_rc` 同理 copy `dma_write_sync` 的 TCP 分支:守卫同上;组 `dma_req_t{direction=DMA_DIR_WRITE}`;**先 `send_dma_req` 后 `send_dma_data`**(顺序不可颠倒,见 bridge_vcs.c:699-704 注释);阻塞等 `DMA_CPL`(同 read 的循环,含 TLP_READY 缓存到 `&g_rc[rc]`);无回读数据。
> 精确 transform 清单见"关键事实"。`recv_dma_data` 缓冲 64B 上限(DPI data[16]),len>64 截断。

- [ ] **Step 2: SV DPI import(bridge_vcs.sv 的 `_rc` import 段 ~185-217 内加)**
```systemverilog
import "DPI-C" function int bridge_vcs_dma_read_rc(input int rc, input longint unsigned host_addr,
                                                  output int unsigned data[16], input int len);
import "DPI-C" function int bridge_vcs_dma_write_rc(input int rc, input longint unsigned host_addr,
                                                   input int unsigned data[16], input int len);
```

- [ ] **Step 3: 61 编译验证(不需 QEMU)**

Run(61,VCS env):`make vcs-vip` —— 期望 0 error(新 DPI 符号解析)。
> 本地也可 `make bridge`(cmake)编 C 单侧检查语法。

- [ ] **Step 4: Commit** `git commit -m "feat(ext-tlp): per-RC 入向 DMA 发起 DPI(dma_read/write_rc)"`

## Task 0.2: SV rx_loop 分派 MEM_RD/MEM_WR + build CplD

**Files:** Modify `vcs-tb/cosim_xrc_driver.sv`

- [ ] **Step 1: 替换 rx_loop 的 drop(228-234)为 kind 分派**
```systemverilog
if ($cast(cpl, rx_tlp)) begin
    forward_completion_to_qemu(cpl);
end else begin
    inbound_req_count++;
    case (rx_tlp.kind)
        TLP_MEM_WR: service_inbound_mem_write(rx_tlp);
        TLP_MEM_RD, TLP_MEM_RD_LK: service_inbound_mem_read(rx_tlp);
        // 阶段1 加: TLP_ATOMIC_*, TLP_IO_RD/WR
        default: `uvm_info(get_name(), $sformatf(
            "RC%0d 未支持入向 %s, 丢弃", rc_index, rx_tlp.kind.name()), UVM_MEDIUM)
    endcase
end
```

- [ ] **Step 2: 加服务函数(port rc_driver.sv:133-154 的 CplD 构建;数据源换成 DPI)**
```systemverilog
// 入向 MWr(posted, 不回 Cpl):payload → host
protected task service_inbound_mem_write(pcie_tl_tlp req);
    pcie_tl_mem_tlp w; int unsigned wdata[16];
    if (!$cast(w, req)) return;
    pack_bytes_to_words(w.payload, wdata);   // 见 Step3
    void'(bridge_vcs_dma_write_rc(rc_index, w.addr, wdata, w.payload.size()));
    total_tlp_count++;
endtask

// 入向 MRd(non-posted):读 host → build CplD 打回 DUT
protected task service_inbound_mem_read(pcie_tl_tlp req);
    pcie_tl_mem_tlp r; int unsigned rdata[16]; int nbytes;
    pcie_tl_cpl_tlp cpl;
    if (!$cast(r, req)) return;
    nbytes = r.length * 4;   // length DW → bytes(近似,首/末 BE 精确化留后续)
    if (bridge_vcs_dma_read_rc(rc_index, r.addr, rdata, nbytes) != 0) begin
        `uvm_error(get_name(), $sformatf("RC%0d 入向 MRd DMA 失败", rc_index)) return;
    end
    cpl = build_cpld_tlp(r, rdata, nbytes);
    send_tlp(cpl);
    total_cpl_count++;
endtask

// 建 CplD(port rc_driver.sv:133-154:回显 requester_id/tag,填 lower_addr/byte_count/status)
protected function pcie_tl_cpl_tlp build_cpld_tlp(pcie_tl_mem_tlp r, int unsigned d[16], int nbytes);
    pcie_tl_cpl_tlp cpl = pcie_tl_cpl_tlp::type_id::create("cpld");
    int len_dw = (nbytes + 3) / 4;
    cpl.kind = TLP_CPLD; cpl.fmt = FMT_3DW_WITH_DATA; cpl.type_f = TLP_TYPE_CPL;
    cpl.tc = r.tc; cpl.td = 0; cpl.ep_bit = 0; cpl.attr = r.attr;
    cpl.length = (len_dw == 1024) ? 0 : len_dw[9:0];
    cpl.requester_id = r.requester_id; cpl.tag = r.tag;
    cpl.completer_id = 16'(rc_index);   // per-RC BDF
    cpl.cpl_status = CPL_STATUS_SC; cpl.bcm = 0;
    cpl.byte_count = nbytes[11:0]; cpl.lower_addr = r.addr[6:0];
    cpl.payload = new[nbytes];
    for (int i = 0; i < nbytes; i++) cpl.payload[i] = d[i/4][(i%4)*8 +: 8];
    return build_cpld_tlp = cpl;
endfunction
```

- [ ] **Step 3: 加 `pack_bytes_to_words`(payload byte[] → int[16] LE,unpack_words_to_bytes 的逆)**
```systemverilog
protected function void pack_bytes_to_words(bit [7:0] payload[], output int unsigned d[16]);
    for (int i = 0; i < 16; i++) d[i] = 0;
    foreach (payload[i]) if (i/4 < 16) d[i/4][(i%4)*8 +: 8] = payload[i];
endfunction
```

- [ ] **Step 4: 61 编译** `make vcs-vip` → 0 error。**Commit** `feat(ext-tlp): rx_loop 入向 MRd/MWr 分派 + build CplD`

## Task 0.3: 阶段0 SV e2e —— 白盒注入自检(53 QEMU + 61 VCS)

> **修正(recon 后):** 原假设"对 RC 的 RQ agent 起 mem_rd/mem_wr seq"**方向错**。核实:`tb_cosim_multirc_top` 里 RC-role adapter **驱 CQ/RC、采样 CC/RQ**,4 条 AXIS far-end **悬空**(接真 DUT 的模板,tb 内无 DUT/ep_stub);RC sequencer 起 mem seq → 驱 **CQ(host→DUT MMIO)**,**不触发**入向 `service_inbound_*`(那由 **RQ monitor** 喂,只有真 DUT/EP-role 能产)。VIP-only tb 里无物产入向 RQ。选**最小·白盒注入**验地基(EP-替身全保真链留后续)。

**Files:** Modify `vcs-tb/cosim_xrc_driver.sv`(加 test-only 钩子)、`vcs-tb/cosim_xrc_test.sv`(加自检 + plusarg 守卫)

- [ ] **Step 1: 驱动加 test-only 钩子** —— `cosim_xrc_driver` 加 2 公有方法:`test_inbound_mwr(addr,d[16],nbytes)`(复用生产 `build_mmio_tlp(BV_TLP_MWR,...)` 建 MWr → 走真 `service_inbound_mem_write` → `bridge_vcs_dma_write_rc`);`test_read_host(addr,nbytes,d[16])`(转调 `bridge_vcs_dma_read_rc`,不发 CplD)。
- [ ] **Step 2: test 加自检** —— `cosim_xrc_test` 加 `run_inbound_dma_selfcheck()`:逐 RC 写 64B 已知 pattern 到 per-RC 隔离 GPA(`0x0F100000 + r*0x10000`,高内存保留区)→ 读回逐字比对。run_phase 用 `+INBOUND_DMA_TEST` 守卫(置则自检后即退,不阻塞 shutdown;默认行为不变)。
- [ ] **Step 3: 起环境** —— 61 `build_cosim_multirc.sh build`(lib 覆盖见头);53 起 QEMU:9000(cosim device,`transport=tcp,port_base,instance_id`)。
- [ ] **Step 4: 跑 + 判定** —— 61 `simv_cosim_mrc +INBOUND_DMA_TEST +REMOTE_HOST=<53> +PORT_BASE=9000`。判据:log 出 `inbound-DMA self-check PASS (all RC)`,`got==exp` 逐字一致,无 UVM_ERROR。**Commit** 记录结果。
> **范围**:验 Task 0.1 写/读 DPI + 0.2 `service_inbound_mem_write` 分派 + 真 QEMU 往返;**不**驱真 RQ-AXIS、**不**走 `service_inbound_mem_read` 的 CplD-over-wire(tb 无 RC-channel 消费者会 hang,留 EP-替身方案)。

---

# 阶段 1 —— AtomicOp + IO per-RC(扩 direction + `_pad_rid`,双端重编)

## Task 1.1: C types 扩 dma_req_t(保持 32B)+ 原子 RMW helper

**Files:** Modify `bridge/common/cosim_types.h`、`bridge/vcs/bridge_vcs.sv`;Create `bridge/common/atomic_rmw.h`

- [ ] **Step 1: 扩 `dma_direction_t` + 拆 `_pad_rid`(cosim_types.h:112-129)**
```c
typedef enum {
    DMA_DIR_READ   = 0,
    DMA_DIR_WRITE  = 1,
    DMA_OP_FETCHADD = 2,
    DMA_OP_SWAP     = 3,
    DMA_OP_CAS      = 4,
    DMA_OP_IORD     = 5,
    DMA_OP_IOWR     = 6,
} dma_direction_t;

typedef struct {
    uint16_t requester_id;
    uint8_t  op_size;         /* 原子操作数宽 4/8;IO first_be(低4位)——原 _pad_rid 高字节 */
    uint8_t  space;           /* 0=MEM 1=IO ——原 _pad_rid 低字节 */
    uint32_t tag;
    uint32_t direction;       /* = op-code(DMA_DIR_* / DMA_OP_*) */
    uint64_t host_addr;
    uint32_t len;
    uint32_t dma_offset;
    uint32_t timestamp;
} __attribute__((packed)) dma_req_t;

_Static_assert(sizeof(dma_req_t) == 32, "dma_req_t must be 32 bytes");  /* 32 不变 */
```
> `_pad_rid`(2B)拆成 `op_size`+`space`,sizeof 仍 32,断言不动。老代码填 0 = op_size=0/space=MEM,兼容 plain RW。

- [ ] **Step 2: SV `dma_direction_e` 复本同步(bridge_vcs.sv:115-118)** —— 加 `DMA_OP_FETCHADD=2 … DMA_OP_IOWR=6`。

- [ ] **Step 3: 原子 RMW 纯 C helper(test + QEMU 共用)`bridge/common/atomic_rmw.h`**
```c
#ifndef ATOMIC_RMW_H
#define ATOMIC_RMW_H
#include <stdint.h>
/* 纯计算:给旧值 + operand(CAS 再给 compare),按 op 算新值。返回旧值(供 CplD)。
 * 不做内存访问 —— 内存原子性由调用方(QEMU qatomic / test 缓冲)保证。 */
static inline uint64_t atomic_rmw_compute(int op, uint64_t old_val,
                                          uint64_t operand, uint64_t compare,
                                          uint64_t *new_val_out) {
    uint64_t nv = old_val;
    switch (op) {
        case 2 /*FETCHADD*/: nv = old_val + operand; break;
        case 3 /*SWAP*/:     nv = operand; break;
        case 4 /*CAS*/:      nv = (old_val == compare) ? operand : old_val; break;
    }
    if (new_val_out) *new_val_out = nv;
    return old_val;  /* PCIe AtomicOp CplD 回旧值 */
}
#endif
```

- [ ] **Step 4: 编译验证** —— `make bridge`(cmake,C11 会验 `_Static_assert`);61 `make vcs-vip`。**Commit** `feat(ext-tlp): dma_req_t 扩 op-code/op_size/space(保持32B)+ atomic_rmw helper`

## Task 1.2: C per-RC atomic/io 发起 DPI

**Files:** Modify `bridge/vcs/bridge_vcs.c`、`bridge/vcs/bridge_vcs.sv`

- [ ] **Step 1: `bridge_vcs_atomic_request_rc`(mirror dma_write_rc:发 operand,阻塞等 old value)**
```c
/* op ∈ {DMA_OP_FETCHADD/SWAP/CAS};operand_in = FetchAdd/Swap 1×op_size;CAS = compare‖swap 2×op_size。
 * 回 old_value(op_size 字节)—— 用 dma_read 的回读通道。 */
int bridge_vcs_atomic_request_rc(int rc, int op, int op_size,
                                 unsigned long long host_addr,
                                 const unsigned int *operand_in, int operand_words,
                                 unsigned int *old_out) {
    if (!rc_ok(rc)) return -1;
    cosim_transport_t *tr = g_rc[rc].transport; if (!tr) return -1;
    static uint32_t next_tag = 4000; uint32_t tag = next_tag++;
    dma_req_t req = { .tag = tag, .direction = (uint32_t)op, .op_size = (uint8_t)op_size,
                      .space = 0, .host_addr = host_addr, .len = (uint32_t)op_size, .timestamp = 0 };
    /* 先 send_dma_req 后 send_dma_data(operand),顺序同 write */
    if (tr->send_dma_req(tr, &req) < 0) return -1;
    { uint8_t ob[16]; int nb = operand_words*4;
      for (int i=0;i<nb;i++) ob[i] = operand_in[i/4] >> ((i%4)*8);
      if (tr->send_dma_data(tr, tag, (uint32_t)op, host_addr, ob, nb) < 0) return -1; }
    /* 阻塞等 DMA_CPL + 回读 old value(照 dma_read_rc 的 for(1000) 循环:含 TLP_READY 缓存 &g_rc[rc],
     * recv_dma_cpl 校验 tag/status,recv_dma_data → old_out) */
    return 0; /* 循环体照抄 dma_read_rc:for(1000){...DMA_CPL: recv_dma_cpl+recv_dma_data→old_out; return 0} */
}
```
`bridge_vcs_io_request_rc(rc, is_write, io_addr, data, first_be)`:`direction=DMA_OP_IORD/IOWR`,`space=1`,`op_size=first_be`;IORd 回读值,IOWr 回 status。

- [ ] **Step 2: SV import(bridge_vcs.sv)** 加 `atomic_request_rc`/`io_request_rc`(`operand_in`/`old_out` = `int unsigned [16]`)。

- [ ] **Step 3: 61 `make vcs-vip` + 本机 `make bridge` 0 error。Commit** `feat(ext-tlp): per-RC atomic/io 发起 DPI`

## Task 1.3: QEMU `cosim_dma_cb` atomic/io 分支

**Files:** Modify `qemu-plugin/cosim_pcie_rc.c`

- [ ] **Step 1: 在 `cosim_dma_cb`(129-182)TCP 分支加 op-code 分派**

在现有 `if (req->direction == DMA_DIR_WRITE) {…} else {…}` 前加 atomic/io 判断:
```c
if (req->direction >= DMA_OP_FETCHADD && req->direction <= DMA_OP_CAS) {
    /* 入向 AtomicOp:收 operand → host-ptr 原子 RMW → 回 old value */
    uint32_t tag, dir, olen; uint64_t oaddr; uint8_t ob[16]; olen = sizeof(ob);
    ctx->transport->recv_dma_data(ctx->transport, &tag, &dir, &oaddr, ob, &olen);
    int sz = req->op_size;                 /* 4 或 8 */
    uint64_t operand = 0, compare = 0, old = 0;
    for (int i=0;i<sz;i++) operand |= (uint64_t)ob[i] << (i*8);
    if (req->direction == DMA_OP_CAS)      /* CAS: compare‖swap */
        for (int i=0;i<sz;i++) compare |= (uint64_t)ob[sz+i] << (i*8);
    /* host 指针原子 RMW(RAM 目标):pci_dma_map → qatomic → unmap */
    dma_addr_t mlen = sz;
    void *hp = pci_dma_map(PCI_DEVICE(s), req->host_addr, &mlen, DMA_DIRECTION_FROM_DEVICE);
    if (hp && mlen >= (dma_addr_t)sz) {
        if (sz == 8) {
            uint64_t opd = operand, cmp = compare;
            if (req->direction==DMA_OP_FETCHADD) old = qatomic_fetch_add((uint64_t*)hp, opd);
            else if (req->direction==DMA_OP_SWAP) old = qatomic_xchg((uint64_t*)hp, opd);
            else old = qatomic_cmpxchg((uint64_t*)hp, cmp, opd);
        } else { /* sz==4 */
            uint32_t opd = operand, cmp = compare, o32;
            if (req->direction==DMA_OP_FETCHADD) o32 = qatomic_fetch_add((uint32_t*)hp, opd);
            else if (req->direction==DMA_OP_SWAP) o32 = qatomic_xchg((uint32_t*)hp, opd);
            else o32 = qatomic_cmpxchg((uint32_t*)hp, cmp, opd);
            old = o32;
        }
        pci_dma_unmap(PCI_DEVICE(s), hp, mlen, DMA_DIRECTION_FROM_DEVICE, sz);
    } else {
        qemu_log("cosim: atomic target not RAM-mappable GPA=0x%lx\n", req->host_addr);
    }
    uint8_t rb[8]; for (int i=0;i<sz;i++) rb[i] = old >> (i*8);
    bridge_complete_dma_with_data(ctx, req->tag, 0, req->direction, req->host_addr, rb, sz);
    return;
}
if (req->direction == DMA_OP_IORD || req->direction == DMA_OP_IOWR) {
    /* 入向 IO:address_space_io(RAM-only 环境可先 sink+固定 Cpl,见 spec 边界)
     * IORD 回 4B 读值;IOWR 收 data 写 + 回 status。实现按 address_space_ldl/stl_le on address_space_io */
    return;
}
```
> 头文件:`#include "qemu/atomic.h"`(qatomic_*)、`hw/pci/pci_device.h`(pci_dma_map/unmap)。`qatomic_cmpxchg` 返回旧值,不判是否命中(CplD 回旧值,DUT 自比)。

- [ ] **Step 2: 编译** —— cosim_pcie_rc.c 属 device(ninja 编),本机若无 QEMU 树跳过,留 Task 1.6 在 53 编;本机 `make bridge` 确保 bridge 侧引用不报错。**Commit** `feat(ext-tlp): cosim_dma_cb atomic(qatomic RMW)+ io 分支`

## Task 1.4: SV rx_loop atomic/io 分派 + CplD(回旧值)

**Files:** Modify `vcs-tb/cosim_xrc_driver.sv`

- [ ] **Step 1: rx_loop case 加 atomic/io 分支**(Task 0.2 的 case 里补)
```systemverilog
TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS: service_inbound_atomic(rx_tlp);
TLP_IO_RD, TLP_IO_WR: service_inbound_io(rx_tlp);
```

- [ ] **Step 2: `service_inbound_atomic`(port rc_driver.sv:173-220 operand 解析 + 230-250 CplD)**
```systemverilog
protected task service_inbound_atomic(pcie_tl_tlp req);
    pcie_tl_mem_tlp a;                    // decode 返 mem_tlp,按 kind 分派(非 $cast atomic)
    int sz, op, opw; int unsigned operand[16], oldv[16];
    pcie_tl_cpl_tlp cpl;
    if (!$cast(a, req)) return;
    sz = (a.length >= 2) ? 8 : 4;         // FetchAdd/Swap len1→4/len2→8;CAS len2→4/len4→8
    op = (req.kind==TLP_ATOMIC_FETCHADD)?2 : (req.kind==TLP_ATOMIC_SWAP)?3 : 4;
    // operand: FetchAdd/Swap 1×sz;CAS compare‖swap 2×sz —— 从 a.payload(LE)打进 words
    opw = (op==4) ? (2*sz+3)/4 : (sz+3)/4;
    pack_bytes_to_words(a.payload, operand);
    if (bridge_vcs_atomic_request_rc(rc_index, op, sz, a.addr, operand, opw, oldv) != 0) begin
        `uvm_error(get_name(), "atomic DPI 失败") return; end
    cpl = build_cpld_tlp(a, oldv, sz);    // 回旧值(byte_count=sz)
    send_tlp(cpl); total_cpl_count++;
endtask
```
`service_inbound_io`:IORd → `bridge_vcs_io_request_rc(rc,0,addr,_,first_be)`→读值→CplD;IOWr → `..(rc,1,addr,data,first_be)`→回 status-only Cpl(`kind=TLP_CPL` 无 payload)。

- [ ] **Step 3: 61 `make vcs-vip` 0 error。Commit** `feat(ext-tlp): rx_loop atomic/io 分派 + 回旧值 CplD`

## Task 1.5: C 单测 test_atomic_roundtrip(不需 VCS/QEMU)

**Files:** Create `tests/integration/test_atomic_roundtrip.c`;Modify `tests/integration/CMakeLists.txt`

- [ ] **Step 1: 镜像 `test_dma_roundtrip.c`**,`dma_callback` 换成用 `atomic_rmw_compute` 做 RMW(在测试内存缓冲上):对 FetchAdd/Swap/CAS(命中+不命中)断言:回投 old 正确、缓冲 new 正确。SHM_NAME/SOCK 用唯一名。
- [ ] **Step 2: CMake 加 3 行(照 CMakeLists.txt:9-11)** 链 `cosim_bridge cosim_bridge_common`。
- [ ] **Step 3: `make bridge && ctest --test-dir build/tests/integration -R test_atomic_roundtrip -V`** → PASS。**Commit** `test(ext-tlp): test_atomic_roundtrip C 单测`

## Task 1.6: 双端重编 + SV e2e(53 QEMU + 61 VCS)

**Files:** 无(集成)

- [ ] **Step 1: 双端重编(红线)** —— **53**:把改过的 `qemu-plugin/cosim_pcie_rc.c` 拷进 QEMU `hw/net/` → `ninja -C <qemu>/build qemu-system-x86_64` **且** `make bridge`(重编 `libcosim_bridge.so`);**61**:`make vcs-vip`。(dma_req_t 线上语义变,双端必须同步。)
- [ ] **Step 2: 激励** —— test 对 RC 的 RQ agent 起 `pcie_tl_atomic_seq`(或 `pcie_tl_atomic_fixed_seq` 固定操作数)+ `io_rd_seq`/`io_wr_seq`。2-RC 各自 RQ。
- [ ] **Step 3: e2e** —— 53 `make run-qemu`,61 `simv_vip +COSIM +REMOTE_HOST=<53> +PORT_BASE=9100`。
- [ ] **Step 4: 判定** —— DUT AtomicOp → CplD 回旧值(SV scoreboard 对旧值 + 期望 guest 内存被 RMW);2-RC 隔离(RC0 atomic 不串 RC1);IO 回 CplD/Cpl。无 UVM_ERROR/FATAL。**Commit** 记录结果。

---

## Self-Review

- **spec 覆盖**:阶段0 DMA per-RC ✓、阶段1 Atomic(qatomic RMW 回旧值)+IO ✓、per-RC(g_rc[rc])✓、真 VIP RQ seq ✓、C 单测+SV e2e ✓、Msg 排除 ✓。
- **占位扫描**:`atomic_request_rc` 的等待循环、`io_request_rc` 内部、IO 服务分支标注"照抄 dma_read_rc 循环 / 见 spec"—— 是**明确指向已给全代码的 mirror**(dma_read_rc 全代码在 Task 0.1),非空占位。IO 服务深度依赖"IO 是否有真实目标"(spec 遗留默认:先 address_space_io,无目标退 sink)。
- **类型一致**:`dma_direction_t` C 枚举(2..6)与 SV `dma_direction_e` 复本、rx_loop op 编码(2/3/4)三处一致;`dma_req_t` 32B 不变(断言不动);CplD 字段名 = rc_driver.sv:133-154。
- **风险**:① QEMU 原子用 `pci_dma_map`+`qatomic`(RAM 可行,非 RAM 退化+告警)—— 已按 9.2.0 无 AS 原子 RMW 事实设计。② 双端重编红线单列 Task 1.6 Step1。③ IO 真实目标未定 → 先真服务,e2e 无目标转 sink(spec 已授权)。④ operand/old value 走 DMA_DATA,tag 空间(atomic 4000 / dma 3000)隔离。

---

## Execution Handoff

存 `docs/superpowers/plans/2026-07-15-ext-tlp-inbound.md`。执行:**Subagent-Driven(推荐)** 每 task 派 subagent + 两段 review;或 **Inline**。
**红线:** 阶段1 改 `dma_req_t`/`cosim_dma_cb` 后必须 **53 ninja+make bridge + 61 make vcs-vip 双端重编**;VCS 编/跑在 61,QEMU device 在 53。
