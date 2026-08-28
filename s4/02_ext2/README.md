# S4-02 · ext2 真实文件系统（brd RAM 块设备）

> RP2350 Linux 移植 · 工程 02（S4 文件系统篇）：真板没有块设备硬件，用内核 brd（ramdisk）驱动把 RAM 模拟成 `/dev/ram0` 块设备，PC 上 `mkfs.ext2` 做镜像，/init 拷镜像、挂载、写读测试——第一次跑"真实文件系统格式"（inode/目录/位图）。

## 机制

- 内核侧：`CONFIG_BLK_DEV_RAM=y`（brd）+ `CONFIG_BLK_DEV_RAM_SIZE=512`（KB）→ `/dev/ram0`（devtmpfs 提供节点）。
- rootfs 侧：`/rootfs.ext2`（PC 上 mkfs.ext2 生成，含 hello.txt）随 rootfs 进内存；/init 把镜像拷进 `/dev/ram0` → `mount /dev/ram0 /mnt ext2` → 写/读 `/mnt/test.txt` 验证。
- **断电即失**：brd 是 RAM 盘，重启数据没了——正好演示"持久化"概念（真 flash 持久化需要 MTD 驱动，后面再说）。

## 为什么 ext2

内核已内置（`CONFIG_EXT2_FS=y`）；工具成熟（PC 上 mkfs.ext2/e2fsck/debugfs 能解剖 superblock/inode/目录块）；结构经典，是 ext4 的祖先；支持读写，能做写文件实验。详见学习记录 S4-02。

## 目录内容

- `initramfs-src/` — /init（无 libc：拷镜像、mount、写读测试 + shell）
- `root-content/` — ext2 镜像里预置的文件（mkfs.ext2 -d 灌入）
- `rp2350_minimal_defconfig` — 开 brd（512KB）
- `kernel-Image` — 本关重编的内核（含 brd）
- 复用 S4-00：DTB（未变，`make flash-s4-00-dtb`）

## 如何复现

### 构建

```sh
make all                    # 不需要：本关无 bootloader
make init-s4-02             # /init bFLT
make image-s4-02            # mkfs.ext2 → rootfs.ext2（512KB，含 hello.txt）
make rootfs-s4-02           # gen_init_cpio → rootfs.cpio（含镜像）
make kernel-s4-02           # 重编内核（开 brd）→ kernel-Image
```

### 烧录（BOOTSEL 模式）

板子上已是 S4-00 的 bootloader/DTB 时，只需：

```sh
make flash-s4-02-bootloader  # 本关 bootloader（banner=s4-02，可选，便于识别工程）
make flash-s4-02-kernel     # 新内核（含 brd）
make flash-s4-02-rootfs     # rootfs（含 ext2 镜像）
```

DTB 复用：`make flash-s4-00-dtb`（未变时不用重烧）。

### 运行观察（UART0，GP16/17，115200）

预期：

1. `S4-02 ext2 on brd`
2. `ext2 OK: hello ext2`（挂载后写入 /mnt/test.txt 再读回）
3. `# ` 提示符照常

## 已知边界

- brd 是 RAM 盘：重启数据丢失（教学演示"非持久化"；真持久化需要 flash 驱动 + jffs2/ubifs 等）。
- 镜像 512KB 上限受 rootfs 分区 1MB 约束（512KB 镜像 + cpio 开销）；要更大就扩分区 + `BLK_DEV_RAM_SIZE`。
