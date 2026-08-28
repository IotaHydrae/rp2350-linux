# S4-00 · bootloader 拷 initramfs：rootfs 独立烧录

> RP2350 Linux 移植 · 工程 00（S4 文件系统篇）：S3-05 把 initramfs 编进内核，改 rootfs 就得重编重烧整个内核；这一关把它拆成独立分区——bootloader 从分区 2 拷 initramfs 到固定 RAM 地址，DTB 用 `linux,initrd-start/end` 描述，内核照常解包。以后改 rootfs 只烧分区 2。

## 固定约定布局

| 内容 | Flash | RAM |
|---|---|---|
| kernel | 分区 0 @ 64K，3MB | 0x11000000 |
| DTB | 分区 1 @ 3136K，64K | 0x11700000 |
| initramfs (rootfs) | 分区 2 @ 3200K，1MB | 0x11300000 ~ 0x11400000 |

`linux,initrd-start/end` 写死在 DTB chosen，bootloader 的 `INITRAMFS_LOAD_ADDR` 必须与之一致（改地址要两处同步 + 重烧 DTB/bootloader）。

## 内核侧改动

- defconfig **清空** `CONFIG_INITRAMFS_SOURCE`（不再内置 initramfs）——rootfs 出错时能明确判定是独立文件系统的问题；保留 `CONFIG_BLK_DEV_INITRD=y`。
- 启动时内核按 DTB 的 initrd 地址 reserve 内存 → `populate_rootfs()` 解包 → 解完 `free_initrd_mem` 释放。

## 目录内容

- `bootloader/` — 拷 kernel + dtb + initramfs 三份，各自校验后跳转
- `dts/` — chosen 加 `linux,initrd-start/end`
- `partition_table.json` — 分区 2 = ROOTFS（1MB，families=absolute）
- `initramfs.list` — rootfs 内容清单（S4-00 自有 /init，`make init-s4-00` 构建）
- `rp2350_minimal_defconfig` — S3-05 基础上清掉 INITRAMFS_SOURCE

## 如何复现

### 构建

```sh
make all                    # bootloader（不要 sudo）
make init-s4-00             # 构建 S4-00 自有 /init（rootfs 内容依赖）
make rootfs-s4-00           # gen_init_cpio → rootfs.cpio
make kernel-s4-00           # 无内置 initramfs 的内核 → kernel-Image
make build/s4/00_boot-initramfs/rp2350a-minimal.dtb
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s4-00-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s4-00-kernel
make flash-s4-00-dtb
make flash-s4-00-rootfs    # 之后改 rootfs 只需重跑 这条
```

### 运行观察（UART0，GP16/17，115200）

预期日志：

1. `=== s4-00 boot-initramfs bootloader ===`
2. `copy initramfs ...` + `verify: ... initramfs mismatches=0`
3. 内核日志照常 → **无 VFS panic** → `S3-05 initramfs OK` → `# hello` → `Hello, world!`

## 已知边界

- initramfs RAM 地址是固定约定（DTB + bootloader 双处写死），改地址要两处同步。
- rootfs 分区 1MB：手搓阶段够用；不够时改 partition_table.json 大小 + DTB `initrd-end` + 重烧。
- rootfs 内容 S4-00 自洽（initramfs-src/ 是 S3-05 的 shell 拷贝 + S4 banner）。
