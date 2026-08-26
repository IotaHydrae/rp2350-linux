# S3-00 · earlycon 工程：真板静默调试全过程

> 时间：2026-08-25 · 板子：RP2350A-Minimal（16MB flash、8MB PSRAM CS1=GPIO0、UART0 GP16/17）· 内核：linux 7.2 riscv32 noMMU M-mode
> 结论先行：**内核死在 PSRAM 上的第一条原子操作（AMO）上，早于任何日志输出**。根因 = RP2350 硬件墙：Hazard3 的 AMO 只在 SRAM 上支持。

## 0. 一页速览

| 项 | 内容 |
|---|---|
| S3-00 目标 | bootloader 加载真内核 + 最小 DTB + earlycon 出字，并看到预期 panic（故意缺 intc/timebase） |
| 实际结果 | 内核在 earlycon 之前完全静默——不是 DTB 问题，是 **PSRAM AMO 墙** |
| 死因指令 | `boot_cpu_init() → set_cpu_online() → amoor.w.aqrl` 写 PSRAM 里的 `__cpu_online_mask` |
| 异常码 | mcause=0x7（Store/AMO fault） |
| 为什么静默 | `boot_cpu_init` 是 `start_kernel` 第一件事，比任何 printk 都早，earlycon 根本没机会注册 |
| 修法方向 | M 模式 AMO 模拟器（trap 里解码 AMO 指令模拟，单核 + 中断关 = 原子性成立） |

---

## 1. 背景：S3-00 要验证什么

移植路线：S1 假镜像闭环（bootloader 拷 4KB 假镜像 + 跳转）→ S2 QEMU 跑真内核（构建 + 启动协议）→ S3 真板只接串口。

S3-00 的舞台：bootloader 从 flash 分区表读**真内核**（2.79MB）和 **DTB**，拷到 PSRAM（内核 @ `0x11000000`、DTB @ PSRAM 顶部 `0x11700000`），按 RISC-V 启动协议跳转（a0=hartid、a1=DTB 物理地址）。

DTB 按"工程按需增量"规则拆两块：`rp2350a.dtsi`（SoC 级）+ `rp2350a-minimal.dts`（板级）。00 工程**故意**只给最少量，并去掉 `timebase-frequency` 和 `riscv,cpu-intc`——原计划是让内核在 earlycon 出字后 panic 在 `init_IRQ`（"No interrupt controller found."），这一课的验收 = **earlycon 出字 + 亲眼看到 panic**。

## 2. 工程搭建

`s3/00_amowall/`：

- `bootloader/main.c`：分区表 bootloader——`rom_get_partition_table_info` 按 id 查分区扇区范围 → `memcpy` 拷内核到 `0x11000000`、拷 DTB 到 `0x11700000` → `csrci mstatus, 0x8` 关中断 → 函数指针跳转，a1=DTB 地址。
- `partition_table.json`：KERNEL id0 @64K size 3M；DTB id1 @3M+64K size 64K。
- `dts/`：cpus（无 timebase/intc）+ serial@40070000（PL011，无 clocks/interrupts）+ memory + chosen（bootargs=`earlycon=pl011,mmio32,0x40070000,115200n8`）。
- 根 Makefile：`flash-s3-00-bootloader` / `flash-s3-00-kernel` / `flash-s3-00-dtb`。

关键设计决策（已拍板）：
- 分区 KERNEL 3MB（用户拍板"先 3M，内核长大再改"）。
- DTB 放 flash 分区 1（改 DTB 只重烧分区，不动 bootloader）。
- DTB 加载到 PSRAM 顶部 `0x11700000`（内核解析后数据已死、但被 memblock 永久保留，不会覆盖；分析见 `DTB生命周期与布局分析.md`）。
- 内核镜像复用 `s2/kernel-Image`，后按用户要求拷贝进工程目录保证可独立复现。

## 3. 第一轮烧录：四个工具坑（每个都是真现象）

### 3.1 picotool 不认无扩展名文件

`picotool load -fv -p 0 s2/kernel-Image` → `ERROR: filename ... does not have a recognized file type (extension)`。

原因：picotool 靠扩展名猜文件类型，`kernel-Image` 无扩展名、`.dtb` 它也不认。修法：加 `-t bin`。

### 3.2 `-t` 必须在 `-p` 之后

`picotool load -fv -t bin -p 0 ...` → `ERROR: unexpected option: -p`。

原因：picotool 的解析器见到 `-t` 后不再接受后面的 `-p`（实测三种顺序对比确认）。修法：`-p 0 -t bin`。

### 3.3 分区 size "3M" 被解析成 0 字节（最阴的坑）

`"size": "3M"` → 烧录显示 `00010000->00010000`（0 字节）；bootloader 日志 `partition 0 sectors [16, 15] -> size 0x0`、`copy kernel 0 bytes`，然后跳到 PSRAM 残留垃圾（`first bytes: 55 5d 6d 57`），无日志。

本地验证：`picotool partition create` 一个同时含 `"3M"` 和 `"3072K"` 分区的 JSON，`picotool info` 显示 3M 分区 = 0 字节、3072K 分区 = 3MB。**picotool 只认 K 不认 M**。修法：`"3072K"`。

### 3.4 `sudo make` 污染 build 目录

`sudo make` 触发的 cmake 重建把 build 里文件变成 root 所有，之后非 root 的 ninja 报 `Error writing to build log: Permission denied`。修法：`make all` 不加 sudo，只有 `picotool` 命令需要 sudo（后来又加了 udev 规则连 sudo 都省了）。

## 4. 真板首跑：bootloader 正常，内核静默

分区修好后的日志：

```
partition 0 sectors [16, 783] -> flash 0x10010000, size 0x300000
partition 1 sectors [784, 799] -> flash 0x10310000, size 0x10000
copy kernel 3145728 bytes: flash 0x10010000 -> PSRAM 0x11000000
copy done. first bytes: b1 a8 00 00
copy dtb 65536 bytes: flash 0x10310000 -> PSRAM 0x11700000
copy done. first bytes: d0 0d fe ed
disable irqs, jump to 0x11000000 (a0=0 hartid, a1=0x11700000 dtb)
```

拷贝内容正确（内核 Image 头 `b1 a8` = c.j 跳转指令；DTB 头 `d0 0d fe ed` = FDT magic）。但跳转后**零输出**。

## 5. QEMU 二分：排除 DTB

思路：把工程 DTB 改造成 QEMU 能跑的形状（QEMU 的内存 @0x80000000、UART 是 8250 @0x10000000），用同一个内核镜像跑，看是否复现静默。

改造：memory reg 换 0x80000000、bootargs 换 `earlycon=uart8250,mmio32,0x10000000,115200n8`。

变体矩阵（T1~T7）：

| 变体 | intc | timebase | serial 节点 | QEMU 结果 |
|---|---|---|---|---|
| T1（工程原样） | ✗ | ✗ | ✓ | 首次静默（重跑正常） |
| T2 | ✓ | ✓ | ✗ | 出字（timer_probe: no matching timers） |
| T3 | ✓ | ✗ | ✗ | 出字 |
| T4 | ✗ | ✓ | ✗ | 出字 |
| T5 | ✓ | ✓ | ✓ | 出字 |
| T6 | ✗ | ✗ | ✗ | 出字 |
| T7 | ✗ | ✗ | ✓ | 出字 |

结论：所有结构变体在 QEMU 都能出 earlycon（T1 首次静默是偶发，重跑正常）→ **DTB 结构和内核启动路径没问题，静默是真板侧问题**。这也顺便在 QEMU 验证了预期行为：有 intc 无 timebase → 会走到 time_init panic；无 intc → init_IRQ panic（都在 earlycon 之后）。

## 6. 上调试器：OpenOCD + GDB

### 6.1 为什么重编译 OpenOCD

系统 OpenOCD（0.12.0+dev-02631）的 `rp2350.cfg` 用 `riscv -dap -ap-num` 建 RISC-V 目标，但它的 riscv 驱动是旧版，报 `Unknown param: -dap`。查源码确认该树 riscv 目标没有 DAP 支持（`git log -S '"dap"' -- src/target/riscv/` 为空）。修法：从 `raspberrypi/openocd` 重新编译（2026-08-25），启动日志正常：

```
Info : [rp2350.rv0] Examined RISC-V core
Info : [rp2350.rv0]  XLEN=32, misa=0x40901105
Info : Listening on port 3333 for gdb connections
```

### 6.2 连接流程

```sh
# 终端 1
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"
# 终端 2
gdb-multiarch /home/developer/linux-7.2/build-rv32/vmlinux
(gdb) target remote localhost:3333
(gdb) monitor halt
```

要点：`set USE_CORE rv0` 必须给（rp2350.cfg 默认建双 M33 核）；`monitor reg` 一次只能查一个寄存器（传多个会协议错误）。

### 6.3 第一次 halt 的困惑

`monitor halt` 后：pc=`0x11195390`（内核 `handle_exception` 入口，PSRAM 执行正常）、ra=`0x2001041c`、sp=`0x20010400`（SRAM 乱码）、mcause=6（嵌套异常现场，被处理逻辑弄脏）。

当时的解读：内核确实在 PSRAM 跑起来了、异常处理代码本身正常，但"被中断的上下文"是 SRAM 乱码——说明这是**嵌套异常**的现场，不能直接信。需要抓**第一次**异常。

## 7. 抓第一现场：AMO 墙

在异常入口下硬件断点，复位重跑，第一次进异常时寄存器还没被弄脏：

```sh
(gdb) hbreak *0x11195378       # handle_exception 入口（0x195378 + 0x11000000）
(gdb) monitor reset halt
(gdb) continue
```

结果：

```
mcause = 0x7            （Store/AMO fault）
mepc   = 0x1100e94a     （amoor.w.aqrl a4,a3,(a5)）
ra     = 0x1119a216     （调用者，内核代码）
sp     = 0x1120df10     （内核自己的栈，PSRAM——跳转完全正常）
```

反汇编定位（`objdump -d` vmlinux）：

```
0000e926 <set_cpu_online>:
  e94a: 46d7a72f  amoor.w.aqrl  a4,a3,(a5)     ← 原子 OR 写 __cpu_online_mask
  e95c: 0107a02f  amoadd.w      zero,a6,(a5)   ← 原子加写 __num_online_cpus
```

`__cpu_online_mask` 链接在 `0x2ab558` → 运行时 `0x112ab558`（PSRAM）。调用链：`start_kernel()` 第一件事 `boot_cpu_init()` → `set_cpu_online(0, true)` → 第一条 AMO 撞墙。

## 8. 手册佐证

RP2350 datasheet 3.1.5（Global Exclusive Monitor）：

- "The Hazard3 cores on RP2350 implement AMOs as an exclusive read/write pair that retries until the write succeeds."
- 排他访问的 reservation granule 是 **SRAM** 的 16 字节对齐区域；"Exclusive accesses are only supported on SRAM. The system treats exclusive accesses to other memory regions as ..."（异常）。

所以：内核代码和数据全在 PSRAM → 任何原子操作（AMO）都 fault。PLAN 里预告的"硬件墙"如期而至，只是它比 init_IRQ panic 更早。

## 9. 对照实验 amo-test：亲手钉死硬件行为

设计：接管 mtvec（自定义 trap handler 记录 mcause/mepc/mtval，mepc+4 跳过指令后 mret），同一个 `amoor.w.aqrl` 分别打在 SRAM 变量和 PSRAM 变量上。

真机输出：

```
SRAM  AMO: ok, var=1 (期望 1)
PSRAM AMO: TRAP mcause=0x00000007 mepc=0x100001cc mtval=0x00000000
           AMO 被跳过，变量=0 (期望仍为 0，AMO 未生效)
```

两边钉死：SRAM 上 AMO 生效；PSRAM 上同一指令 → mcause=7、指令不生效。

## 10. 结论与下一步

1. S3-00 的验收从"看到 intc panic"变成"**亲眼撞上 PSRAM AMO 墙并定位到第一条指令**"——收获更大：这是 RP2350 Linux 移植的核心矛盾，不解决它，earlycon/console/timer 全都没戏。
2. 修法正路 = **M 模式 AMO 模拟器**：自定义 trap 入口（或扩展 handle_exception 早期路径），解码 AMO 指令（amoadd/amoswap/amoor/amoand/amoxor/amomin/amomax + W/D、aq/rl 位），对非 SRAM 地址用普通 load/store 模拟，mepc+4 后 mret。原子性安全：单核 + trap 期间中断自动关闭。
3. 下一步工程：`s3/01_earlycon`（模拟器）——它让内核能跑过第一条原子操作，之后 earlycon 才可能出字。

## 附录 A：完整命令清单

```sh
# 构建
make all
make build/s3/00_amowall/rp2350a-minimal.dtb

# 烧录（BOOTSEL 模式；内核/DTB 用 -p 走分区）
make flash-s3-00-bootloader
make flash-s3-00-kernel
make flash-s3-00-dtb

# 对照实验（会覆盖 flash 开头的 bootloader）
make flash-amo-test

# 调试（OpenOCD + GDB）
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"
gdb-multiarch /home/developer/linux-7.2/build-rv32/vmlinux
```

## 附录 B：关键源码 / 手册位置

- 内核异常入口：`arch/riscv/kernel/entry.S:128`（handle_exception）
- 内核启动第一条原子：`init/main.c`（start_kernel → boot_cpu_init）→ `arch/riscv/kernel/smpboot.c`（set_cpu_online）→ `include/linux/cpumask.h`（amoor）
- 内核启动顺序：`arch/riscv/kernel/head.S:210`（_start_kernel）
- 手册：`rp2350-datasheet.txt` 3.1.5（排他访问 / AMO 只在 SRAM）

## 附录 C：时间线

1. 工程搭建 + 构建通过 → 2. 烧录四坑（-t bin / 顺序 / 3M→3072K / sudo 污染）→ 3. 真板静默 → 4. QEMU 二分排除 DTB → 5. 重编译 OpenOCD → 6. GDB 第一现场（amoor.w mcause=7）→ 7. 手册佐证 → 8. amo-test 对照实验钉死 → 9. 结论：AMO 模拟器。
