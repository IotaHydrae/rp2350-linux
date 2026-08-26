# 2026-08-26 · S3-01 验收通过：earlycon 出字 + init_IRQ panic

> 板子：RP2350A-Minimal · 内核：linux 7.2 riscv32 noMMU M-mode + AMO/amocas 模拟器
> 结果：**S3-00/01 验收达成**——earlycon 打印内核 banner 与启动日志，内核按设计在 `init_IRQ` panic（"No interrupt controller found."，DTB 故意无 intc）。

## 最后一堵墙：CONFIG_CMDLINE_FORCE 覆盖 DTB bootargs

症状：earlycon 始终不打印，但内核能跑到 init_IRQ panic。

排查：
1. DTB 文件本身没问题（fdtget 能读出 pl011 bootargs）。
2. 加诊断打印 `cmdline:` → 内核的 boot_command_line 竟是 **QEMU 的**（`root=/dev/vda rw earlycon=uart8250,mmio,0x10000000,... console=ttyS0`）。
3. 根因：`arch/riscv/configs/nommu_virt_defconfig` 自带 `CONFIG_CMDLINE="root=/dev/vda ..."` + **`CONFIG_CMDLINE_FORCE=y`**——内核强制用编译期内置命令行，完全无视 DTB 的 bootargs。earlycon 因此一直按 `uart8250@0x10000000`（板上的 flash 地址）配置，输出进了错误地址。
4. 修复：清掉 `CONFIG_CMDLINE` 与 `CONFIG_CMDLINE_FORCE`，让内核用 DTB 的 bootargs（后并入完整 defconfig `rp2350_minimal_defconfig`，`make kernel-s3-01` 一键重建）。

## 验收日志（关键行）

```
[    0.000000] Linux version 7.2.0-gee2a9d82bc94-dirty ...
[    0.000000] Machine model: RP2350A-Minimal
[    0.000000] earlycon: pl11 at MMIO32 0x40070000 (options '115200n8')
[    0.000000] Kernel command line: earlycon=pl011,mmio32,0x40070000,115200n8
[    0.000000] Zone ranges: Normal [mem 0x11000000-0x117fffff]
...
[    0.000000] Kernel panic - not syncing: No interrupt controller found.
```

## S3-01 内核正式提交（linux-7.2，作者 Wooden Chair）

- `6860027b2` riscv: Complete AMO/amocas emulation for RP2350 PSRAM（半字取指修复 + amocas.w 模拟 + cmpxchg 强制走 amocas）
- `c8bf5c2a3` serial: Allow PL011 driver build on RISC-V（Kconfig 放宽）
- `24ad00dc9` riscv: RP2350: temporary SIO MTIME workaround for get_cycles()（**S3-02 回退**）

临时诊断打印（diag/panic/cmdline/earlycon-buf）已全部移除；成功内核存档于 `s3/01_earlycon/kernel-Image`。

## S3-02 计划（下一步）

1. 回退 `24ad00dc9`（MTIME 临时补丁）。
2. DTB 加 `timebase-frequency` + clint 节点（RP2350 SIO MTIME 布局，驱动需适配偏移）+ XH3IRQ 中断控制器 + `riscv,cpu-intc`。
3. 目标：过 init_IRQ panic，jiffies 动起来，启动推进到下一断点。
