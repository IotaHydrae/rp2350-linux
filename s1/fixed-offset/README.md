# S1 固定偏移版（归档）

> 归档位置：`s1/fixed-offset/`（主线的 S1 已升级为分区表版，见 `s1/partition-table/`）。

这是 S1 的**第一版 bootloader**：镜像位置写死在 flash 偏移 64KB（`FAKE_IMAGE_FLASH_XIP = 0x10010000`），烧录用 `picotool load -o 0x10010000`。它完成了 S1 闭环验收（2026-08-21 联跑 PASS）。

后来升级为**分区表版**（`s1/`，picobin，`-p 0` 烧录）——固定偏移版不再使用，归档在这里备用。两者差异：

| | 固定偏移版（本目录） | 分区表版（`s1/partition-table/`） |
|---|---|---|
| 镜像位置 | 写死 flash 偏移 64KB | 读 picobin 分区表（partition 0 @ 64K） |
| 烧录 | `picotool load -o 0x10010000 fake-image.bin` | `picotool load -p 0 fake-image.bin` |
| 镜像 | `fake-image/`（与本目录相同） | `s1/fake-image/` |

历史：固定偏移版代码在 git 提交 `2bf8af1` 中也有完整记录，随时可 `git show` 找回。
