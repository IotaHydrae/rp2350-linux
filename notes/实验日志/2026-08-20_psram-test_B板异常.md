# psram-test 首次联跑 + 异常报告（RP2350B-Plus-W）

- 日期：2026-08-20
- 板子：Waveshare RP2350B-Plus-W（PSRAM CS = GPIO47）
- 目的：验证 PSRAM 初始化 + 写读自检
- 结论：ID/大小正常，第一次写 `0x11000000` 时异常（`mcause=2` 非法指令 @ mepc=0x100000f4），该地址反汇编为合法指令，矛盾；后换板坐实为坏硬件连锁反应

## 第一次运行（无异常报告器，静默卡死）

```text
=== psram-test ===
sys clock: 150000000 Hz
psram_is_available: 1
psram size: 8388608 bytes (0x00800000)
write/read self-test on PSRAM...
```

（输出停在此处）

## 加异常报告器后

```text
=== psram-test ===
sys clock: 150000000 Hz
psram_is_available: 1
psram size: 8388608 bytes (0x00800000)
write/read self-test on PSRAM...

*** MACHINE EXCEPTION ***
mcause = 0x00000002 (低12位: 5=load访问fault, 7=store/AMO访问fault)
mepc   = 0x100000f4 (出事的指令地址)
mtval  = 0x00000000 (被访问的地址)
```
