# psram-test 验收 PASS（RP2350A-Minimal）

- 日期：2026-08-21
- 板子：自研 RP2350A-Minimal（PSRAM CS = GPIO0）
- 目的：确认新板 PSRAM 正常工作，关闭 mcause=2 遗留问题
- 结论：PASS；mcause=2 未复现 → 原异常是坏芯片连锁反应，遗留关闭

## 原始日志

```text
=== psram-test ===
sys clock: 150000000 Hz
psram_is_available: 1
psram size: 8388608 bytes (0x00800000)
write/read self-test on PSRAM...
PASS: PSRAM is alive at 0x11000000
done
```
