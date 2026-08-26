# S3-01 · 内核 AMO 模拟器：改动记录

> 内核仓库：`/home/developer/linux-7.2`（git，初始提交 `f94a4e629`）
> 本次提交：`ee2a9d82b` — "riscv: Add AMO/LR/SC emulation for PSRAM"
> 时间：2026-08-25 · 作者：Wooden Chair <hua.zheng@embeddedboys.com>

> 相关文档：临时诊断代码（内核直接 poke PL011 打印）见
> [S3-01 · 裸串口PL011诊断打印](./S3-01%20·%20裸串口PL011诊断打印.md)。
> 完整踩坑历程（AMO 墙 → earlycon 出字，五关日志全含）见
> [S3-01 · 从AMO墙到earlycon出字：完整踩坑历程](./S3-01%20·%20从AMO墙到earlycon出字：完整踩坑历程.md)。

## 1. 背景：为什么要改内核

00 工程（`s3/00_earlycon`）的结论：RP2350 的 Hazard3 把 AMO 实现为"排他读-写对"，而排他访问只在 SRAM 上支持（手册 3.1.5）。内核代码和数据全在 PSRAM（`0x11000000`），第一条原子操作（`start_kernel → boot_cpu_init → set_cpu_online → amoor.w` 写 `__cpu_online_mask`）就触发 mcause=7 Store/AMO fault，**早于任何 printk**，连 earlycon 都来不及注册，所以完全静默。

这不是配置能解决的——必须让内核自己响应这个异常。修法只有一条正路：**在 M 模式 trap 路径里模拟 AMO/LR/SC**。

## 2. 设计决策

### 2.1 挂钩点：`do_trap_error()` 入口（最小侵入）

异常流程：`handle_exception`（entry.S）→ 按 scause 查 `excp_vect_table` → noMMU 下访问类异常都到 `do_trap_unknown` → `do_trap_error` → `die()`/panic。

选择在 `do_trap_error` 顶部挂钩（traps.c）：

```c
static void do_trap_error(struct pt_regs *regs, int signo, int code,
	unsigned long addr, const char *str)
{
	if (try_amo_emulation(regs))
		return;
	...
}
```

理由：它是所有异常通往 die 的公共路径，加一行钩子即可；`try_amo_emulation` 内部严格按"cause 匹配 + 指令解码 + 地址范围"判断，不匹配就返回 false 走原逻辑，**对非 AMO 异常零影响**。

### 2.2 模拟语义：AMO = 读-改-写，rd 拿旧值

AMO 指令 `amoop rd, rs2, (rs1)` 的语义：`rd = 旧内存值`，`内存 = op(旧值, rs2)`。模拟器照此执行：

- 解码：opcode `0x2f`（AMO/LR/SC），funct5 区分 9 种 AMO + LR（0x02）+ SC（0x03）；funct3 必须为 `010`（word，rv32 无 `.d` 变体）。
- 地址：`rs1` 指向 PSRAM 窗口（`0x11000000`–`0x11800000`）才模拟，其他地址的 AMO 回落 die()。
- rd=0（x0）跳过写回。
- 完成后 `regs->epc += 4`，返回 true；trap 返回路径把新 epc 写回 mepc。

### 2.3 原子性论证：为什么"读-改-写"可以当原子用

两个事实叠加：
1. **单核**：CONFIG_SMP=n，只有核 0 跑内核，核 1 停在 bootrom。
2. **trap 期间 M 模式中断自动关闭**（硬件清 mstatus.MIE）：模拟的三条普通 load/store 之间不可能被中断插进来。

所以模拟的读-改-写不可被打断，等价于原子操作。

### 2.4 LR/SC：软件 reservation

内核的 `cmpxchg` 用 `lr.w`/`sc.w`（printk 环形缓冲区等路径会用到），在 PSRAM 上同样 fault，所以一并模拟：

- `lr.w`：读内存 → 记下 reservation 地址 → rd=旧值。
- `sc.w`：reservation 命中同 16 字节 granule → 写内存、rd=0（成功）；否则 rd=1（失败）。写完清 reservation。
- 任何被模拟的 AMO/SC 写到同 granule 会清掉 reservation。

已知局限：LR 与 SC 之间的**普通 store**（不 fault，不经模拟器）不会使 SC 失败——单核下实际影响极小，记录为边界。

### 2.5 寄存器访问：pt_regs 没有 regs[] 数组

第一次编译报错暴露的问题：RISC-V 的 `struct pt_regs` 是**具名字段**（ra/sp/gp/tp/t0..t6/a0..a7/s0..s11），没有 `regs[32]`。修法：`reg_by_num()` 按 RISC-V 寄存器编号（x1=ra ... x10=a0 ... x31=t6）switch 映射到对应字段，x0 返回 NULL（读取为 0、写回跳过）。

## 3. 改动清单（5 个文件，+202 行）

| 文件 | 类型 | 内容 |
|---|---|---|
| `arch/riscv/include/asm/amo-emu.h` | 新增 | `try_amo_emulation()` 声明；`#else` 分支给内联空实现，未开配置时零开销 |
| `arch/riscv/kernel/amo-emu.c` | 新增 | 模拟器主体：指令解码、PSRAM 范围检查、9 种 AMO + LR/SC、reservation 状态 |
| `arch/riscv/kernel/traps.c` | 修改 | `do_trap_error()` 顶部挂钩 + `#include <asm/amo-emu.h>` |
| `arch/riscv/Kconfig` | 修改 | 新增 `CONFIG_RISCV_AMO_EMULATION`（bool，`depends on !MMU`，help 说明 RP2350 PSRAM 背景） |
| `arch/riscv/kernel/Makefile` | 修改 | `obj-$(CONFIG_RISCV_AMO_EMULATION) += amo-emu.o` |

## 4. 编译与验证过程

```sh
# 启用配置（build-rv32 是 out-of-tree 构建目录）
scripts/config --file build-rv32/.config --enable RISCV_AMO_EMULATION
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 olddefconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 -j$(nproc) Image
```

过程中踩的坑：

1. **`regs->regs[i]` 编译错误**：pt_regs 没有数组字段（见 2.5），改 `reg_by_num()` 映射后通过。
2. **配置确认**：`grep CONFIG_RISCV_AMO_EMULATION build-rv32/.config` → `=y`。
3. **符号确认**：`nm build-rv32/vmlinux | grep try_amo_emulation` → `0000b52c T try_amo_emulation`（编进去了）。
4. 新 Image 2792176 字节（比旧版大 36 字节），拷入 `s3/01_amo-emu/kernel-Image`。

## 5. 提交信息

```
riscv: Add AMO/LR/SC emulation for PSRAM

RP2350 supports AMO/LR/SC only on main SRAM; a kernel running from
PSRAM faults (mcause 6/7) on its first atomic operation, before any
console output.  Add a trap-path emulator that decodes the faulting
AMO/LR/SC and performs the read-modify-write with plain loads/stores.
Atomicity is safe: single-hart (SMP=n) and M-mode traps disable
interrupts.  Hooked at the top of do_trap_error(); non-AMO faults
fall through to the normal die() path.

Signed-off-by: Wooden Chair <hua.zheng@embeddedboys.com>
```

格式依据：内核 `Documentation/process/submitting-patches.rst`——`subsystem: summary phrase`、祈使语气、标题 ≤75 字符；subsystem 用 `riscv:`（改的是 arch/riscv）。

## 6. 已知边界与后续

- 只模拟 PSRAM 窗口内的 AMO/LR/SC；其他地址的原子操作异常照旧 die()。
- LR/SC reservation 不感知 LR/SC 之间的普通 store（单核下影响极小）。
- rv32 只有 `.w` 变体；`.d` 是 rv64 的，未覆盖。
- 后续验证（真板）：跨过第一条原子操作 → earlycon 出字 → 预期 panic 在 `init_IRQ`（DTB 故意缺 riscv,intc）。

## 7. 复现命令

```sh
# 内核构建（见第 4 节）；工程烧录见 s3/01_amo-emu/README.md
make flash-s3-01-bootloader && make flash-s3-01-kernel && make flash-s3-01-dtb
```

## 8. 调试补充发现与更正（2026-08-25）

- **mscratch 是调试器假象**：GDB 下第一异常 mscratch=0x1120f3c0（导致处理器误走用户路径崩溃），但正常启动（内核 UART 诊断）mscratch=0、模拟器正常。OpenOCD halt/step 会弄脏 mscratch。
- **get_cycles64 崩溃更正**：不是 noMMU GOT 未重定位（setup_vm 用 PC 相对 `la` 取运行时基址，重定位正常），而是 DTB 无 clint 节点 → `clint_time_val=NULL` 解引用。修法 = 加 RP2350 MTIME clint 节点（后续工程）。
- **0xf0000000**：CPU 数据读 XIP 时间歇返回 0xf0000000，GDB 读同一地址正确；缓存开/关都出现过，间歇性。
- **xip-stress 验证硬件可靠**：从 PSRAM 执行 + 读写混合，缓存开/关 × 8MB 写读回/反复读/flash/自代码区，全 0 通过。
- **间歇性根因怀疑 = PSRAM_CS(GPIO0) 缺上拉**：Bank 0 pad 复位下拉 → 上电 CS1 被断言（手册 9.2 行 43240 明确要求外部上拉）。待用户补 10kΩ 上拉后验证。
- **当前 workaround**（bootloader）：uncached 拷贝 + 校验（保留）、缓存禁用（电阻修好后可试恢复）、跳转前清 mscratch（无害）。
- **临时内核 UART 诊断未提交**：amo-emu.c/h + traps.c 钩子在 linux-7.2 工作区（未 commit），验证完删除再提交。

详细排查见 `实验日志/2026-08-25_S3-01硬件间歇性排查.md`。
