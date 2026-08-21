# tests

测试程序统一放这里（主线产物 bootloader / fake-image 在各自目录）。

| 程序 | 作用 | 状态 |
|---|---|---|
| `psram-test` | `hardware_psram` 驱动：读 PSRAM ID/大小 + 写读自检 + 异常报告器 | ✅ 已验收（RP2350A-Minimal） |

烧录（BOOTSEL 模式下）：

```bash
make flash TARGET=psram-test
```
