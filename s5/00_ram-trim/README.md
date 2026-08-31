# S5-00 · 裁剪优化①：RAM 路线轻量化

> RP2350 Linux 移植 · S5 第一关：沿 RAM 加载路线把系统压轻——内核 Image、busybox、rootfs 三个尺寸一起砍，目标把并发进程上限从 2 抬到 3（`dmesg | tail -10` 不再段错误）。

## 本关起点（bootloader）

bootloader = s4-05 版 + **225MHz 超频**（用户 2026-08-31 手工改）：

- `sysclk`：150MHz → 225MHz（`vreg_disable_voltage_limit()` + 1.20V + `set_sys_clock_khz(225000)`）；
- `clk_peri`：改为跟 `clk_sys`（225MHz），不再走默认 48MHz 那路；
- 日志精简：`copy done.` 与校验成功输出去掉；**校验保留但只在失败时打印**（225MHz 下 flash/PSRAM 时序余量是唯一真风险，失败要能当场看出来）。

串口波特率不用改：pico-sdk 按当前 clk_peri 现算 divisor，还是 115200；内核 earlycon / sbsa console 都不重算 divisor。

## 机制（三个裁剪刀口）

1. **内核 config 瘦身**：Image 2.67MB → 目标更小（defconfig 里裁掉用不到的子系统/驱动）。
2. **busybox 精细裁剪**：258KB/进程 → 目标 ≤200KB/进程（applet 集合 + 编译特性），3 进程预算。
3. **rootfs 镜像再缩**：512KB → 更小（brd 少占，initrd 释放区连续块变大）。

内存账本联动：镜像越小 → brd 占得越少 → initrd 释放区连续块越大 → 并发进程越多。

## 已知边界 / 风险

- **225MHz flash/PSRAM 时序**：bootloader 从 flash XIP 跑、copy 走 QMI 写 PSRAM，超频后可能出错；校验会抓，失败即 halt。
- **遗留小事**：overlay `/init` 的 banner 还是 "S4-04 busybox"（S4-05 遗留），本关重出 rootfs 时顺手改掉。
- 并发上限 2 的完整账本见学习地图 ⑲。

## 如何复现（BOOTSEL 模式）

```sh
make flash-s5-00-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s5-00-kernel     # 暂复用 S4-04 内核（sha 2fbb50ab）
make flash-s5-00-dtb
make flash-s5-00-rootfs     # 暂复用 S4-05 rootfs（512KB）
```

预期：banner `=== s5-00 ram-trim bootloader ===` → 内核 legacy initrd 链 → hush 提示符。

## 当前状态

- 🔄 开工：bootloader 已搭（225MHz 起点），待真机验证超频启动；
- ⬜ 裁剪刀①内核 config；⬜ 刀②busybox；⬜ 刀③rootfs 镜像；⬜ 验收（并发 2→3）。
