# S4-03 · 根切 ext2（legacy initrd）

> RP2350 Linux 移植 · 工程 04（S4 文件系统篇）：把"拷镜像 + 挂载"从用户态 /init 挪回内核。
> 分区 2 直接放 raw ext2 镜像，内核走 legacy initrd 链自己把根挂起来，再执行根里的 /init。

## 机制（本关新链）

上两关（S4-01/02）是 initramfs 模型：cpio 被内核解包进初始 rootfs，`kernel_init_freeable` 发现 /init 可执行就**跳过 prepare_namespace**，挂载是 /init 自己干的。

本关换成 legacy initrd（老式 RAM disk）模型，链是内核代码路径：

1. bootloader 把分区 2（raw ext2 镜像，不再包 cpio）拷到 PSRAM `0x11300000`。
2. `populate_rootfs`（init/initramfs.c）先解内置 initramfs（空），再拿 `linux,initrd-start/end` 指向的内存试解 cpio——ext2 不是 cpio，解不开，于是把原始字节**原样存成 `/initrd.image`**（ramfs 里的普通文件）。
3. 初始 rootfs 里没有 /init → `ramdisk_execute_command` 被清空 → `prepare_namespace()`（init/do_mounts.c）执行。
4. `initrd_load()`（init/do_mounts_initrd.c）→ `rd_load_image()`（init/do_mounts_rd.c）：打开 /initrd.image，`identify_ramdisk_image()` 在 block 1 认出 ext2 超级块，按 `s_blocks_count` 拷 `nblocks` KiB 进 `/dev/ram0`（brd）。
5. `mount_root()`：`root=/dev/ram` 被 `parse_root_device()` 特判成 `Root_RAM0`（ramdisk 1:0），`mount_root_generic` 按 `rootfstype=ext2` 挂载 → **`VFS: Mounted root (ext2 filesystem)`**。
6. `devtmpfs_mount()` 挂出 /dev，然后 `kernel_init` 按 `init=/init` 执行根里的 /init → shell。

## 决策（2026-08-28 用户拍板）

- 决策① 镜像怎么进内存 → **bootloader 直接拷 raw ext2**（去掉 cpio 包一层；保留 cpio 就不是根切，还是 initramfs 流程）。
- 决策② init 程序放哪 → **`init=/init` 显式指定**（不靠 /sbin/init 静默搜索，日志里能看到 `Run /init as init process`）。
- 决策③ 根设备写法 → **`root=/dev/ram`**：parse_root_device 特判成 Root_RAM0；`root=/dev/ram0` 在 devtmpfs 挂载前查不到节点会解析失败。

## 目录内容

- `bootloader/` — 本关 bootloader（banner=s4-03，分区 2 按 raw rootfs 拷）
- `dts/` — 板级/SoC 设备树（chosen 加 root=/dev/ram rootfstype=ext2 init=/init）
- `initramfs-src/` — 根里 /init（无 libc shell：dup3 安 stdio、hello → exec /bin/hello）
- `hello-src/` — /bin/hello（bFLT）
- `rp2350_minimal_defconfig` — 与 S4-02 相同（本关无内核改动，保留为独立复现）
- 复用 S4-02 内核（sha `98b0cb5c`），本工程不拷 kernel-Image

## 如何复现

### 构建

```sh
make init-s4-03        # /init bFLT
make hello-s4-03       # /bin/hello bFLT
make image-s4-03       # mkfs.ext2 → rootfs.ext2（512KB，含 /init /bin/hello /dev）
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s4-03-bootloader   # 本关 bootloader（banner=s4-03，识别工程用）
make flash-s4-03-kernel       # 复用 S4-02 内核（无内核改动）
make flash-s4-03-dtb          # 本关 DTB（bootargs 变了，必须重烧）
make flash-s4-03-rootfs       # 分区 2 = raw ext2 镜像
```

### 运行观察（UART0，GP16/17，115200）

预期新增/变化的关键行：

1. bootloader：`copy rootfs ... -> PSRAM 0x11300000`，verify 行是 `rootfs mismatches=0`
2. 内核：`rootfs image is not initramfs (...); looks like an initrd`（populate_rootfs 兜底）
3. 内核：`RAMDISK: ext2 filesystem found at block 0` + `RAMDISK: Loading 512KiB [1 disk] into ram disk...`
4. 内核：`using deprecated initrd support, will be removed in January 2027...`（**预期警告，不是错误**）
5. 内核：`VFS: Mounted root (ext2 filesystem) on device 1:0.` ← 本关验收实锤
6. 内核：`Run /init as init process`
7. shell：`S4-03 root ext2` + `# `，敲 hello 出 `Hello, world!`

## 已知边界 / 排查

- legacy initrd 会打 deprecation 警告（2027-01 移除）；本关教学目的就是走这条老链，属预期。
- 如果卡在 `VFS: Cannot open root device "/dev/ram"...`：先查 bootargs 是否 root=/dev/ram（不是 ram0）、rootfstype=ext2、分区 2 是否 raw ext2。
- 如果没看到 shell 而日志停在 `Run /init as init process`：/init 起不来，用 `scripts/log-analyze.sh <vmlinux> <日志>` 看 Call Trace（vmlinux 在 `/home/developer/linux-7.2/build-rv32-s4-02/vmlinux`）。
- 根里 /init 自己 dup3 tty 到 0/1/2：初始 rootfs 是空 ramfs，没有 /dev/console，`console_on_rootfs()` 打不开（日志会有一行 `Warning: unable to open an initial console.`，属预期）。
