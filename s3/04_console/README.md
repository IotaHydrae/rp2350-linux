# S3-04 · 真 console 收尾：ttyAMA0 确定接管日志

> RP2350 Linux 移植 · 工程 04：S3-03 已经让 `ttyAMA0` 注册成 console 并实际接管过日志，这一关把它**焊死**——显式 `console=ttyAMA0`、恢复 `CONFIG_VT` 后不被 dummy console 抢、sbsa-uart 方案定案。

## 这个工程验证什么

内核日志打印分两段：

1. **earlycon（bootconsole）**：直写 PL011 寄存器，从第一条日志就开始打；
2. **真 console（ttyAMA0）**：pl011/sbsa 驱动 probe 后注册，printk 交接、关闭 bootconsole。

交接时谁是「首选」由 bootargs 决定：有 `console=` 时，那个 console 无论注册先后都归它；没有时谁先注册谁默认——`CONFIG_VT` 开着的话 `tty0`（dummy console）注册得早，会把日志接管到不存在的显示设备上，串口从此看不到日志（S3-02 撞过的「假卡死」）。

本工程改动：
- DTB bootargs 加 `console=ttyAMA0`（锁定首选 console，防 VT 恢复后抢日志）；
- 验证 DEBUG_INFO（DWARF5）行号定位可用（`scripts/log-analyze.sh` / `pc-locate.sh` 显示 源文件:行号）；
- 恢复 `CONFIG_VT` 后日志仍从 `ttyAMA0` 出（dummy/tty0 不抢）；
- sbsa-uart 方案定案：长期用 or 后续换完整 pl011 platform 驱动。

## 目录内容

- `bootloader/`、`dts/`、`partition_table.json` — 照 03 模式；DTB bootargs 加 `console=ttyAMA0`
- `kernel-Image` — DEBUG_INFO 版内核（与 03 同源，sha `c9b844e9…`），构建自 `/home/developer/linux-7.2`，`O=build-rv32-03`；S3-04 恢复 VT 后改由 `O=build-rv32-04` 构建
- `rp2350_minimal_defconfig` — 03 的完整 defconfig 原样复制（含 `CONFIG_DEBUG_INFO_DWARF5=y`；`CONFIG_VT` 恢复待本关验证后定案）

## 如何复现

### 构建

```sh
make all                        # bootloader（不要 sudo）
make build/s3/04_console/rp2350a-minimal.dtb
make kernel-s3-04               # 配置 → 编译 → 拷贝（改 CONFIG_VT 后使用）
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s3-04-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s3-04-kernel         # 内核与 03 相同，可跳过
make flash-s3-04-dtb
```

### 运行观察（UART0，GP16/17，115200）

预期日志：

1. bootloader banner：`=== s3-04 console bootloader ===`
2. `printk: console [ttyAMA0] enabled` + `legacy bootconsole [pl11] disabled` 后日志继续从 ttyAMA0 出
3. 日志末尾仍停在 VFS panic（rootfs 是 S3-05 的事，此处是预期终点）
4. 恢复 `CONFIG_VT` 后，无 `Console: colour dummy device` 抢占、日志仍从 ttyAMA0 出

### 行号定位验证（DEBUG_INFO）

把启动日志存成文件，跑：

```sh
scripts/log-analyze.sh /home/developer/linux-7.2/build-rv32-03/vmlinux /tmp/kern.log
```

Call Trace 每行显示 `函数名 源文件:行号`（如 `mount_root_generic /home/developer/linux-7.2/init/do_mounts.c:225`）。

## 已知边界

- 本关只动 DTB 和内核配置，不动内核源码；内核改动总账见 `notes/内核改动记录与溯源.md`。
- 真实 UART RX 中断（打字进 shell）要 tty open，S3-05 有 `/init` 后自然可用。
