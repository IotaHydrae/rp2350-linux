# S1 · 分区表版 bootloader + fake-image（假镜像闭环）

> RP2350 Linux 移植 · 工程：S1 主线。bootloader 从 **picobin 分区表**读取假镜像，拷到 PSRAM，
> 按 RISC-V 启动协议跳转，串口确认假镜像在 PSRAM 里跑起来——**闭环验收通过**（2026-08-21）。

## 这个工程验证什么

1. PSRAM 初始化（8MB @ `0x11000000`）与读写正确性；
2. 分区表（picobin）读取：bootloader 内嵌分区表，`picotool -p 0` 按分区写镜像；
3. 跳转协议：`a0 = hartid`、`a1 = DTB 地址`（假镜像不解析 DTB，打印原样），跳 `0x11000000`；
4. 假镜像从 PSRAM XIP 执行：自检 `0x11000000` 首字并循环打印。

## 目录内容

- `bootloader/main.c` — 分区表版 bootloader（PSRAM 初始化、找分区、拷贝、跳转）
- `fake-image/` — 假镜像（链接在 PSRAM `0x11000000`：`fake-image.ld` + `start.S` + `main.c`）
- `partition_table.json` — 分区表：partition 0 = FAKE @ 64K

## 构建

```sh
make all      # 工程根目录：产出 build/s1/bootloader.uf2 + build/s1/fake-image.bin
```

## 烧录（BOOTSEL 模式）

```sh
make flash-bootloader     # 烧 bootloader（内嵌分区表）
# 拔线 → 按住 BOOTSEL 重新插线（分区表生效需要重启再进 BOOTSEL）
make flash-fake           # 假镜像写入分区 0（-p 0）
```

## 运行观察

正常上电，串口（UART0 GP16/17 @115200 / USB ttyACM0）：

```
=== s1 bootloader (partition table) ===
PSRAM available: 1, size: 8388608
partition sectors [16, 31] -> flash 0x10010000, size 0x10000
copy 4096 bytes: flash 0x10010000 -> PSRAM 0x11000000
copy done. first bytes: 37 f1 7f 11
disable irqs, jump to 0x11000000 (a0=0 hartid, a1=NULL)

[Fake Image] running from PSRAM!
a0 (hartid) = 0x00000000
a1 (dtb)    = 0x00000000
self-check: word at 0x11000000 = 0x117ff137
[Fake Image] done, looping.
```

## 验收标准

假镜像从 PSRAM 运行、自检通过、循环打印 → **S1 闭环**（PSRAM 初始化 + 跳转协议打通）。

## 与固定偏移版的关系

本目录是 S1 主线；早期"写死 flash 偏移 64KB"的版本已归档到 `s1/fixed-offset/`（不再使用，
差异见其 README）。

## 实验记录与参考

- `notes/实验日志/2026-08-21_S1分区表版联跑.md`、`2026-08-21_S1联跑闭环.md`
- `notes/学习记录/S1 · 假镜像闭环.md`
