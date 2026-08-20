# PLAN · RP2350 Linux 移植（riscv32 NOMMU）

> 项目学习笔记真源在 `notes/`（本仓库，随 git 提交）；本文件管「产品是什么 + 怎么跑」。数据手册参考：`rp2350-datasheet.pdf` / `rp2350-datasheet.txt`。

## 产品一句话

把 Linux（RISC-V 32 位、无 MMU）移植到 Waveshare RP2350 Plus 16MB 的 RISC-V 核（Hazard3，RV32IMAC）上。从自写 bootloader 开始，终点：板子串口能进 Linux shell。

## 剧本场景

- 烧录：电脑编译 bootloader + 镜像，用 picotool / openocd 烧进 16MB flash。
- 上电：bootloader 初始化 PSRAM → 把镜像从 flash 拷到 `0x11000000` → 跳转 → 串口看到每步日志。
- 里程碑：S1 假镜像链路 → S3 真内核在板子串口打出第一行字 → S6 进 shell。

## 形状与分工（已拍）

- 路线 A：自写最小 bootloader + 主线 Linux 内核 + 自写设备树 + QEMU 当测试台。
- 分工：代码由 AI 写；方向性决策用户拍；每个节点用户真板验收。
- 学习目标：能讲出原理（给一块陌生板子，能说出要摸清哪几件事、找谁要答案）。

## 关键事实与决策依据（数据手册原文在 `rp2350-datasheet.txt`）

- PSRAM：QMI CS1，XIP 映射 `0x11000000`（手册 4.4）。
- UART0：`0x40070000`，PL011 r1p5 → Linux 自带 pl011 驱动可用（手册 UART 章节）。
- RISC-V 定时器：SIO 内标准 MTIME/MTIMECMP（手册 3.2）。
- 中断控制器：XH3IRQ，52 条外部线、16 级抢占（手册 3.8.6.1）。
- 硬件墙：AMO / lr-sc 只支持 SRAM，PSRAM 上会触发 Store/AMO Fault（手册 MCAUSE CODE 7）→ S3/S4 亲手撞。
- Hazard3：RV32IMAC + Zba/Zbb/Zbs/Zbkb/Zcb/Zcmp/Zicsr。

## 待定决策

- 内核版本：S2 时拍（要求 ≥ 6.3，rv32 nommu 支持合入的版本）。
- PSRAM 片选脚：S1 确认（候选 GP0/8/19/47；pico-sdk `hardware_psram` 可自动探测）。
- 串口引脚/波特率：沿用用户工程 UART0 GP16/17 @ 115200（与内核 console 保持一致）。

## 怎么跑（构建/部署级，随阶段补充）

- 环境：`PICO_SDK_PATH=/home/developer/raspberrypi/pico-sdk`；已有 qemu-system-riscv32、picotool、riscv64-linux-gnu-gcc、dtc、cmake、ninja。
- 缺：pico-sdk 的 RISC-V 裸机工具链（`riscv-none-elf-gcc`）→ S1 开工时联网安装（官方 riscv-toolchain）。
- 烧录方式：S1 细化（picotool load 或 openocd rp2350-riscv）。

## 变更记录（翻案纪律：改了当场记，写旧方案 + 为什么翻）

-（暂无）
