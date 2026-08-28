# PLAN · RP2350 Linux 移植（riscv32 NOMMU）

> 项目学习笔记真源在 `notes/`（本仓库，随 git 提交）；本文件管「产品是什么 + 怎么跑」。数据手册参考：`rp2350-datasheet.pdf` / `rp2350-datasheet.txt`。

## 产品一句话

把 Linux（RISC-V 32 位、无 MMU）移植到 Waveshare RP2350B-Plus-W 的 RISC-V 核（Hazard3，RV32IMAC）上。从自写 bootloader 开始，终点：板子串口能进 Linux shell。

## 剧本场景

- 烧录：电脑编译 bootloader + 镜像，用 picotool / openocd 烧进 16MB flash。
- 上电：bootloader 初始化 PSRAM → 把镜像从 flash 拷到 `0x11000000` → 跳转 → 串口看到每步日志。
- 里程碑：S1 假镜像链路 → S3-00 真内核在板子串口打出第一行字并**故意看到 panic**（init_IRQ "No interrupt controller found."）→ S3-01 earlycon 出字 + 故意 panic 验收 → S3-02 定时器链（jiffies 动）→ S3-03 Xh3irq 外设中断 → S3-04 真 console ✅ → **S3-05 进 shell ✅** → **S4 文件系统篇：S4-00 ✅（rootfs 独立烧录）→ S4-01 ✅（shell 调用外部程序）→ S4-02 ✅（ext2 真实文件系统 on brd）→ S4-03 ✅（根切 ext2）→ S4-04 🔄（busybox 移植）→ S4-05+（fs 延伸，待定）** → **S5 裁剪优化（bootloader 频率、内核压缩、zram，系统更轻快）** → **S6 RP2350 外设控制器（i2c/spi/watchdog/dma/pio，i2c/spi 用传感器/屏幕验收）** → **S7 双核 AMP + rpmsg（阶段拆分待定）** → **S8 电源管理（PM，范围待拍）**。

## 形状与分工（已拍）

- 路线 A：自写最小 bootloader + 主线 Linux 内核 + 自写设备树 + QEMU 当测试台。
- 分工：代码由 AI 写；方向性决策用户拍；每个节点用户真板验收。
- 学习目标：能讲出原理（给一块陌生板子，能说出要摸清哪几件事、找谁要答案）。

## 关键事实与决策依据（数据手册原文在 `rp2350-datasheet.txt`）

- PSRAM：QMI CS1（片选 = GPIO47，用户查原理图确认），XIP 映射 `0x11000000`（手册 4.4）。
- UART0：`0x40070000`，PL011 r1p5 → Linux 自带 pl011 驱动可用（手册 UART 章节）。
- RISC-V 定时器：SIO 内标准 MTIME/MTIMECMP（手册 3.2）。
- 中断控制器：XH3IRQ，52 条外部线、16 级抢占（手册 3.8.6.1）。
- 硬件墙：AMO / lr-sc 只支持 SRAM，PSRAM 上会触发 Store/AMO Fault（手册 MCAUSE CODE 7）→ S3/S4 亲手撞。
- Hazard3：RV32IMAC + Zba/Zbb/Zbs/Zbkb/Zcb/Zcmp/Zicsr。
- S3 布局（2026-08-25 拍板）：内核 Image @ `0x11000000`；DTB @ PSRAM 顶部 `0x11700000`（DTB 解析后数据已死，但内核 `setup_bootmem()` 会 memblock 永久保留，分析见 `notes/DTB生命周期与布局分析.md`）；跳转 a1 传 DTB 地址；FAKE 分区 64K → 3M（拷贝长度按分区实际大小算，后续内核变大只改分区）。
- MTIME 频率：pico-sdk `runtime_init_clocks()` 用 clk_ref(12MHz)/12 启动全部 tick 生成器 → MTIME 1MHz → DTB `timebase-frequency = <1000000>`（手册 8.5 / 3.1.8）。

## 待定决策

- 内核版本：**linux 7.2**（用户 2026-08-21 拍板，kernel.org 下载源码，S2 使用）。
- PSRAM 片选脚：S1 确认（候选 GP0/8/19/47；pico-sdk `hardware_psram` 可自动探测）。
- 主力板：自研 RP2350A-Minimal（RP2350A 封装，16MB flash，8MB PSRAM，CS1 = GPIO0，已实测正常）。自写 `boards/rp2350a_minimal.h`。
- 挂起板：Waveshare RP2350B-Plus-W（RP2350B，16MB flash，8MB PSRAM，CS1 = GPIO47）——两条驱动都能读 PSRAM ID 但写地址空间卡死，已换过 PSRAM 芯片仍复现，疑时序问题，等用户研究后再回来处理。配置保留在 `boards/waveshare_rp2350b_plus_w.h`。
- 串口引脚/波特率：沿用用户工程 UART0 GP16/17 @ 115200（与内核 console 保持一致）。
- **双核路线（2026-08-28 用户拍板）**：SMP 不做（riscv NOMMU M-mode 无 MMU/SBI，Linux SMP 机制按 MMU+SBI 设计，等于重写整套）；AMP 可行——bootloader 起 core1 跑裸机/RTOS 程序，Linux（core0）用 rpmsg 通信。硬件基础：SIO 双邮箱 FIFO + 32 自旋锁 + 每核 MTIMECMP + Xh3irq 每核路由；共享地址空间需划分 SRAM/PSRAM 地盘。
- **S8 PM 范围定案（2026-08-28）**：CCF 时钟树默认放 S8 开头当 PM 地基（S6 外设若卡时钟则提前到 S6 开头）；候选 += CPU idle（WFI+tickless 可观察）、DVFS（测电流）；不建议一上来做 suspend/deep sleep（唤醒源/USB/串口保持坑深难验收）。注意：S5 的 bootloader 频率调整是 bootloader 侧 SDK 配 PLL，与内核 CCF 两个层次。

## 怎么跑（构建/部署级，随阶段补充）

- 环境：`PICO_SDK_PATH=/home/developer/raspberrypi/pico-sdk`；已有 qemu-system-riscv32、picotool、riscv64-linux-gnu-gcc、dtc、cmake、ninja。
- 内核源码：`/home/developer/linux-7.2`（已建 git 仓库，初始提交 `f94a4e629`（作者 Wooden Chair <hua.zheng@embeddedboys.com>）；构建产物 `build-rv32/` 已加 .gitignore；后续移植改动按功能提交）。
- 缺：pico-sdk 的 RISC-V 裸机工具链（`riscv-none-elf-gcc`）→ S1 开工时联网安装（官方 riscv-toolchain）。
- 工具链手动安装（用户下载）：`https://github.com/raspberrypi/pico-sdk-tools/releases/download/v2.0.0-5/riscv-toolchain-14-x86_64-lin.tar.gz`，解压后 `PICO_TOOLCHAIN_PATH` 指到含 `bin/` 的目录。
- 烧录方式：每个例子一条 Makefile 目标（`make flash-bootloader` / `flash-fake` / `flash-psram-test`，BOOTSEL 模式 + picotool；openocd rp2350-riscv 备选）。
- 免 root 访问 USB：`sudo cp udev/99-rp2350.rules /etc/udev/rules.d/ && sudo udevadm control --reload-rules && sudo udevadm trigger`，然后重插设备（RP2350 BOOTSEL = 2e8a:000f；运行固件 CDC = 2e8a:0009）。
- 工程模板惯例（参考 `/home/developer/iotahydrae/rpi-pico-lab/` 下的项目）：每个工程 `CMakeLists.txt + main.c + pico_sdk_import.cmake`；环境由 `tools/envsetup.sh` 设置（`PICO_SDK_PATH=$CWD/pico-sdk`）；调试烧录用 DAPLink + OpenOCD 脚本（rp2350-riscv 用 `rp2350-riscv.cfg`）。
- 目录结构：`s1/partition-table/`（S1 主线）、`s1/fixed-offset/`（归档）、`s2/`（内核 + qemu 脚本）、`s3/00_amowall/`（S3-00 工程：bootloader + dts + partition_table.json）、`tests/`；根 CMakeLists 统管构建。
- S3-00 分区：partition 0 = KERNEL @ 64K size 3M（`picotool load -p 0 s2/kernel-Image`）；partition 1 = DTB @ 3M+64K size 64K（`picotool load -p 1 build/s3/00_amowall/rp2350a-minimal.dtb`）；bootloader 目标 `s3-00-bootloader`。

## 变更记录（翻案纪律：改了当场记，写旧方案 + 为什么翻）

-（暂无）
