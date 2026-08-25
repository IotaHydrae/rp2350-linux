# DTB 生命周期与布局分析（S3 设计依据）

> 日期：2026-08-25 · 源码：`/home/developer/linux-7.2`（linux 7.2）· 关联：S3 开工设计、`QEMU-virt-DTB参考.md`
> 一句话结论：DTB 解析完之后，数据确实没用了；但内核会把 DTB 所在内存**永久保留**（memblock reserve），正常路径不会被覆盖。

## 问题

S3 开工前用户问：DTB 放 PSRAM 顶部，内核解析完之后是不是就没用了、可以被其他程序覆盖掉？

直觉里「解析完就没用」对了一半；「可以被覆盖」错了一半。差别在于两件事：**数据生命周期**（没用了）和**内存生命周期**（内核保留、不回收）。

```mermaid
flowchart LR
    A["bootloader<br/>DTB @ 0x11700000"] -->|a1 传物理地址| B["原始 DTB blob<br/>扁平二进制"]
    B -->|early_init_dt_scan<br/>启动最早期| C["memory / cmdline / model<br/>一次性读走"]
    B -->|unflatten_device_tree<br/>setup_arch 内| D["live tree<br/>struct device_node 拷贝"]
    D -->|此后全部驱动读取| E["of_* API / 驱动"]
    B -.->|memblock_reserve<br/>永久保留| F["原始 blob 所在内存<br/>分配器永不触碰"]
```

## 分析过程（可复现）

从「内核到底怎么用 DTB」问起，顺 `setup_arch()` 往下追。

### 1. 内核怎么读 DTB：两次「解析」，各管一段

RISC-V 的 DTB 消费分两段（`arch/riscv/kernel/setup.c`）：

- **扁平扫描**：`parse_dtb()`（setup.c:255）→ `early_init_dt_scan()`，线性扫原始 blob，只取启动必需的几样：memory 节点（告诉 memblock 内存有多大）、chosen（cmdline、stdout-path）、machine model。这一步发生在内存管理可用之前。
- **展开拷贝**：`setup_arch()` 后段（setup.c:329-331）调 `unflatten_device_tree()`，把原始 blob 展开成一棵 `struct device_node` 树，**拷贝**到内核自己分配的内存（`of_root` 指向新树）。此后所有驱动、`of_*` API 读的都是这棵拷贝，原始 blob 不再被读。

所以「解析完就没用了」在数据层面成立——准确说法是：**unflatten 之后，原始 blob 只是没人读，内核并没有把它当垃圾回收。**

### 2. 内核为什么不会覆盖它：setup_bootmem() 显式保留

`arch/riscv/mm/init.c` 的 `setup_bootmem()`（init.c:217），被 `paging_init()`（init.c:1350）无条件调用（MMU / NOMMU 共用；noMMU 下 `dtb_early_va` 就是物理地址本身，init.c:1309）。里面有这一行（init.c:307）：

```c
if (!IS_ENABLED(CONFIG_BUILTIN_DTB))
    memblock_reserve(dtb_early_pa, fdt_totalsize(dtb_early_va));
```

含义：按 `fdt_totalsize`（整块 DTB 大小）把这块物理内存从 memblock 的可用内存里划走。memblock 之后变成伙伴分配器，被 reserve 的区域不会变成 free page——所以内核自己（页表、kmalloc、给用户进程的内存）都不会落在 DTB 上。

`CONFIG_BUILTIN_DTB=y` 时不保留：DTB 编译进内核镜像，本来就在 rodata，属于内核镜像保留区，不需要单独划。

### 3. 边界（哪里会坏）

- 故意直接写物理地址（如 `/dev/mem` 这类绕开分配器的路径）可以覆盖它——但那不是「被其他程序正常覆盖」。
- 前提：DTB 地址必须在 memory 节点声明的范围内（我们的是 0x11000000~0x11800000），保留才有意义。
- bootloader 提供的 DTB 必须 `fdt_totalsize` 正确，否则内核保留的大小不对（dtc 编译出来的 .dtb 自带正确值，不用手工算）。

## S3 布局决策（2026-08-25 用户拍板）

- 内核 Image @ `0x11000000`（沿用 S1 跳转地址；rv32 要求 4MB 对齐，满足）
- DTB @ `0x11700000`（PSRAM 顶部附近；8MB 结束于 0x11800000，给内核和数据留足空间）
- 跳转协议：a0 = hartid，**a1 = DTB 物理地址（不再是 NULL）**——真内核必须有 DTB
- 分区：FAKE 64K → 3M（`partition_table.json`），bootloader 拷贝长度按分区实际大小算，不再写死 4096；后续内核变大只改分区
- 代价：PSRAM 顶部几 KB 永久保留（最小 DTB 约 1~2KB，8MB 里可忽略）

## 内核怎么知道内存有多大：memory 节点是唯一来源

### 问题

bootloader 跳转内核后，内核怎么知道可用内存多大、范围从哪到哪？

### 结论

内核**不探测内存，只信 DTB 的 `/memory` 节点**。bootloader 的 a1 只告诉内核 DTB 在哪个地址；内存范围是 DTB 的内容，不通过寄存器参数传。

### 分析过程（可复现）

1. **读 memory 节点**：`parse_dtb()` → `early_init_dt_scan()` → `early_init_dt_scan_memory()`（`drivers/of/fdt.c:1036`）。扫 DTB 根下所有 `device_type = "memory"` 的节点，读 `reg` 属性的 `(base, size)` 对。
2. **登记 memblock**：每条调 `early_init_dt_add_memory_arch(base, size)` → 最终 `memblock_add(base, size)`（`fdt.c:1158` 结尾）。RISC-V 没覆盖这个弱函数，用通用版。
3. **算范围、减保留区**：`setup_bootmem()`（`arch/riscv/mm/init.c:217`）→ `phys_ram_base = memblock_start_of_DRAM()`、`phys_ram_end = memblock_end_of_DRAM()`；再划掉内核镜像（init.c:237）、DTB（init.c:307）、initrd、reserved-memory，剩下才是可分配页。

### 具体到我们的板子（S3 的 DTB 要写）

```dts
memory@11000000 {
    device_type = "memory";
    reg = <0x11000000 0x00800000>;
};
```

内核看到就认为物理内存是 `[0x11000000, 0x11800000)` 共 8MB，再自己扣掉内核镜像和 DTB。

### 证据与坑

- 证据：S2 QEMU 日志 `Normal [mem 0x0000000080000000-0x0000000087ffffff]` = 启动参数 `-m 128M`，来源就是 QEMU 自动生成的 memory 节点。
- 坑：memory 节点写错，内核就以为内存是错的（base 写偏，PSRAM 起点就偏）；漏写可能直接起不来。这是「内核知道有 PSRAM」的唯一入口，S3 写 DTB 时第一优先级。
- 边界：rv32 的物理地址上限是 32 位（`MAX_MEMBLOCK_ADDR = ~0`），0x11000000 没有溢出问题。

## bootloader 死后，SRAM / SCRATCH / XIP_RAM 怎么处理

### 问题

bootloader 在 flash 上 XIP 执行、跳转后就死了；主 SRAM 512KB、XIP_RAM 16KB、SCRATCH_X/Y 各 4KB 这些内存，内核能使用吗？需要处理吗？

### 结论

- bootloader 跳转后确实「死了」：代码不再执行，留在 SRAM 的栈/数据随之作废；但死 ≠ 自动交给内核——内核认内存的唯一渠道还是 DTB 的 memory 节点，没声明的地方对内核就是「不存在」，无需处理。
- S3 只声明 PSRAM（`0x11000000` 8MB）；其余内存全部不声明、自动闲置。

### 这些块是什么（先纠正认知）

- 520KB 主 SRAM 是一整块连续的 `0x20000000`–`0x20081FFF`：前 512KB 是普通 RAM，最后 8KB 就是 SCRATCH_X（0x20080000，4KB）+ SCRATCH_Y（0x20081000，4KB）——同一块 SRAM 的尾巴，SDK 单独命名是 bootrom/调试器习惯用途（pico-sdk `default_locations.ld`）。
- XIP_RAM 16KB @ `0x13FFC000` 不是普通 SRAM，是 cache-as-SRAM 窗口：RP2350 用 pin 缓存行实现「缓存当 RAM」（手册 4.4.1.3；bootrom 也在 0x13ffc000-0x14000000 找 RAM 镜像）。语义特殊，不是即插即用内存。

### 为什么 S3 不用（三个理由）

1. 非连续内存是墙：PSRAM（0x11000000）和 SRAM（0x20000000）间隔约 232MB 空洞；noMMU + FLATMEM 页框连续编号，空洞需要 pfn_valid 处理——值得单独实验，不跟 S3 混变量。
2. XIP_RAM 特殊：pin 缓存行、与 XIP 缓存互相影响、pico-sdk 有专门 xip_ram 链接脚本。
3. 收益小：8MB PSRAM 足够内核 + 后续 rootfs；SCRATCH 8KB / 缓存窗口 16KB 对 Linux 是蚊子腿。

### SRAM 的未来价值（为什么现在闲置 ≠ 永远没用）

RP2350 的 AMO / lr-sc 原子操作只支持 SRAM，PSRAM 上触发 Store/AMO Fault（手册 MCAUSE CODE 7，见 PLAN.md 硬件墙）。以后内核跑到自旋锁/原子变量可能撞墙，届时 SRAM 是「放需要原子操作的数据」的候选地（S4/S5 的事）。

## 参考

- `arch/riscv/kernel/setup.c`（parse_dtb / setup_arch / unflatten_device_tree）
- `arch/riscv/mm/init.c`（setup_bootmem / paging_init / memblock_reserve）
- `notes/QEMU-virt-DTB参考.md`（S3 最小 DTB 的形状来源）
