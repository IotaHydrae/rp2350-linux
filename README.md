# RP2350 Linux 移植（riscv32 NOMMU · 从 bootloader 到 shell）

> 把主线 Linux（RISC-V 32 位、无 MMU、M 模式）跑上自研 **RP2350A-Minimal** 板的 RISC-V 核。从自己写 bootloader 开始，一步一个可复现的里程碑，串口日志是唯一的裁判。
>
> 这是一个**边做边学**的项目：代码由 AI 写、方向由人拍、每个节点真板验收，每关都有完整的实验记录（`notes/`）。

## 现在跑到哪了

| 阶段 | 工程 | 验证内容 | 状态 |
|---|---|---|---|
| S1 | `s1/` | bootloader 从 flash 拷镜像到 PSRAM 并跳转 | ✅ |
| S2 | `s2/` | QEMU 跑通 riscv32 NOMMU 真内核 | ✅ |
| S3-00 | `s3/00_amowall/` | 真板引导撞出 PSRAM AMO 墙（静默卡死 + GDB 抓现场） | ✅ |
| S3-01 | `s3/01_earlycon/` | AMO/amocas 模拟器跨墙，earlycon 出字 + 故意看到 init_IRQ panic | ✅ |
| S3-02 | `s3/02_timer/` | 定时器链：init_IRQ panic 消失、jiffies 动起来 | ✅ |
| S3-03 | `s3/03_irq/` | Xh3irq 外设中断：软件触发 IRQ 33 → handler 输出 `!`；ttyAMA0 console 提前打通 | ✅ |
| S3-04 | 待建 | 真 console 收尾（VT 恢复、console 参数） | ⬜ |
| S3-05 | 待建 | 板子上进 shell（initramfs + busybox） | ⬜ |

当前板子里烧的是 S3-03 的干净内核（启动日志到 `Kernel panic: VFS: Unable to mount root fs`——没有 rootfs 的**预期终点**）。

## 快速开始（跟着做就能看到日志）

### 1. 硬件与工具

- 自研 RP2350A-Minimal 板（16MB flash、8MB PSRAM，PSRAM 片选 = GPIO0）
- UART0（GP16/17，115200）接 USB 转串口，看日志
- Linux 开发机：`riscv64-linux-gnu-gcc`、`cmake`、`ninja`、`picotool`、`dtc`、`qemu-system-riscv32`、`gdb-multiarch`、`openocd`（完整搭建见 [`notes/环境搭建.md`](notes/环境搭建.md)）
- pico-sdk：`/home/developer/raspberrypi/pico-sdk`（含 RISC-V 裸机工具链）

### 2. 构建

```sh
make all                        # 编译全部 bootloader（不要加 sudo）
make build/s3/03_irq/rp2350a-minimal.dtb   # 编译 03 的 DTB
make kernel-s3-03               # 一键：配置 → 编译内核 → 拷贝到工程目录
```

内核源码在 `/home/developer/linux-7.2`，构建目录 `build-rv32-03`（out-of-tree，不污染源码树）。每个工程一份**完整 defconfig**，构建时拷进构建目录做 `.config` 种子再 `olddefconfig`。

### 3. 烧录（BOOTSEL 模式）

```sh
make flash-s3-03-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s3-03-kernel
make flash-s3-03-dtb
```

### 4. 观察

上电看串口（115200）。预期：bootloader 拷贝日志 → 内核 banner → `ttyAMA0 ... is a SBSA` → console 接管 → 一路到 VFS 无 rootfs panic（当前阶段终点）。

### 5. 调试（真板卡死时）

```sh
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"
```

```text
gdb-multiarch /home/developer/linux-7.2/build-rv32-03/vmlinux
set architecture riscv:rv32
target remote :3333
monitor reset halt
```

完整教程（断点/单步/源码/寄存器/TUI 分屏/抓第一现场）：[`notes/OpenOCD-GDB调试教程.md`](notes/OpenOCD-GDB调试教程.md)。

## 目录结构

```text
s1/             S1：分区表 + bootloader + 假镜像
s2/             S2：QEMU 跑真内核（config 碎片已废弃，保留脚本）
s3/             按里程碑分工程：00_amowall / 01_earlycon / 02_timer / 03_irq
                  （每个工程自带 README 实验手册 + bootloader + dts + kernel-Image + 完整 defconfig）
tests/          PSRAM 测试程序（amo-test、xip-stress 等）
boards/         自研板 pico-sdk 板级头文件
notes/          学习真源：学习地图 / 学习记录 / 实验日志 / 各种速查
PLAN.md         产品与工程现状（真源之一）
```

## 怎么学（文档导航）

- [`notes/学习地图.md`](notes/学习地图.md) —— 项目全景 + 当前进度 + AI 续学交接单（新对话先读它）
- [`notes/学习记录/`](notes/学习记录/) —— 每关一篇复盘文（S3-01 五关踩坑、S3-02 定时器链、S3-03 Xh3irq）
- [`notes/实验日志/`](notes/实验日志/) —— 真机原始日志存档
- [`notes/内核AMO模拟器详解.md`](notes/内核AMO模拟器详解.md) —— 看不懂源码也能懂的逐段教学
- [`notes/内核改动记录与溯源.md`](notes/内核改动记录与溯源.md) —— 每笔内核改动 + commit id，可 `git show` 溯源
- [`notes/环境搭建.md`](notes/环境搭建.md) —— 工具链/构建环境
- [`notes/RISC-V调试与反汇编速查.md`](notes/RISC-V调试与反汇编速查.md) · [`notes/RISC-V汇编指令速查.md`](notes/RISC-V汇编指令速查.md) —— 查手册用
- `exercises/` —— 每关配套练习题（答案折叠）

## 工程师速览

### 移植形态

- **riscv32 NOMMU M-mode**：`CONFIG_MMU=n`、`CONFIG_ARCH_RV32I=y`、M 模式直接跑（无 SBI/OpenSBI）
- 内核 Image 加载到 **PSRAM 0x11000000**（8MB），DTB 到 **0x11700000**，跳转协议 `a0=hartid, a1=dtb`
- UART0 是 ARM PL011（`arm,sbsa-uart` compatible 接入——RISC-V 无 AMBA 总线，platform 驱动版本零内核改动可用）
- 中断：标准 `riscv,cpu-intc`（MTIP/MEIP）+ 自定义 **Xh3irq**（52 线 CSR 数组，非标准 PLIC，自写 irqchip）
- 定时器：SIO MTIME/MTIMECMP，1MHz tick（与 sys_clk 解耦），自写 clocksource/clockevent

### 三大硬件墙（本项目最值钱的经验）

1. **PSRAM 上的 AMO 会 fault，LR/SC 会静默失败**：排他监视器只认 SRAM（手册 2.1.6）。AMO 触发异常可模拟；LR/SC 的 `sc.w` 静默返回失败，循环永不退出——所以 cmpxchg 和所有条件原子操作都强制走 `amocas.w`（AMO 编码 → fault → 模拟器兜底）。详见 [`内核AMO模拟器详解.md`](notes/内核AMO模拟器详解.md)。
2. **Xh3irq 不是 PLIC**：没有 claim 寄存器，最高优先级中断从 MEINEXT CSR 读（带 UPDATE 同指令），电平源在 handler 清源前一直 pending——无 handler 的中断必须 mask，否则 chained handler 死循环。MEIEA 复位还有幽灵位（IRQ 3/14 默认已使能），驱动 init 要清空。
3. **RP2350 非对齐 32 位 load 返回 0xf0000000**（不 fault 不拆分）：指令取指必须按半字拼装。

### 内核改动

全部 8 笔提交（含已回退的临时补丁）与动机，见 [`notes/内核改动记录与溯源.md`](notes/内核改动记录与溯源.md)。配置走**完整 defconfig**（每个工程一份），不用 merge_config 碎片（alldefconfig 会打开 MMU、savedefconfig 会丢 `ARCH_RV32I`）。

## 已知边界

- 单核（SMP=n）；Xh3irq 全同优先级（16 级抢占未做）
- rv32 的 64 位原子（cmpxchg64）仍是 LR/SC，未收口
- 真实 UART RX 中断需要 tty open（进 shell 后自然可用）
- 挂起板 Waveshare RP2350B-Plus-W（PSRAM 写卡死，等硬件排查）

## 复现与贡献

每个工程目录的 README 就是该关的复现手册（构建/烧录/预期日志/已知问题）。想从某一关开始复现，直接进对应目录照做。实验记录欢迎对照真机日志核对；发现问题先看 [`学习地图.md`](notes/学习地图.md) 的"现在在哪"。
