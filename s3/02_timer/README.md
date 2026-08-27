# S3-02 · 定时器链：init_IRQ panic 消失 + jiffies 动起来

> RP2350 Linux 移植 · 工程 02：给 DTB 补 `riscv,cpu-intc` + SIO 平台定时器节点，写 `timer-rp2350` 驱动，跨过 init_IRQ 的 "No interrupt controller found." panic，让 jiffies 真正走起来。

## 这个工程验证什么

S3-01 的终点是 earlycon 出字后在 `init_IRQ` 故意 panic（DTB 缺 intc）。S3-02 补上两件事：

1. **`riscv,cpu-intc`（CPU 本地中断控制器）**：`init_IRQ` 里 `if (!handle_arch_irq) panic(...)` 不再触发——`riscv_intc_init` 注册 irq domain 并接管异常分发（cause → 对应中断）。
2. **`timer-rp2350` 驱动（SIO MTIME/MTIMECMP）**：clocksource（读 64 位 MTIME 提供时间基准）+ clockevent（写 MTIMECMP，到点触发标准 MTIP 中断）→ 时钟子系统注册成功 → jiffies 走、udelay 不再空转。

关键设计决策：**时间基准用 1MHz tick，不用 150MHz 全速**。MTIME 默认由 tick generator 供时（clk_ref 12MHz/12 = 1MHz），与 sys_clock 解耦——bootloader 改 CPU 频率不影响内核时间基准，DTB 的 `timebase-frequency = <1000000>` 可以放心写死。驱动还会兜底启动 tick generator（若 bootloader 没起）。

为什么不能直接用现成的 `timer-clint` 驱动（三个硬伤）：
1. 寄存器偏移写死（MTIME @ +0xbff8、MTIMECMP @ +0x4000），RP2350 在 SIO 的 0x1b0/0x1b8，DTB 改不了驱动里的硬编码；
2. 强制要求 timer + soft 双中断，RP2350 的软中断在 SIO 另一个寄存器（RISCV_SOFTIRQ），单核用不上 IPI；
3. MTIMECMP 用 `writeq` 低→高写入会触发假中断，RP2350 手册要求"全 1 → 高半 → 低半"顺序。

## 目录内容

- `bootloader/`、`dts/`、`partition_table.json` — 照 01 模式；DTB 新增 `timebase-frequency`、`riscv,cpu-intc`、`timer@d0000000`
- `kernel-Image` — 新内核（回退 MTIME 临时补丁 + `timer-rp2350` 驱动），构建自 `/home/developer/linux-7.2`，`O=build-rv32-02`
- `rp2350_minimal_defconfig` — 完整 defconfig（savedefconfig 导出）：在 01 基础上加 `CONFIG_RP2350_TIMER=y`
- 内核改动：`arch/riscv/kernel/setup.c` 移除临时补丁；`drivers/clocksource/timer-rp2350.c`（新驱动）；Kconfig/Makefile 挂载

## 如何复现

### 构建

```sh
make all                        # bootloader（不要 sudo）
make build/s3/02_timer/rp2350a-minimal.dtb
make kernel-s3-02               # 配置 → 编译 → 拷贝到 s3/02_timer/kernel-Image
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s3-02-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s3-02-kernel
make flash-s3-02-dtb
```

### 运行观察

正常上电，看 UART0（GP16/17，115200）。预期：

1. bootloader banner（`=== s3-02 timer bootloader ===`）+ 拷贝/校验日志
2. 内核 banner + `earlycon: pl011 at MMIO32 0x40070000`
3. `rp2350-timer: timer@d0000000: timer running at 1000000 Hz`
4. **init_IRQ 不再 panic**，启动继续推进到下一个断点（NOMMU 无 rootfs，最终停在 "Run /init as init process failed" / "No working init found" 一类的 panic——这是本工程的新验收点）

如果日志停在上一步或静默卡死：用 GDB 抓第一现场（`notes/OpenOCD-GDB调试教程.md`），重点看 `mcause`/`mepc` 和 `MIP`/`MIE` 状态。

## 验收记录（2026-08-27 ✅）

真板完整日志见 `notes/实验日志/2026-08-27_S3-02定时器链验收.md`。终点：

```text
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

本工程验收点全部达成：init_IRQ panic 消失、jiffies 动（时间戳推进 + lpj=4000 + clocksource 切换）、启动推进到无 rootfs 新断点。

### 施工中撞过的墙（速查）

1. **percpu 中断**：`riscv,cpu-intc` 的中断全是 percpu 类型，驱动必须 `request_percpu_irq` + per-cpu clockevent（普通 `request_irq` 卡在注册）。
2. **dummy console 禁 earlycon**：`CONFIG_VT=y` 注册 tty0 dummy console → printk 禁 bootconsole → 串口静默。本工程临时禁 `CONFIG_VT`；S3-04 真 console 落地后恢复（或只禁 `CONFIG_DUMMY_CONSOLE`）。
3. **LR/SC 条件原子死循环**：`arch_atomic_fetch_add_unless` 等 4 个条件原子用 LR/SC，PSRAM 上 `sc.w` 静默失败 → `deactivate_super` 死循环（Mountpoint-cache 后必现卡死）。已改为 amocas.w 循环（`CONFIG_RISCV_AMO_EMULATION` 下）。

## 已知边界

- 单核（SMP=n）：驱动用全局 clock_event_device，SMP 未验证。
- Xh3irq 外设中断控制器留到 S3-03（本工程故意不加，定时器走 MTIP 直连不需要它）。
- 真 console（ttyAMA0 接管日志）留到 S3-04（需要 clocks + Xh3irq 中断）。
- 64 位原子（`CONFIG_GENERIC_ATOMIC64` 走 cmpxchg64 LR/SC 路径）本次未触发；后续若撞到需迁到 amocas.d 并扩展模拟器。
- `CONFIG_VT` 被临时禁用（见踩坑 2）。
