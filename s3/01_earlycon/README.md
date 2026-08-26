# S3-01 · earlycon 出字 + init_IRQ panic（AMO 模拟器跨墙）

> RP2350 Linux 移植 · 工程 01：给内核加 M 模式 AMO/amocas 模拟器，跨过 00 撞上的 PSRAM AMO 墙，让 earlycon 真正出字，并在 `init_IRQ` 看到预期 panic（DTB 故意无 intc）。

## 这个工程验证什么

00 的结论：RP2350 的 AMO/LR/SC 只在 SRAM 上支持，内核跑在 PSRAM 时第一条原子操作（`boot_cpu_init → set_cpu_online → amoor.w`）就触发 mcause=7，早于任何输出。

本工程在内核异常路径加了模拟器（`CONFIG_RISCV_AMO_EMULATION`）：

- `arch/riscv/kernel/amo-emu.c`：解码 AMO（add/swap/xor/or/and/min/max ±u）与 LR/SC，对 PSRAM 窗口（0x11000000-0x11800000）用普通 load/store 模拟，mepc+4 后返回。
- `arch/riscv/kernel/traps.c`：`do_trap_error()` 入口挂钩，模拟成功就 return。
- 原子性安全：单核（SMP=n）+ trap 期间 M 模式中断关闭。

预期结果：内核跨过第一条原子操作 → banner 打印 → **earlycon 注册并回放日志** → 走到 `init_IRQ`（DTB 故意没有 riscv,intc）→ **panic "No interrupt controller found."** ——这正是 00 原计划想看到的验收，现在靠模拟器达成了。

## 目录内容

- `bootloader/`、`dts/`、`partition_table.json` — 与 00 相同（DTB 仍缺 intc/timebase）
- `kernel-Image` — 带模拟器的新内核（构建自 `/home/developer/linux-7.2`，`O=build-rv32`）
- `rp2350_minimal_defconfig` — **完整**内核 defconfig（savedefconfig 导出，非碎片）：`MMU=n`、M 模式、`RISCV_AMO_EMULATION`、PL011、无 QEMU 内置命令行；只放工程内，构建时拷进 `build-rv32/.config` 再 `olddefconfig`（内核树另有一份已提交的同名快照，构建不依赖它）
- 内核补丁：`linux-7.2` 仓库提交 `ee2a9d82b`（改动记录见 `notes/学习记录/S3-01 · 内核AMO模拟器改动记录.md`）

## 如何复现

### 构建

```sh
make all                        # bootloader（不要 sudo）
make build/s3/01_earlycon/rp2350a-minimal.dtb
```

内核重建（改内核后）：

```sh
make kernel-s3-01    # 工程根目录：配置 → 编译 → 拷贝到 s3/01_earlycon/kernel-Image
```

手动等价命令：

```sh
cd /home/developer/linux-7.2
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 rp2350_minimal_defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 -j$(nproc) Image
cp build-rv32/arch/riscv/boot/Image \
    /home/developer/iotahydrae/rp2350-linux/s3/01_earlycon/kernel-Image
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s3-01-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s3-01-kernel
make flash-s3-01-dtb
```

### 运行观察

正常上电，看 **UART0（GP16/17，115200）**（内核日志走 PL011，USB 看不到内核日志）。

预期：bootloader 拷贝日志 → 内核 banner（回放）→ `earlycon: pl011 at MMIO32 0x40070000` → 内存信息 → `panic: No interrupt controller found.`（init_IRQ，DTB 故意缺 intc）。

如果仍然静默或挂住：GDB 抓第一现场（教程见 `notes/OpenOCD-GDB调试教程.md`），注意 `handle_exception` 地址会因新内核变化（`nm vmlinux | grep handle_exception` + 0x11000000）。

## 已知边界

- LR/SC 的 reservation 是软件模拟：LR 与 SC 之间若有普通 store 不会使 SC 失败（单核下影响极小）。
- 只模拟 PSRAM 窗口；其他地址上的 AMO 仍走正常 die()。
- 模拟器覆盖 rv32 的 `.w` 变体（rv32 无 `.d`）。
