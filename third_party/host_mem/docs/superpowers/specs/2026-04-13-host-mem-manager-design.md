# Host Memory Manager Design Spec

## Overview

SystemVerilog `uvm_object` 实现的主机内存管理模块，用于验证环境中模拟主机内存的分配、释放、读写和调试。支持 64-bit 地址空间，基于 Buddy System 算法实现高效的可变大小分配与自动合并。

## Goals

- 在 testbench 中分配/释放内存地址段，防止地址冲突
- 内置 byte 流读写，自动检测非法访问
- 提供丰富的调试和诊断能力
- 作为 `uvm_object` 可多实例化，各自管理独立地址空间

## Architecture

单类集成设计，所有功能在 `host_mem_manager` 类中，内部按功能分组：

```
host_mem_manager (uvm_object)
+-- Buddy 分配器（alloc/free/合并）
+-- 数据存储（read/write/memset/memcpy/compare）
+-- 子区间管理（release_range/sub_block_valid）
+-- 安全检查（未分配访问/double-free/poison fill/越界检测）
+-- 历史记录（alloc/free log + 泄漏检查）
+-- 调试接口（hexdump/分配状态/统计信息）
```

## Buddy System Allocator

### Parameters

- 地址空间：64-bit，通过 `init_region()` 指定管理范围
- 最小块大小：64B（cache line 粒度）
- 块大小：64B, 128B, 256B, ... 均为 2 的幂
- Poison pattern：可配置，默认 `8'hDE`

### Data Structures

```sv
// 空闲块：每一级的空闲块集合
// key = buddy level (0=64B, 1=128B, 2=256B, ...)
// value = 该级别所有空闲块的基地址集合
bit free_blocks[int][bit[63:0]];

// 已分配块信息
typedef struct {
    bit [63:0]   base_addr;
    int unsigned buddy_size;   // Buddy 块大小（2的幂）
    int unsigned req_size;     // 用户请求的原始大小
    int unsigned align;        // 请求的对齐
    string       caller_file;
    int          caller_line;
    realtime     alloc_time;
} alloc_info_t;

alloc_info_t alloc_table[bit[63:0]];  // key = base_addr

// 地址反向查找：每 64B 对齐地址 -> 所属块 base_addr
bit[63:0] addr_to_block[bit[63:0]];

// 数据存储：每个已分配块的数据
byte block_data[bit[63:0]][];  // key = base_addr, value = 动态数组

// 子区间有效位图：跟踪 release_range 释放的 64B 子块
bit sub_block_valid[bit[63:0]][];  // key = base_addr, 每bit对应64B

// 历史记录
typedef struct {
    string       op;           // "ALLOC" / "FREE" / "RELEASE_RANGE"
    bit [63:0]   base_addr;
    int unsigned size;
    string       caller_file;
    int          caller_line;
    realtime     timestamp;
} mem_history_t;

mem_history_t history[$];

// 统计信息（用 longint unsigned 支持 64-bit 地址空间）
longint unsigned total_size;
longint unsigned allocated_size;
longint unsigned free_size;
int unsigned     alloc_count;
int unsigned     total_alloc_ops;
int unsigned     total_free_ops;

// 多 region 记录
typedef struct {
    bit [63:0] base_addr;
    bit [63:0] end_addr;
} region_info_t;

region_info_t regions[$];

// 配置
byte poison_pattern = 8'hDE;
bit  warn_on_poison_read = 0;
```

### Init Algorithm

```
init_region(base, end):
  1. 计算区间大小
  2. 将区间分解为多个 2 的幂大小的块（从最大到最小贪心分解）
     例: 48KB = 32KB + 16KB
  3. 每个块加入对应 level 的 free_blocks
  4. 更新 total_size, free_size
```

### Alloc Algorithm

```
alloc(size, align):
  1. buddy_size = max(round_up_pow2(size), align, 64)
     对齐要求融入 buddy_size，level-N 的块天然按 64*2^N 对齐
  2. 计算 level = log2(buddy_size / 64)
  3. 从 level 向上查找有空闲块的最小 level
  4. 找到后逐级分裂到目标 level
     分裂产生的伙伴块加入 free_blocks
  5. 记录 alloc_table[base] = alloc_info
  6. 写入 addr_to_block 映射（每 64B 粒度一条）
  7. 创建 block_data[base] = new byte[buddy_size]
  8. 创建 sub_block_valid[base]，全部置 1
  9. 记录 history，更新统计
  10. 返回 base_addr；空间不足返回 -1 并报 ERROR
```

### Free Algorithm

```
free(addr):
  1. 检查 alloc_table[addr] 是否存在
     不存在 → 检查是否在 freed 历史中（double-free 检测）→ FATAL
  2. 获取 alloc_info: buddy_size, level
  3. poison fill: block_data[addr] 全部填 poison_pattern
  4. 删除 block_data[addr], alloc_table[addr], addr_to_block 映射, sub_block_valid[addr]
  5. 合并循环：
     a. buddy_addr = addr XOR buddy_size
     b. buddy_addr 在 free_blocks[level] 中？
        是 → 移除 buddy_addr，addr = min(addr, buddy_addr)，level++，继续
        否 → 停止
  6. 将合并后的块加入 free_blocks[level]
  7. 记录 history，更新统计
```

### Release Range

支持 DMA 等场景的分批部分释放，不涉及 buddy 层操作：

```
release_range(addr, size):
  1. 检查 addr 和 size 按 64B 对齐，否则 FATAL
  2. 查找所属块 base
  3. 检查范围在块内
  4. poison fill 对应区间
  5. 清除 sub_block_valid 中对应位
  6. 检查是否所有位都已清零
     是 → 自动触发 buddy 层 free(base)
  7. 记录 history
```

## Core API

### Construction & Init

```sv
function new(string name = "host_mem_manager");

// 初始化地址区间，可多次调用添加不同 region
function void init_region(
    bit [63:0] base_addr,
    bit [63:0] end_addr,
    byte       poison = 8'hDE
);
```

### Alloc & Free

```sv
// 返回分配的基地址，失败返回 -1
function bit [63:0] alloc(
    int unsigned size,
    int unsigned align    = 1,
    string       file     = `__FILE__,
    int          line     = `__LINE__
);

// 整块释放，addr 必须是 alloc 返回的基地址
// 如果该块有部分子区间已通过 release_range 释放，free 仍然释放整个块（清理剩余部分）
function void free(
    bit [63:0] addr,
    string     file = `__FILE__,
    int        line = `__LINE__
);

// 部分释放，addr 和 size 必须 64B 对齐
function void release_range(
    bit [63:0]   addr,
    int unsigned size,
    string       file = `__FILE__,
    int          line = `__LINE__
);
```

### Data Read/Write

```sv
function void write(
    bit [63:0]   addr,
    byte         data[],
    string       file = `__FILE__,
    int          line = `__LINE__
);

function void read(
    bit [63:0]   addr,
    int unsigned size,
    ref byte     data[],
    string       file = `__FILE__,
    int          line = `__LINE__
);
```

### Bulk Operations

```sv
function void memset(
    bit [63:0]   addr,
    byte         value,
    int unsigned size,
    string       file = `__FILE__,
    int          line = `__LINE__
);

function void memcpy(
    bit [63:0]   dst_addr,
    bit [63:0]   src_addr,
    int unsigned size,
    string       file = `__FILE__,
    int          line = `__LINE__
);

// 返回 1=相同, 0=不同; mismatch_offset 返回首个不匹配偏移
function bit compare(
    bit [63:0]   addr1,
    bit [63:0]   addr2,
    int unsigned size,
    output int unsigned mismatch_offset,
    string       file = `__FILE__,
    int          line = `__LINE__
);
```

### Debug Interface

```sv
// hexdump: 每行16B, hex+ASCII, 重复行折叠
function void hexdump(
    bit [63:0]   addr,
    int unsigned size
);

// 打印所有已分配块: base, req_size, buddy_size, align, time, caller
function void print_alloc_table();

// 统计信息: 总空间/已分配/空闲/利用率/碎片/操作计数
function void print_stats();

// 分配/释放历史, last_n=0 打印全部
function void print_history(int unsigned last_n = 0);

// 泄漏检查: 报告未释放的块 (WARNING 级别)
function void leak_check(
    string file = `__FILE__,
    int    line = `__LINE__
);
```

## Safety Checks

| Operation | Check | Severity |
|-----------|-------|----------|
| write/read | Address not allocated | FATAL |
| write/read | Address in released sub-range | FATAL |
| write/read | Access beyond block boundary (checked against req_size) | FATAL |
| free | Address not an alloc base | FATAL |
| free | Double-free | FATAL |
| release_range | Address not in any allocated block | FATAL |
| release_range | Sub-range already released | WARNING |
| alloc | Insufficient space | ERROR |
| alloc | size=0 | ERROR |

### Error Report Format

```
UVM_FATAL @ 100ns [HOST_MEM] Accessing unallocated address 0x0000_1080
  -> Called from: tb/pcie_driver.sv:245
  -> Nearest block: 0x0000_1000 (size=64, already freed at 80ns)
```

- 报错时附带附近块信息辅助定位
- double-free 报出首次释放的时间和调用者

### Poison Fill

- 释放（free/release_range）后将数据填充为 poison_pattern（默认 `0xDE`）
- 可选 `warn_on_poison_read`：读到全 poison 数据时发出 WARNING（默认关闭）

## Debug Output Formats

### hexdump

```
[HOST_MEM] hexdump: 0x0000_1000 - 0x0000_107F (128 bytes, block base=0x1000, req_size=1024)
0x0000_1000: 48 65 6C 6C 6F 20 57 6F  72 6C 64 21 00 DE DE DE  |Hello World!....|
0x0000_1010: DE DE DE DE DE DE DE DE  DE DE DE DE DE DE DE DE  |................|
*
0x0000_1070: AB CD EF 01 23 45 67 89  00 00 00 00 00 00 00 00  |....#Eg.........|
```

### print_alloc_table

```
[HOST_MEM] Allocation Table (3 blocks):
  #0  base=0x0000_1000  req_size=1024    buddy_size=1024   align=64   alloc @ 10ns  from tb/dma_env.sv:88
  #1  base=0x0000_2000  req_size=15876   buddy_size=16384  align=4    alloc @ 25ns  from tb/nvme_driver.sv:142
  #2  base=0x0001_0000  req_size=4       buddy_size=64     align=4    alloc @ 30ns  from tb/pcie_agent.sv:56
```

### print_stats

```
[HOST_MEM] Memory Statistics:
  Region[0]:      0x0000_0000 - 0x0FFF_FFFF (256 MB)
  Region[1]:      0x1000_0000 - 0x1FFF_FFFF (256 MB)   // 如有多个 region
  Allocated:      17.0 KB (3 blocks)
  Free:           262127.0 KB
  Utilization:    0.01%
  Fragmentation:  2 free chunks across 4 levels
  Total alloc ops:  5
  Total free ops:   2
  History entries:  7
```

### print_history

```
[HOST_MEM] Memory History (last 5 of 7):
  [7] FREE   @ 50ns  addr=0x0000_3000  size=256     from tb/dma_env.sv:102
  [6] ALLOC  @ 30ns  addr=0x0001_0000  size=4       from tb/pcie_agent.sv:56
  ...
```

### leak_check

```
// No leaks:
[HOST_MEM] Leak check passed: 0 blocks outstanding

// With leaks (WARNING):
UVM_WARNING @ 1000ns [HOST_MEM] Leak check: 2 blocks not freed (total 16448 bytes):
  base=0x0000_1000  req_size=1024   alloc @ 10ns  from tb/dma_env.sv:88
  base=0x0000_2000  req_size=15876  alloc @ 25ns  from tb/nvme_driver.sv:142
```

## File Structure

```
host_mem/
  src/
    host_mem_manager.sv    -- 主实现文件
    host_mem_pkg.sv        -- package 声明，包含 typedef 和 import
```

## Usage Example

```sv
host_mem_manager mem = new("host_mem0");
mem.init_region(64'h0000_0000_0000_0000, 64'h0000_0000_0FFF_FFFF);

// Allocate
bit [63:0] addr = mem.alloc(1024, .align(64));

// Write
byte wdata[] = new[1024];
foreach(wdata[i]) wdata[i] = i;
mem.write(addr, wdata);

// Read back
byte rdata[];
mem.read(addr, 1024, rdata);

// Compare
int unsigned mismatch;
if (!mem.compare(addr, addr2, 1024, mismatch))
    $display("Mismatch at offset %0d", mismatch);

// Partial release (DMA scenario)
mem.release_range(addr, 512);

// Debug
mem.hexdump(addr, 128);
mem.print_stats();

// Cleanup
mem.free(addr);  // or auto-free after all sub-ranges released
mem.leak_check();
```
