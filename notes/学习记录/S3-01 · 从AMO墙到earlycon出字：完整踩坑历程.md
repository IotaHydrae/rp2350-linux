# S3-01 · 从 AMO 墙到 earlycon 出字：完整踩坑历程

> 板子：RP2350A-Minimal（16MB flash、8MB PSRAM CS1=GPIO0、UART0 GP16/17 @115200）
> 内核：linux 7.2 riscv32 NOMMU M-mode（内核跑在 PSRAM `0x11000000`）
> 时间：2026-08-25 ~ 08-26 · 结果：**S3-01 验收通过**（earlycon 出字 + `init_IRQ` panic）
>
> 本文是完整复盘：从起点到验收，每一关的「现象 → 排查 → 根因 → 修复 → 验证」，日志内嵌。
> 原始日志存档：`notes/实验日志/`（每关一份）；本文件是可独立阅读的完整脉络。

## 0. 起点：S3-00 留下的 AMO 墙

内核的代码和数据全在 PSRAM。RP2350 的 Hazard3 核把 AMO 实现为"排他读-写对"，而排他监视器（Global Exclusive Monitor）**只支持 SRAM**。于是内核第一条原子操作——`start_kernel → boot_cpu_init → set_cpu_online → amoor.w` 写 `__cpu_online_mask`——就触发 **mcause=7 Store/AMO 访问 fault**，早于任何 printk/earlycon，真板完全静默。

S3-00 用 GDB 抓到的第一现场：

```
(gdb) hbreak *0x1100ebc0
(gdb) monitor reset halt
(gdb) continue
Breakpoint 1, 0x1100ebc0 in ?? ()
(gdb) monitor reg mcause
mcause (/32): 0x00000007
(gdb) x/4i $mepc
   0x1100ebc0:  amoor.w.aqrl    a4,a3,(a5)     ← set_cpu_online 的位操作
   0x1100ebc4:  and     a5,a4,a3
```

S3-00 结论：这不是配置能解决的，必须让内核自己在 trap 路径里模拟 AMO。

---

## 1. 第一关：AMO 模拟器（内核侧）

### 设计（提交 `ee2a9d82b`，详见《S3-01 · 内核AMO模拟器改动记录》）

- 挂钩点：`do_trap_error()` 入口，所有访问类异常通往 die() 的公共路径。
- 语义：AMO = 读-改-写，rd 拿旧值；只模拟 PSRAM 窗口（`0x11000000-0x11800000`）内的指令。
- 原子性：单核（SMP=n）+ M 模式 trap 期间中断自动关闭 → 模拟的三条普通 load/store 不可被打断。
- 错误假设（后来被推翻）：LR/SC 在 PSRAM 上"同样 fault"，所以一并写了软件 reservation。

### 真板首跑：先撞到的是 bootloader 拷贝损坏

现象：bootloader 拷贝正常（3MB、首字节 `b1 a8 00 00`），跳转后内核零输出。GDB 三路对比：

```
(gdb) x/8wx 0x101A5644        # flash 分区 0 @ 内核偏移 0x195644
0x101a5644: 0x000462b7 0x60028293 0x00c22403 0x3002b4f3   # 正确
(gdb) x/8wx 0x11195644        # PSRAM 同一偏移
0x11195644: 0xdefedcfa 0x1118feb0 0x60028293 0x112570e4   # 隔字损坏！
```

根因：3MB 大拷贝经 XIP 写回缓存，16KB 缓存持续驱逐脏行导致丢写/写错位。修法：**拷贝走 uncached 窗口（`0x14...` 别名）+ 跳转前整段校验**（bootloader 提交 `34dedec`/`9fbd7b2` 等）。

### 间歇性卡死：疑似硬件（PSRAM_CS 上拉）

修好拷贝后仍偶发卡死（复位后恢复）。怀疑 `PSRAM_CS=GPIO0`（Bank 0）复位内部下拉 → 上电瞬间 CS1 被断言。用户补了 10kΩ 上拉后，卡死消失——但后续又出现新问题，进入下面的关卡。

> 这一段完整排查见 `实验日志/2026-08-25_S3-01硬件间歇性排查.md` 与 `2026-08-25_S3-01真板首跑.md`。

---

## 2. 第二关：非对齐 32 位读返回 `0xf0000000`

### 现象

日志反复出现同一故障循环，GDB 抓到 PC 停在 `sw a5,60(sp)`（`.Lsave_context` 保存现场序列里）：

```
[diag] c=00000007 epc=1100ed32 mscr=00000000 r2 i=f0000000 f2=f0000000
[diag] c=00000007 epc=11047d12 mscr=00000000 r2 i=f0000000 f2=f0000000
（反复）
```

### 排查

1. **怀疑 flash 写坏**：`i=` 和 `f2=`（flash 对照读）都是 `0xf0000000`，bootloader verify 却报 0 错误——一度以为是烧录坏。
2. **GDB 取证推翻**：调试口读 flash 与镜像文件逐字节一致（`0x1001ed30` = `0xa72fc185 0x77b346d7 ...`）→ **flash/PSRAM 内容都是对的**。
3. **发现地址规律**：所有 `i=f0000000` 的 epc 都是 `≡2 mod 4`；成功模拟的那次（`0x1100ece8`）是 4 字节对齐。
4. **反汇编证实**：RVC（压缩指令扩展）下，32 位指令允许从任意 16 位边界开始——`c.beqz`（2 字节）后面紧跟 4 字节 AMO，AMO 的 mepc 就是 2 mod 4，这是**合法代码**。

### 根因

诊断/模拟器代码 `insn = *(u32 *)regs->epc` 在 mepc=2 mod 4 时做了**非对齐 32 位数据 load**。RP2350 对这种读**不报错也不拆分，直接返回 `0xf0000000`**（调试口 DAP 能正确读，所以 GDB 看到真值）。

### 修复

取指改为**两个 16 位半字拼接**（半字读天然 2 字节对齐，安全），先判断低 2 位：`!=11` 就是 16 位压缩指令，绝不可能是 AMO/LR/SC，直接拒绝：

```c
u16 lo = *(u16 *)regs->epc;
u16 hi = *(u16 *)(regs->epc + 2);
insn = (u32)lo | ((u32)hi << 16);
if ((insn & 0x3) != 0x3)
	return false;	/* 16-bit compressed instruction */
```

> 附带结论：**RP2350 非对齐 32 位 load 返回 `0xf0000000`**，以后写裸机/驱动代码要避开。完整记录见 `实验日志/2026-08-26_S3-01_非对齐读根因定位.md`。

---

## 3. 第三关：LR/SC 不 fault——`sc.w` 静默失败

### 现象

修好非对齐读后，`boot_cpu_init` 的 5 条 AMO 全部被模拟（`ok`），但随后**静默卡死**。GDB：

```
(gdb) monitor reg pc
pc (/32): 0x11048f1c
(gdb) x/12i $pc-16
   0x11048f18:  lr.w    a5,(s8)
=> 0x11048f1c:  bne     a5,s6,0x11048f26
   0x11048f20:  sc.w.rl a4,s2,(s8)
   0x11048f24:  bnez    a4,0x11048f18    ← 循环
```

这是 `prb_reserve`（printk 环形缓冲区）的 cmpxchg——内核第一条打印 `pr_notice(linux_banner)` 的保留操作。

### 排查

手册 2.1.6（Global Exclusive Monitor）原文关键句：

> "Exclusive accesses are only supported on SRAM. The system treats exclusive accesses to other memory regions as normal reads and writes, reporting exclusivity failure to the originating PE, for example by a non-zero return value from an Arm strex instruction."

对比：
- **AMO**：Hazard3 实现为"排他读-写对，重试直到成功"，PSRAM 上永远失败 → 报 mcause=6/7 → 可被模拟器拦截。
- **LR/SC**：LR 是普通读 + 监视器打标；SC 检查监视器，不支持就**返回失败值（1）**，**不产生异常** → 模拟器无从拦截。

### 根因

任何 LR/SC 重试循环在 PSRAM 上都会死转，且没有 diag 可打（没异常）。S3-01 最初"LR/SC 同样 fault"的假设是错的。

### 修复：cmpxchg 强制走 amocas.w（Zacas）

`amocas.w` 是 AMO 编码（opcode 0x2f, funct5=00101），会 fault（Hazard3 没有 Zacas 解码器 → mcause=2 非法指令）→ 可被模拟器拦截。两处改动：

1. `arch/riscv/include/asm/cmpxchg.h`：`__arch_cmpxchg` 的 amocas 路径加 `|| IS_ENABLED(CONFIG_RISCV_AMO_EMULATION)`——**编译期强制**。原因：原条件 `riscv_has_extension_unlikely(ZACAS)` 依赖运行时 hwcap，而 hwcap 在 `setup_arch` 里才解析，第一次 printk 时必为 false。
2. 模拟器：允许 `EXC_INST_ILLEGAL`（2）但只放行 funct5=0x05；新增 `amocas.w` 语义：rd 既是期望值输入又是旧值输出，`old == expected` 时写 rs2。

验证：新内核 `prb_reserve` 反汇编全是 `amocas.w.aqrl`，没有 lr/sc：

```
   48bf4:	2f6727af          	amocas.w.aqrl	a5,s6,(a4)
   48c16:	2f3727af          	amocas.w.aqrl	a5,s3,(a4)
```

修复后日志：`boot_cpu_init` 的 AMO + 大量 `f=00000005`（amocas）全部 `ok`。

> 附带观察：日志里 `desc_make_final` 的 `fail exp=7ffff8xx old=bffff8xx` 是**良性竞态**（描述符已被 finalize，ID 相同、state 不同），不是卡死原因。完整记录见 `实验日志/2026-08-26_S3-01_LRSC静默失败与amocas方案.md`。

---

## 4. 第四关：udelay 死转——DTB 没有 timer（`clint_time_val=NULL`）

### 现象

amocas 全线工作后仍静默卡死，GDB 抓到 PC 在 `udelay` 计算路径：

```
(gdb) monitor reg pc
pc (/32): 0x1118e900        # link 0x18e900 = udelay 内部
```

### 排查链条

1. `udelay`/`__delay` 用 `get_cycles()` 计时；M 模式下 `get_cycles() = readl(clint_time_val)`（arch/riscv/include/asm/timex.h）。
2. DTB 没有 clint 节点 → clint 驱动不 probe → `clint_time_val` 保持 **NULL**。
3. NULL 解引用 → 读地址 0 → **RP2350 读地址 0 不 fault**（返回 bootrom 内容当垃圾时间）。
4. `loops_per_jiffy` 在 .data 初始值就是 4096（非零）→ 任何 `udelay(usecs)` 至少 1 个循环 → `(get_cycles() - t0) < cycles` 用恒定垃圾时间永远成立 → **死转**。

### 修复（临时，S3-02 回退）

`setup_arch` 开头（提交 `24ad00dc9`）：

```c
writel(0x0000000f, (void __iomem *)0xd00001a4);  /* MTIME_CTRL: EN|FULLSPEED|DBGPAUSE */
clint_time_val = (u64 __iomem *)0xd00001b0;      /* SIO_MTIME low half */
```

要点：SIO MTIME 复位使能但走 tick generator（默认关闭），置 `FULLSPEED` 让它直连 150MHz sys_clk；`clint_time_val` 是内核 .bss 全局，bootloader 写不了（内核启动会清 .bss），只能内核自己设或将来由 clint 驱动通过 DT probe 设置。

修复后内核推进到 `init_IRQ`，打出预期 panic（借助临时 `[panic]` 直打打印才看到）：

```
[panic] No interrupt controller found.
```

> 完整记录见 `实验日志/2026-08-26_S3-01_udelay定时器墙与临时timer补丁.md`。

---

## 5. 第五关：PL011 驱动没编译，earlycon 查无此名

### 现象

timer 修好后仍看不到 banner，只有 `[panic] No interrupt controller found.`。加诊断打印定位：

```
[panic] cmdline:
[panic] root=/dev/vda rw earlycon=uart8250,mmio,0x10000000,115200n8 console=ttyS0
```

### 排查

1. `CONFIG_SERIAL_AMBA_PL011` 没开（配置里只有 8250）→ `__earlycon_table` 没有 pl011 条目 → `setup_earlycon("pl011,...")` 静默失败（`Unrecognized earlycon option` 也进了环形缓冲区看不见）。
2. QEMU 时能用是因为 S2 用的是 `uart8250` earlycon。
3. 想开 pl011 又发现它的 Kconfig `depends on ARM_AMBA`（ARM 专用）→ 修改为 `depends on ARM_AMBA || RISCV`。
4. 开了驱动还不够——`OF_EARLYCON_DECLARE(pl011,...)` 整个被 `#ifdef CONFIG_SERIAL_AMBA_PL011_CONSOLE` 包着，console 选项也得开。

### 修复

- `drivers/tty/serial/Kconfig`：`depends on ARM_AMBA || RISCV`（提交 `c8bf5c2a3`）。
- 配置：`CONFIG_SERIAL_AMBA_PL011=y` + `CONFIG_SERIAL_AMBA_PL011_CONSOLE=y`。

---

## 6. 第六关（最后一堵墙）：`CONFIG_CMDLINE_FORCE` 覆盖 DTB bootargs

### 现象

pl011 编进去后仍无 banner，诊断显示内核 cmdline 还是 QEMU 的：

```
[panic] cmdline:
[panic] root=/dev/vda rw earlycon=uart8250,mmio,0x10000000,115200n8 console=ttyS0
...
[panic] earlycon-buf:
[panic] uart8250,mmio,0x10000000,115200n8
```

### 根因

`arch/riscv/configs/nommu_virt_defconfig` 自带：

```
CONFIG_CMDLINE="root=/dev/vda rw earlycon=uart8250,mmio,0x10000000,115200n8 console=ttyS0"
CONFIG_CMDLINE_FORCE=y
```

`CMDLINE_FORCE=y` 让内核**强制使用编译期内置命令行，完全无视 DTB 的 bootargs**。earlycon 因此一直按 `uart8250@0x10000000`（板上的 flash 地址）配置，输出进了错误地址。

### 修复

清掉 `CONFIG_CMDLINE` 与 `CONFIG_CMDLINE_FORCE`，让内核用 DTB 的 bootargs（并入完整 defconfig `s3/01_earlycon/rp2350_minimal_defconfig`，工程根目录 `make kernel-s3-01` 一键重建）。

---

## 7. 验收：earlycon 出字 + init_IRQ panic

修复 CMDLINE_FORCE 后的真板日志（关键行）：

```
[diag] c=00000002 epc=11048790 ... i=2947a92f a=1124645c f=00000005 ok
[panic] cmdline:
[panic] earlycon=pl011,mmio32,0x40070000,115200n8
[panic] earlycon-buf:
[panic] pl011,mmio32,0x40070000,115200n8
[    0.000000] Linux version 7.2.0-gee2a9d82bc94-dirty ...
[    0.000000] Machine model: RP2350A-Minimal
[    0.000000] earlycon: pl11 at MMIO32 0x40070000 (options '115200n8')
[    0.000000] printk: legacy bootconsole [pl11] enabled
[    0.000000] Kernel command line: earlycon=pl011,mmio32,0x40070000,115200n8
[    0.000000] Zone ranges: Normal [mem 0x11000000-0x117fffff]
...
[    0.000000] Kernel panic - not syncing: No interrupt controller found.
```

**S3-00/01 验收标准达成**：earlycon 出字 + 内核按设计在 `init_IRQ` panic（DTB 故意无 intc）。

---

## 8. 收尾：清理与提交

临时诊断（diag 预算、`[panic]` 直打、cmdline/earlycon-buf 打印）全部移除；成功内核存档 `s3/01_earlycon/kernel-Image`（sha `f56f0e0d`）。

内核（linux-7.2，作者 Wooden Chair）：

| 提交 | 内容 |
|---|---|
| `6860027b2` | riscv: Complete AMO/amocas emulation for RP2350 PSRAM（半字取指 + amocas + cmpxchg 强制） |
| `c8bf5c2a3` | serial: Allow PL011 driver build on RISC-V |
| `24ad00dc9` | riscv: RP2350: temporary SIO MTIME workaround（**S3-02 回退**） |

项目（rp2350-linux）：

| 提交 | 内容 |
|---|---|
| `cffa399` | S3-01 验收记录 + 学习地图刷新 + 配置碎片（CMDLINE_FORCE 防回退） |

---

## 9. 关键结论速查（五条"坑"）

| # | 坑 | 一句话根因 | 修法 |
|---|---|---|---|
| 1 | 非对齐 32 位读返回 `0xf0000000` | RP2350 数据路径不拆分非对齐读，直接给垃圾 | 两个 16 位半字拼接取指 |
| 2 | LR/SC 死循环无异常 | 排他监视器仅 SRAM，sc.w 静默返回失败（手册 2.1.6） | cmpxchg 强制走 amocas.w + 模拟 |
| 3 | udelay 死转 | DTB 无 clint → `clint_time_val=NULL` → 读地址 0 得恒定垃圾时间 | 临时：MTIME FULLSPEED + 设指针（S3-02 正式修） |
| 4 | earlycon 静默失败 | pl011 驱动没编（Kconfig 还限 ARM） | Kconfig 放宽 RISCV + 开 CONSOLE 选项 |
| 5 | bootargs 被无视 | `nommu_virt_defconfig` 自带 `CMDLINE_FORCE=y` | 清 CMDLINE/CMDLINE_FORCE，用 DTB bootargs |

方法论沉淀：真板静默问题三板斧——**① 先怀疑数据路径（拷贝/缓存/非对齐）② GDB 读内存对照文件（调试口路径独立）③ 在最底层直接 poke UART（绕过一切打印设施）**。三者组合，五个墙都是这么拆的。

## 下一步

S3-02：回退 MTIME 临时补丁 → DTB 加 timebase-frequency + clint 节点（RP2350 SIO MTIME 偏移 `0x1b0/0x1b8`，需驱动适配）+ XH3IRQ 中断控制器 + `riscv,cpu-intc` → 过 init_IRQ panic、jiffies 动起来。
