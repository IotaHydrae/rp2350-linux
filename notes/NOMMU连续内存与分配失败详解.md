# NOMMU 连续内存与"分配失败"详解（S4-04 内存墙）

> 为什么 8MB 内存、账面上还剩 2.6MB，一个 600KB 的分配却会失败？这篇把机制拆到底：有/无 MMU 的差别、buddy 伙伴系统的 order、8MB 的物理布局、启动时序里一步步的碎片化、失败时刻的账本、以及修复为什么有效。

## 一句话结论

**NOMMU 分配器看的不是"还剩多少内存"，而是"最大的那个连续洞有多大"；buddy 还按 2 的幂向上取整给块。** 600KB 的请求必须拿到一个 1MB 的整块（order-8），而失败时最大的洞只有 256KB——所以 -ENOMEM。

## 1. 有 MMU vs 无 MMU：为什么"连续"要命

**有 MMU**：进程看到的是虚拟地址。内核分配 600KB 虚拟空间，物理页可以散落在任何地方，页表负责把它们"拼"成连续的假象。分配的是"虚拟连续"，物理碎片无所谓。

**无 MMU**：没有页表，程序眼里的地址就是物理地址。分配 600KB = 真的去找 600KB **物理连续**的空间。中间任何一个 4KB 被占用，这 600KB 就凑不出来。

这是 NOMMU 一切内存问题的根源，不是内核偷懒，是硬件没有地址翻译。

## 2. 内核怎么分配：buddy 伙伴系统与 order

Linux 物理内存用 **buddy（伙伴）系统**管理：空闲内存按 2 的幂分成不同大小的"块"，每个大小叫一个 **order**：

| order | 大小 |
|---|---|
| 0 | 4KB |
| 1 | 8KB |
| 2 | 16KB |
| 3 | 32KB |
| 4 | 64KB |
| 5 | 128KB |
| 6 | 256KB |
| 7 | 512KB |
| 8 | 1MB |
| 9 | 2MB |

关键规则：**请求向上取整到最近的 order**。要 600KB → 必须给 order-8（1MB）的整块，多的 400KB 白扔（buddy 不会只给一半）。

NOMMU 上的用户态内存分配走这条链（代码出处：`mm/nommu.c`）：

```c
/* do_mmap_private() */
order = get_order(len);              /* len 向上取整到 2 的幂 */
total = 1 << order;
base = alloc_pages_exact(total << PAGE_SHIFT, GFP_KERNEL);  /* 找一整块 */
```

而 busybox 每次 exec 的请求来自 flat 加载器（`fs/binfmt_flat.c`）：

```c
len = text_len + data_len + extra + 4;
len = PAGE_ALIGN(len);
textpos = vm_mmap(NULL, 0, len, PROT_READ|PROT_EXEC|PROT_WRITE, MAP_PRIVATE, 0);
```

text+data 是**一次**匿名映射 → 一次 order 分配。所以"程序有多大、就要多大的一块连续内存"。

## 3. 8MB 的物理布局（RP2350 PSRAM）

内存节点 `0x11000000 - 0x117fffff`，共 8MB（2048 页）：

| 区域 | 范围 | 大小 | 谁占用 |
|---|---|---|---|
| 内核 Image | 0x11000000 - 0x112ab558 | ~2.67MB | memblock 保留 |
| （缝隙） | 0x112ab558 - 0x11300000 | ~0.5MB | 自由 |
| initrd（分区 2 拷入） | 0x11300000 - 0x11400000 | 1MB | 启动时保留，populate_rootfs 后释放 |
| 自由区 | 0x11400000 - 0x11700000 | ~3MB | 自由 |
| DTB | 0x11700000 - 0x11710000 | 64KB | memblock 保留 |

启动初期，buddy 手里大概有 ~4MB 自由内存，其中最大的是 initrd 释放后的 1MB 整块 + 3MB 区。

## 4. 启动时序：碎片是怎么一步步形成的

1. **内核启动**：memblock 保留内核 + DTB + initrd 区，其余进 buddy。
2. **populate_rootfs**：ext2 不是 cpio，解不开 → 把 initrd 原始字节（1MB）拷成 ramfs 文件 `/initrd.image`——**256 个 4KB 页从自由区逐页分配**（撒在 3MB 区一带）→ 然后 `free_initrd_mem` 释放 initrd 保留区，1MB **整块**回到 buddy（这是 buddy 里最大的一块）。
3. **rd_load_image**：打开 /initrd.image（产生 page cache），把 1MB 镜像写进 `/dev/ram0`（brd）。**brd 按 4KB 页逐页分配 256 页**——buddy 从刚释放的 1MB 整块（最大的自由块）底部逐页供，把这块 1MB 啃成了 256 个"占用中"的小页。buddy 眼里它们物理相邻但逻辑上是 256 个独立 order-0 块，**占用期间永远不会合并**。1MB 整块从自由池消失。
4. **init_unlink("/initrd.image")**：那 256 个 ramfs 页释放。它们散在 3MB 区里，旁边夹着 page cache、slab，**只能局部合并**，拼不回大块。
5. **mount_root**：挂 ext2（brd），读目录/文件 → 更多 order-0 page cache。
6. **exec busybox（hush）**：要 600KB → order-8（1MB）块。此刻 3MB 区里还能找到一块 1MB 的洞（hush 成功启动了），拿走整块——**实际用 600KB，浪费 400KB**。
7. **ps / ls / cat**：再 exec → 又要 order-8。3MB 区现在被 /initrd.image 残留页 + page cache + slab 打满洞，最大只剩 256KB → **-ENOMEM → 段错误**。

## 5. 失败时刻的账本（真实日志）

```
Normal free:2696kB
Normal: 70*4kB (U) 30*8kB (U) 18*16kB (U) 15*32kB (U) 10*64kB (U)
        4*128kB (U) 1*256kB (U) 0*512kB 0*1024kB 0*2048kB 0*4096kB
```

逐项换算：

| 块大小 | 数量 | 合计 |
|---|---|---|
| 4KB | 70 | 280KB |
| 8KB | 30 | 240KB |
| 16KB | 18 | 288KB |
| 32KB | 15 | 480KB |
| 64KB | 10 | 640KB |
| 128KB | 4 | 512KB |
| 256KB | 1 | 256KB |
| **总计** | | **2696KB** |

**最大块 = 256KB（order-6）**。要 600KB（order-8）→ 必然失败。注意 0×512KB、0×1024KB——**一个 order-7/order-8 的洞都没有**。

## 6. 三个机制层原因

1. **幂次取整**：600KB 请求实际消耗一个 1MB 块。总剩余够，但"够"不是 buddy 的判断标准。
2. **brd 逐页啃掉整块**：brd 写盘是连续的顺序写，buddy 从大块底部连续供 4KB 页，物理上连成一片、逻辑上全是独立小块——**一块 1MB 的连续内存被"占用但不连续地"消耗掉**，这是碎片化最大来源。
3. **芝麻分配打洞**：ramfs 文件页、ext2 page cache、slab 全是 order-0/1/2 小分配，散落在 3MB 区里，释放后也无法跨过仍占用的邻居合并。

本质：**分配/释放的粒度是 4KB，而请求的粒度是 1MB**。小颗粒的操作把大颗粒的可用性毁掉了——这是 NOMMU + buddy 的根本矛盾，也是 uClinux 系统"二进制必须小"的底层原因。

## 7. 修复为什么有效（255KB busybox + 384KB 镜像）

两步各解决一半：

**① 裁 busybox：600KB → 256KB**
新 busybox：text 196224B + data 64736B ≈ 261KB → PAGE_ALIGN 后 = **262144B = 256KB → order-6**。需要的从"1MB 整块"降级成"256KB 块"，容易满足得多。

**② 缩镜像：1MB → 384KB**
brd 只写 384KB = **96 个 order-0 页**。buddy 从 initrd 释放的 1MB 整块底部逐页供：前 96 页从低端消耗，**上半块 512KB 从头到尾没被碰过**，保持为一个完整的 order-7 块。

于是：
- hush exec：从 512KB 块切一个 order-6（256KB），剩下 256KB 仍完整；
- ls/cat exec：再切一个 order-6——**两个进程共存**。

关键认知：**只要 brd 的写入量小于那块连续内存的一半，大块就保得住**。镜像越小，留给进程的连续块越大。

## 8. 可迁移的教训（换一块 NOMMU 板子照样适用）

- **二进制尺寸 = 每进程连续内存需求**：多调用二进制（busybox）按整份算账，进程数上限 ≈ 大连续块数；
- **根本解法是 XIP**：text 只读映射（来自 flash/文件），进程只占 data+bss+stack（~150KB），8MB 能跑一堆进程——代价是加载器/elf2flt 配置改动，留 S5；
- **碎片源要控制**：块设备（brd）按页写的背面、临时大文件（/initrd.image）、page cache，都是大块的杀手；镜像越小、临时大文件越少，碎片越轻；
- **排查口诀**：`page allocation failure: order:N` + `Mem-Info` 里的自由列表 → 先看最大块，不是看 free 总量。

## 8.5 缓解方向：内存墙怎么破（2026-08-31 分析）

**文件系统上 flash 分两层受益**：
- **载体层（MTD 挂载 jffs2/ubifs）**：rootfs 不再占 RAM（initrd 窗口 1MB + brd 盘面 512KB-1MB 全还回来），且 **brd 这个最大碎片源消失**——自由内存多 ~1.5-2MB 且更连续。这是"缓解"。
- **执行层（XIP）**：text 留在 flash 只读映射，进程只占 data+bss+stack（busybox 262KB→~150KB）——对"exec 连续内存墙"是根本解法。注意：**普通挂载 ≠ XIP**，jffs2 数据仍要读进 RAM 执行；XIP 需要 elf2flt 出 XIP bFLT + 内核 SEP_DATA 配置 + flash 地址对齐。flash 路线是 XIP 的前提（brd 块设备在 NOMMU 下无法 mmap XIP）。

**当前环境降内存手段（按杠杆排序）**：
1. 内核瘦身：Image 2.67MB 是最大头（S5 裁剪优化，可省 0.5-1MB）。
2. 镜像再缩（512KB→384KB）：brd 少写 128KB，连续块 512KB→640KB。
3. DTB initrd 窗口精确化：现在写死 1MB，/initrd.image 临时文件按 1MB 造；窗口改小则临时文件小、释放整齐。
4. busybox 精细裁剪（S5）。
5. XIP（结构性，等 flash 路线）。
6. 行为层：内建命令优先（echo/cd/pwd 不 exec），避免同时跑多个外部命令。

## 9. 在系统里看 buddy（/proc 命令，板子 shell 里直接跑）

内核崩溃/分配失败日志里的 `Mem-Info` 其实就来自这些 proc 文件，随时可以活着查：

| 命令 | 看什么 | 对应崩溃日志 |
|---|---|---|
| `cat /proc/buddyinfo` | **每 zone 每个 order 的自由块个数**——判断"最大连续块有多大"的唯一依据 | `Normal: 70*4kB ... 1*256kB` 那行 |
| `cat /proc/meminfo` | 总量账：MemFree/MemAvailable/Slab 等 | `free:674`、`slab_unreclaimable:234` |
| `cat /proc/pagetypeinfo` | 自由块按 Unmovable/Reclaimable/Movable 细分（buddyinfo 里 `(U)` 的出处） | — |
| `cat /proc/slabinfo` | slab 占用明细 | `slab_unreclaimable` |

**buddyinfo 读法**：每行一个 zone，第 3 列起依次是 order-0、order-1、… 的自由块个数；块大小 = 4KB × 2^order。要判断"能不能再 exec 一个程序"，看它需要的 order 那列是否为 0：

- 255KB busybox → order-6（256KB）列 ≥ 1；
- 两个进程 → order-6 ≥ 2，或 order-7（512KB）≥ 1（能拆出俩）。

**对照实验（验证 NOMMU 内存墙修复）**：

```sh
cat /proc/buddyinfo     # 刚进 shell：order-6/order-7 应该有货
ls /                    # 跑一个外部命令（消耗一个 256KB 块）
cat /proc/buddyinfo     # 再看：order-6/order-7 被消耗
```

注意：NOMMU 没有内存规整（compaction 需要页表），`/proc/sys/vm/compact_memory` 在无 MMU 内核上不可用——碎片只能靠"少制造"（小镜像、少临时大文件），不能靠事后合并。

## 代码出处

- `mm/nommu.c` `do_mmap_private()`：`get_order(len)` + `alloc_pages_exact()`（幂次整块分配）
- `fs/binfmt_flat.c` `load_flat_file()`：text+data 一次 `vm_mmap(..., MAP_PRIVATE, ...)`
- `init/initramfs.c` `populate_initrd_image()` / `free_initrd_mem()`：initrd 文件页分配与保留区释放
- `drivers/block/brd.c`：按页写时 `alloc_pages()` order-0
- 真机日志：`notes/实验日志/`（S4-04）
