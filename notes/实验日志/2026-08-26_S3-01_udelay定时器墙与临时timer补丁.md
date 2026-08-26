# 2026-08-26 · S3-01 卡在 udelay：缺失 timer（clint_time_val=NULL）与临时补丁

> 板子：RP2350A-Minimal · 内核：linux 7.2 riscv32 noMMU M-mode + AMO 模拟器（临时诊断版）
> 现象：amocas 方案后内核大幅推进（earlycon 相关 printk 全部正常，大量 `f=00000005 ok`），但最终又静默卡死。GDB 抓到 PC=`0x1118e900`（link `0x18e900`，`udelay` 计算路径）。

## 卡死机制（完整链条）

1. `udelay`/`__delay` 依赖 `get_cycles()` 作为时间源：
   - M-mode 下 `get_cycles()` = `readl_relaxed(clint_time_val)`（arch/riscv/include/asm/timex.h）。
   - `clint_time_val` 由 clint 驱动（timer-clint.c）在 probe 时设置；DTB 没有 clint 节点 → **指针保持 NULL**。
2. NULL 解引用 → 读地址 0。**RP2350 读地址 0 不 fault**（像非对齐读一样返回垃圾，这里是 bootrom 内容），所以没有 diag、没有 panic。
3. `loops_per_jiffy` 在 .data 里初始值就是 4096（非零）→ 任何 `udelay(usecs)` 至少算 1 个循环 → `__delay` 里 `(get_cycles() - t0) < cycles` 用恒定垃圾时间永远成立 → **死转**。

结论：这是计划中的 **S3-02 定时器墙**——内核现在需要真实时间源，而 DTB 按 S3-00 设计故意没给 timer/intc。

## 附带观察（不是卡死原因）

- 日志里大量 `desc_make_final` 的 `fail exp=7ffff8xx old=bffff8xx`：期望 state=committed(01)、实际 state=finalized(10)、**ID 相同**——这是"描述符已被 finalize"的良性竞态失败，内核无害返回，属正常 printk 路径。
- `debug_locks_off`（`0xfb0c4`）的 amoswap 出现过一次——说明有 WARN/BUG/panic 路径被触发（可能正是 init_IRQ 的 panic），但打印过程被 udelay 卡住。

## 临时补丁（S3-02 回退）

`arch/riscv/kernel/setup.c` `setup_arch()` 开头（已加 `#include <asm/clint.h>`）：

```c
/* TEMPORARY RP2350 port workaround (revert in S3-02) */
writel(0x0000000f, (void __iomem *)0xd00001a4);  /* MTIME_CTRL: EN|FULLSPEED|DBGPAUSE */
clint_time_val = (u64 __iomem *)0xd00001b0;      /* SIO_MTIME low half */
```

要点：
- `MTIME_CTRL` 复位 `0xd`（EN=1，但走 tick generator——`TICKS_PROC0_CTRL` 复位为 0，**tick generator 默认关闭**）。置 `FULLSPEED` 位让它直接数 150MHz sys_clk，保证在跑。
- `clint_time_val` 是内核 .bss 全局指针，bootloader 写不了（内核启动会清 .bss），只能内核自己设（或将来 clint 驱动通过 DT probe 设置）。
- FULLSPEED 下 timebase=150MHz；将来正式 clint 节点用 `timebase-frequency=<150000000>`（或切回 1MHz tick generator 用 `<1000000>`）。

## 预期下一步

udelay 恢复 → 内核推进到 `init_IRQ` → DTB 无 intc → 打出 "No interrupt controller found" panic → **S3-01 验收（earlycon 出字 + 看到 panic）达成**。
