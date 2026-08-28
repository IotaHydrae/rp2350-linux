# S3-05 · 进 shell：initramfs + 自写 /init

> RP2350 Linux 移植 · 工程 05：真板无块设备，用 initramfs（编进内核的 cpio 内存根文件系统）只装一个自写静态 `/init`，让内核从 VFS panic 变成跑到用户态 shell。

## 这个工程验证什么

S3-04 已经把日志锁在 ttyAMA0，唯一卡点是 VFS panic（没有根文件系统）。本工程把根文件系统做成 **initramfs**：

- `CONFIG_INITRAMFS_SOURCE` 指向 `initramfs.list`（gen_init_cpio 清单：`/dev/console` 设备节点 + `/init` 可执行文件）；
- 内核构建时 `usr/gen_initramfs.sh` 把清单打成 cpio，以 `initramfs_data.o` 编进 Image；
- 启动时 rootfs（ramfs）挂为初始根，`populate_rootfs()` 解包 cpio；`kernel_init_freeable()` 检查 `init_eaccess("/init")` 通过就**跳过 prepare_namespace**（VFS panic 消失），直接以 rootfs 为根执行 `/init`。

为什么 `/init` 是 bFLT 不是 ELF：riscv32 NOMMU 内核 `CONFIG_BINFMT_ELF` 依赖 MMU，用户态只能用 uClinux FLAT 格式（`CONFIG_BINFMT_FLAT=y`）。本机工具链没有 elf2flt，所以 `scripts/pack-bflt.sh` 手搓 bFLT（64 字节大端头 + text/data/bss；text 32 字节对齐；无运行时重定位；编译须 `-no-pie`）。

## 目录内容

- `bootloader/`、`dts/`、`partition_table.json` — 照 04 模式；bootargs 不加 `root=`（initramfs 默认跑 `/init`，`rdinit` 缺省就是它）
- `initramfs.list` — gen_init_cpio 清单（`/dev/console` 节点 + `/init` 文件）；`CONFIG_INITRAMFS_SOURCE` 指向它
- `initramfs-src/` — `init.c`（无 libc，ecall 内联汇编发系统调用）+ `init.ld`（text 0x0、data 32 对齐）
- `initramfs/init` — `make init-s3-05` 产物（bFLT）
- `rp2350_minimal_defconfig` — 04 基础上加 `CONFIG_INITRAMFS_SOURCE`

## 如何复现

### 构建

```sh
make all                    # bootloader（不要 sudo）
make init-s3-05             # 编译 init.c → 手搓 bFLT → initramfs/init
make kernel-s3-05           # 配置 → 编 cpio 进 Image → 拷贝 kernel-Image
make build/s3/05_shell/rp2350a-minimal.dtb
```

注意：/init 编进了内核 Image，改 init.c 后必须重新 `make init-s3-05` + `make kernel-s3-05`。

### 烧录（BOOTSEL 模式）

```sh
make flash-s3-05-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s3-05-kernel
make flash-s3-05-dtb
```

### 运行观察（UART0，GP16/17，115200）

预期日志（部件 R 验收）：

1. `=== s3-05 shell bootloader ===`
2. `VFS: Finished mounting rootfs on nullfs` / 无 `/dev/root: Can't open blockdev`、无 VFS panic
3. 出现 `S3-05 initramfs OK`（/init 的第一行输出，经 /dev/console → ttyAMA0）
4. 之后日志静止（最小 /init 只打印后挂起，正常；下一部件才加 shell）

## 已知边界

- bFLT 手搓依赖链接脚本与编译参数（无重定位、32 对齐、`_start` 在 0x0），改链接脚本后重新跑 `pack-bflt.sh`。
- `initramfs.list` 里 `/init` 是绝对路径，换机器/路径要同步改 defconfig 与清单。
- PID 1 退出即 kernel panic，/init 必须常驻。
