# 内核 initramfs 与 rootfs 启动链路详解

> rp2350-linux 移植笔记 · 面向"内核怎么把内存文件系统挂起来、怎么决定跑哪个 /init"的完整链路。源码基于 linux-7.2，核对于 S3-05（2026-08-28）。

## 一句话

内核把"根文件系统"先做成一块 RAM 里的 rootfs（ramfs），启动早期把编进 Image 的 initramfs（cpio）解包进 rootfs；如果 rootfs 里有**可执行**的 `/init`，就跳过"挂块设备根"的整套流程，直接以 rootfs 为根执行 `/init`。VFS panic 就是"rootfs 里没有可执行的 /init、被迫去挂块设备根"的结果。

## 全链路（按启动顺序）

### 1. bootargs：不加 root=

- 内核命令行没有 `root=` 时 `saved_root_name` 为空，后续 `ROOT_DEV` 保持 0。
- 加了 `root=` 才会走"挂块设备根"分支。initramfs 场景**必须不加 root=**（`rdinit=` 可指定 initramfs 的 init 路径，默认就是 `/init`）。

### 2. rootfs：初始根文件系统

- `init/do_mounts.c`：`init_rootfs()` + `rootfs_fs_type`——rootfs 是 ramfs（无 CONFIG_TMPFS 或指定时），是内核最初挂成 `/` 的根。
- 之后的 initramfs 解包、console、/init 执行全都发生在这棵根上。

### 3. populate_rootfs：解包 initramfs

- `init/initramfs.c`：`rootfs_initcall(populate_rootfs)` → `async_schedule_domain(do_populate_rootfs, ...)` 异步执行。
- `do_populate_rootfs()` 里核心是 `unpack_to_rootfs()`：
  - 先判格式：cpio newc 魔数 `070701`/`070702`；gzip 压缩（内核默认，`CONFIG_RD_GZIP=y`）先解压。
  - 逐条解析 cpio 记录：`dir` / `file` / `nod`（设备节点）/ `slink` → 用内核态 init_syscalls 在 rootfs 上创建对应对象。
  - 解包完 `free_initrd_mem()` 释放 initramfs 内存，`initrd_start/end` 清零。
- `wait_for_initramfs()`：`kernel_init_freeable()` 里等异步解包完成（防止后面访问 rootfs 时还没解包完）。

### 4. console_on_rootfs：给 init 准备 stdio

- `init/main.c` `console_on_rootfs()`：`filp_open("/dev/console", O_RDWR, 0)`，成功后 `init_dup` 三次 → 新进程（PID 1）的 fd 0/1/2 都指向 `/dev/console`。
- **关键坑**：`/dev/console` 设备节点必须存在。内核只在**无 initramfs** 时（`init/noinitramfs.c` 的 `default_rootfs()`）自动创建；有 initramfs 时必须由 initramfs 自带——gen_init_cpio 清单里写 `nod /dev/console 0622 0 0 c 5 1`。否则打不开 → `Warning: unable to open an initial console.`，init 的 stdout 全废，banner 出不来。
- `/dev/console`（5:1）是"当前 console 设备"的门面：真板上 `console=ttyAMA0` → 打开它等于打开 ttyAMA0 对应的 tty（console_open → tty_open → uart_startup → **RX 中断使能**）——S3-05 shell 打字能用的机制链在这里接上。

### 5. 决定命运的一行：init_eaccess("/init")

`kernel_init_freeable()`（`init/main.c`）：

```c
wait_for_initramfs();
console_on_rootfs();

ramdisk_command_access = init_eaccess(ramdisk_execute_command);
if (ramdisk_command_access != 0) {
	ramdisk_execute_command = NULL;
	prepare_namespace();   /* ← 只有这里才去挂块设备根 */
}
```

- `ramdisk_execute_command` 默认 `"/init"`（`rdinit=` bootargs 可改）。
- `init_eaccess("/init")` = 检查 rootfs 上 `/init` 是否存在且**可执行**。
  - **通过** → 跳过 `prepare_namespace()` → VFS panic 消失，rootfs 直接当根，稍后执行 `/init`。
  - **不通过**（没 initramfs / /init 不可执行）→ `prepare_namespace()` → 就是 S3-04 之前看到的 VFS panic 来源。

### 6. prepare_namespace：块设备根流程（本关不走，但要懂）

`init/do_mounts.c`：

- `root_delay` 等待、`wait_for_device_probe()`、`md_run_setup()`。
- `saved_root_name[0]` → `ROOT_DEV = parse_root_device(saved_root_name)`。
- `initrd_load()`：legacy initrd（/dev/ram0）专用，会打 "using deprecated initrd support, will be removed in January 2027" 警告——**initramfs 不走这里**。
- `mount_root(saved_root_name)`：按 ROOT_DEV 分派：
  - `Root_NFS` / `Root_CIFS` → 网络根；
  - `Root_Generic` / 0 → `mount_block_root` → `create_dev("/dev/root", ROOT_DEV)` → 逐个尝试块设备文件系统（ext2 等）→ 失败就是 `VFS: Cannot open root device ...` + panic。
- `devtmpfs_mount()`：挂 devtmpfs 到 /dev（`CONFIG_DEVTMPFS_MOUNT=y` 时）。真板 `/dev/ttyAMA0` 就是这么来的。
- `init_pivot_root(".", ".")` + `init_umount`：把新挂的 `/root` 转正、卸掉旧 rootfs（initramfs/initrd 场景通常被第 5 步短路，不走这里）。

### 7. kernel_init：执行 init

`kernel_init()` 按顺序尝试：

1. `ramdisk_execute_command`（initramfs 的 `/init`）——本关路径；
2. `execute_command`（`init=` bootargs）；
3. `CONFIG_DEFAULT_INIT`；
4. `/sbin/init` → `/etc/init` → `/bin/init` → `/bin/sh`；
5. 全失败 → panic `No working init found. Try passing init= ...`。

`run_init_process` 用 binfmt（NOMMU 只有 FLAT）加载 `/init`，成为 PID 1。**PID 1 退出 = kernel panic**（"Attempted to kill init"），所以 /init 必须常驻。

## 对 S3-05 的意义

- initramfs 编进内核（`CONFIG_INITRAMFS_SOURCE` → `usr/gen_initramfs.sh` 打 cpio → `initramfs_data.o` 链接进 Image）省掉一切块设备/网络根依赖，rootfs 即根。
- **无 root= 是关键**：加了 root= 会走 prepare_namespace 的块设备根，initramfs 白搭。
- `/dev/console` 必须自带；`/init` 必须可执行（0755）。
- 扩展阅读：S3-05 学习记录施工态；bFLT 打包见 `notes/bFLT格式与手搓打包详解.md`。
