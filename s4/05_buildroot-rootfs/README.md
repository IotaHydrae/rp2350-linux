# S4-05 · buildroot 组装 rootfs

> RP2350 Linux 移植 · 工程 06（S4 文件系统篇）：rootfs 不再手动 mkfs 打包，改由 **buildroot 组装**（包管理 / skeleton / 符号链接 / 权限 / fakeroot），出 ext2 镜像烧分区 2。为后续把文件系统放到 flash（S6/S7）铺路——同一套 rootfs 基础设施。

## 机制

1. buildroot 把选中包安装到 `output/target/`（rootfs 树）→ 根文件系统镜像目标（`BR2_TARGET_ROOTFS_EXT2`）用 host `mkfs.ext2 -d output/target` 出 ext2；
2. **overlay 注入 /init**（`BR2_ROOTFS_OVERLAY` 指向本工程 `overlay/`）：buildroot 的 rootfs 默认只有 /sbin/init，bootargs 是 `init=/init`，所以把我们的启动器 bFLT 放进去；
3. 镜像必须 ≤512KB：NOMMU 内存墙——brd 只写 512KB，initrd 释放区留 512KB 连续块，够两个 256KB 进程（hush + 一个外部命令）。

## 关键配置（buildroot，提交在 buildroot 仓库）

- `BR2_UCLIBC_INSTALL_UTILS` 关：getconf（233KB）会挤爆预算；
- `BR2_TARGET_ROOTFS_EXT2=y` + `SIZE="512k"` + `MKFS_OPTIONS="-b 1024"` + `RESBLKS=0` + `INODES=256`（默认 inode 数装不下 ~110 个文件/符号链接）；
- `BR2_ROOTFS_OVERLAY=/home/developer/iotahydrae/rp2350-linux/s4/05_buildroot-rootfs/overlay`；
- busybox 31 个 applet：去掉了 sed/head/cut/od/date，加了 insmod/rmmod（等 S5 内核开 CONFIG_MODULES 就能用），行编辑保持。

## 本关范围与边界

- **范围**：纯 rootfs 组装；内核不动（复用 S4-04，sha `2fbb50ab`）。
- **延迟到 S5**：模块动态加载（内核 CONFIG_MODULES + insmod/rmmod 工作流）、rz 传文件（lrzsz 依赖动态库、NOMMU 用不了——S5 计划手写 XMODEM 接收器）、vi（体积大）。
- **inode 用满**（256 个，free=0）：以后要加文件，把 `EXT2_INODES` 调到 384（多占 ~32KB 数据空间，现余 108KB 够）。
- **残留符号链接坑**：改 busybox applet 集合后，`output/target` 里旧 applet 的符号链接不会自动清（指向 busybox 会报 applet not found）——手动 `rm` 后重新 `make` 出镜像。

## 如何复现

```sh
make init-s4-05      # /init 启动器 → overlay/
make rootfs-s4-05    # buildroot 重新组装 + 出镜像 → rootfs.ext2
```

烧录（BOOTSEL）：

```sh
make flash-s4-05-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s4-05-kernel     # 复用 S4-04 内核
make flash-s4-05-dtb
make flash-s4-05-rootfs     # buildroot 镜像
```

预期：bootloader banner `s4-05` → legacy initrd 链 → `S4-05 busybox` → hush 提示符；`ls /etc`（skeleton 在）、`ls /sys /proc`、`uname -a`、行编辑正常。
