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
| S3-04 | `s3/04_console/` | 真 console 收尾：ttyAMA0 确定接管日志（sbsa-uart 定案） | ✅ |
| S3-05 | `s3/05_shell/` | 板子串口进 shell（initramfs + 自写 /init，`# hello` → Hello, world!） | ✅ |
| S4-00 | `s4/00_boot-initramfs/` | rootfs 独立分区：bootloader 拷 initramfs，改 rootfs 不重烧内核 | ✅ |
| S4-01 | `s4/01_exec-hello/` | shell 调用外部程序 /bin/hello（NOMMU 进程创建：vfork/execve/waitid） | ✅ |
| S4-02 | `s4/02_ext2/` | ext2 真实文件系统 on brd（RAM 块设备挂真实文件系统格式） | ✅ |
| S4-03 | `s4/03_root-ext2/` | 根切 ext2：内核 legacy initrd 链直接挂根，执行根里 /init | ✅ |
| S4-04 | `s4/04_busybox/` | busybox 移植（riscv32 NOMMU：uClibc + bFLT + hush + 行编辑） | ✅ |
| S4-05 | `s4/05_buildroot-rootfs/` | buildroot 组装 rootfs（skeleton/overlay /init/ext2 目标），为 flash 路线铺路 | ✅ |

当前板子里是 S4-05 工程（banner `s4-05 buildroot-rootfs`）：buildroot 组装的 rootfs + busybox 29 applet。最新状态以 [`notes/学习地图.md`](notes/学习地图.md) 的"现在在哪"为准。

**接下来**：S5 裁剪优化（内核瘦身/镜像/XIP/flash 路线）→ S6 RP2350 外设控制器（i2c/spi/watchdog/dma/pio）→ S7 双核 AMP + rpmsg → S8 电源管理（CCF 时钟树 / CPU idle / DVFS）。

## 快速开始（跟着做就能看到日志）

### 1. 硬件与工具

- 自研 RP2350A-Minimal 板（16MB flash、8MB PSRAM，PSRAM 片选 = GPIO0）
- UART0（GP16/17，115200）接 USB 转串口，看日志
- Linux 开发机：`cmake`、`ninja`、`picotool`、`dtc`、`qemu-system-riscv32`、`gdb-multiarch`、`openocd`（完整搭建见 [`notes/环境搭建.md`](notes/环境搭建.md)）

### 1.5 准备工具链与内核源码

本项目需要**两套 RISC-V 工具链**，各管一段（S4-04 busybox 会加第三套：riscv32 用户态 uClibc-ng + elf2flt，由 buildroot 生成，构建中）：

**① bootloader 工具链（RISC-V 裸机，编译 pico-sdk 固件）**

树莓派官方 `pico-sdk-tools` 发布的 riscv-toolchain-14（约 850MB）：

```bash
mkdir -p ~/toolchain && cd ~/toolchain
wget -c https://github.com/raspberrypi/pico-sdk-tools/releases/download/v2.0.0-5/riscv-toolchain-14-x86_64-lin.tar.gz
tar xzf riscv-toolchain-14-x86_64-lin.tar.gz -C ~/toolchain
ls ~/toolchain/bin/riscv32-unknown-elf-gcc   # 验证
export PICO_TOOLCHAIN_PATH=~/toolchain        # pico-sdk 靠它找编译器
```

（GitHub 直连慢可以用加速镜像，下载后务必确认 `riscv32-unknown-elf-gcc` 存在。）

**② 内核工具链（交叉编译 Linux，apt 安装）**

```bash
sudo apt install gcc-riscv64-linux-gnu
riscv64-linux-gnu-gcc --version              # 验证
```

> **为什么"riscv64"工具链能编 rv32 内核？** RISC-V 工具链是 multilib 的：`riscv64-linux-gnu-gcc` 既能输出 64 位也能输出 32 位代码。编译内核时，构建系统看到 `CONFIG_ARCH_RV32I` 会自动加 `-march=rv32... -mabi=ilp32`，把编译器"降级"成 32 位模式。另外内核**不链接 libc**（它自己就是操作系统，裸机起步），所以工具链带不带 Linux 标准库都不影响——选它只是因为是内核开发的标准选择、`apt` 一条命令装好。bootloader 的 `riscv32-unknown-elf` 也能编内核，但那是裸机工具链，少 Linux 相关的头文件与约定，不是主路。

**③ 内核源码（kernel.org 下载 linux-7.2）**

```bash
cd ~
wget -c https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz
tar xJf linux-7.2.tar.xz
cd linux-7.2 && git init && git add -A && git commit -m "import: Linux 7.2 pristine source"
```

（最后一步 git 初始化是本项目的约定：所有移植改动按功能提交、带 commit id 可溯源，见 [`notes/内核改动记录与溯源.md`](notes/内核改动记录与溯源.md)。）

**④ pico-sdk（bootloader 的 SDK）**

```bash
git clone -b 2.3.0 https://github.com/raspberrypi/pico-sdk.git ~/raspberrypi/pico-sdk
cd ~/raspberrypi/pico-sdk && git submodule update --init
```

### 2. 构建

```sh
make all                        # 编译全部 bootloader（不要加 sudo）
make image-s4-03                # 本关 rootfs：mkfs.ext2 → rootfs.ext2（含 /init、/bin/hello、/dev）
```

内核源码在 `/home/developer/linux-7.2`，构建目录 `build-rv32-s4-02`（out-of-tree，不污染源码树）。S4-03 无内核改动，复用 S4-02 内核；重编用 `make kernel-s4-02`。每个工程一份**完整 defconfig**，构建时拷进构建目录做 `.config` 种子再 `olddefconfig`（不用 merge_config 碎片）。

### 3. 烧录（BOOTSEL 模式）

```sh
make flash-s4-03-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s4-03-kernel       # 复用 S4-02 内核
make flash-s4-03-dtb          # bootargs 变了，必须重烧
make flash-s4-03-rootfs       # 分区 2 = raw ext2 镜像
```

### 4. 观察

上电看串口（115200）。预期：bootloader 拷贝日志（`copy rootfs ...`）→ `RAMDISK: ext2 filesystem found at block 0` → deprecated 警告（**预期**，不是错）→ **`VFS: Mounted root (ext2 filesystem) readonly on device 1:0.`** → `Run /init as init process` → `S4-03 root ext2` → `# hello` → `Hello, world!`。

### 5. 调试（真板卡死时）

```sh
scripts/start-openocd.sh      # 一键起 openocd（cmsis-dap + rp2350.cfg）
```

```text
gdb-multiarch /home/developer/linux-7.2/build-rv32-s4-02/vmlinux
set architecture riscv:rv32
target remote :3333
monitor reset halt
```

辅助排查脚本（vmlinux 都是第一个参数）：`scripts/pc-locate.sh <vmlinux> <pc>`（PC → 反汇编/符号/源文件）、`scripts/log-analyze.sh <vmlinux> <日志>`（Call Trace 批量翻译带行号）、`scripts/gdb-dump.sh <vmlinux>`（一键抓现场）。完整教程（断点/单步/源码/寄存器/TUI 分屏/抓第一现场）：[`notes/OpenOCD-GDB调试教程.md`](notes/OpenOCD-GDB调试教程.md)。

## 目录结构

```text
s1/             S1：分区表 + bootloader + 假镜像
s2/             S2：QEMU 跑真内核
s3/             00_amowall … 05_shell（每关：README 实验手册 + bootloader + dts + kernel-Image + 完整 defconfig）
s4/             00_boot-initramfs … 03_root-ext2（文件系统篇；S4-04 busybox 待建）
scripts/        排查脚本（start-openocd / pc-locate / log-analyze / gdb-dump / verify-images / diff-kernels / pack-bflt）
tests/          PSRAM 测试程序（amo-test、xip-stress 等）
boards/         自研板 pico-sdk 板级头文件
notes/          学习真源：学习地图 / 学习记录 / 实验日志 / 各种速查
PLAN.md         产品与工程现状（真源之一）
```

## 怎么学（文档导航）

- [`notes/学习地图.md`](notes/学习地图.md) —— 项目全景 + 当前进度 + AI 续学交接单（新对话先读它）
- [`notes/学习记录/`](notes/学习记录/) —— 每关一篇复盘文（S3-01 完整踩坑、S3-02 定时器链、S3-03 Xh3irq、S4-00~S4-03 文件系统链）
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
- 根文件系统：分区 2（1MB）放 raw ext2 镜像，bootloader 拷到 PSRAM `0x11300000`，DTB `linux,initrd-*` 指向它；内核走 legacy initrd（populate_rootfs 兜底存 `/initrd.image` → rd_load_image 拷进 brd `/dev/ram0` → mount_root 按 `root=/dev/ram` 挂 ext2 为根 → 执行根里 `/init`）

### 三大硬件墙（本项目最值钱的经验）

1. **PSRAM 上的 AMO 会 fault，LR/SC 会静默失败**：排他监视器只认 SRAM（手册 2.1.6）。AMO 触发异常可模拟；LR/SC 的 `sc.w` 静默返回失败，循环永不退出——所以 cmpxchg 和所有条件原子操作都强制走 `amocas.w`（AMO 编码 → fault → 模拟器兜底）。详见 [`内核AMO模拟器详解.md`](notes/内核AMO模拟器详解.md)。
2. **Xh3irq 不是 PLIC**：没有 claim 寄存器，最高优先级中断从 MEINEXT CSR 读（带 UPDATE 同指令），电平源在 handler 清源前一直 pending——无 handler 的中断必须 mask，否则 chained handler 死循环。MEIEA 复位还有幽灵位（IRQ 3/14 默认已使能），驱动 init 要清空。
3. **RP2350 非对齐 32 位 load 返回 0xf0000000**（不 fault 不拆分）：指令取指必须按半字拼装。

### 内核改动

全部 10 笔提交（含已回退的临时补丁）与动机，见 [`notes/内核改动记录与溯源.md`](notes/内核改动记录与溯源.md)。配置走**完整 defconfig**（每个工程一份），不用 merge_config 碎片（alldefconfig 会打开 MMU、savedefconfig 会丢 `ARCH_RV32I`）。

## 已知边界

- 单核（SMP=n）；**SMP 不做**（riscv NOMMU 无 MMU/SBI，双核走 AMP + rpmsg，S7 计划）
- 根挂载默认只读（要写根，bootargs 加 `rw`）；legacy initrd 已 deprecated（2027-01 移除，当前为教学走老链）
- rootfs 载体是 brd RAM 盘：**断电即失**（持久化要 flash 驱动 + jffs2/ubifs，S6/S8 候选）
- rv32 的 64 位原子（cmpxchg64）仍是 LR/SC，未收口
- 真实 UART RX 中断需要 tty open（进 shell 后自然可用）
- 挂起板 Waveshare RP2350B-Plus-W（PSRAM 写卡死，等硬件排查）

## 复现与贡献

每个工程目录的 README 就是该关的复现手册（构建/烧录/预期日志/已知问题）。想从某一关开始复现，直接进对应目录照做。实验记录欢迎对照真机日志核对；发现问题先看 [`学习地图.md`](notes/学习地图.md) 的"现在在哪"。
