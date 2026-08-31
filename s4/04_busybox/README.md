# S4-04 · busybox 移植（riscv32 NOMMU，bFLT）

> RP2350 Linux 移植 · 工程 05（S4 文件系统篇）：把真正的 busybox（buildroot 编的 uClibc-ng + bFLT）请进根文件系统，PID 1 从"自写 shell"升级成 **busybox ash**，敲 ls/cat/grep 等 25 个 applet。

## 机制（本关新链）

1. **工具链**：riscv32 NOMMU 用户态只能 bFLT，libc 只能用 uClibc-ng（musl/glibc 不支持 NOMMU）。buildroot（`/home/developer/buildroot-2026.05.2`）生成整套：`riscv32-buildroot-linux-uclibc-gcc` + elf2flt + busybox。
2. **bFLT 转换**：buildroot 的包框架给目标 CFLAGS/LDFLAGS 自动加 `-Wl,-elf2flt=-r -static`（`package/Makefile.in:222`），所以 busybox 编出来直接是 `BFLT v4 ram gotpic`。脱离 buildroot 手编时自己带这套 flag。
3. **GOTPIC**：elf2flt 产的 bFLT 带 GOTPIC 标志，内核 `binfmt_flat` 的 GOTPIC 路径（GOT 在 data 头部、加载时加基址）第一次真机验证——之前 S3-05 手搓的 bFLT 都是无重定位、无 GOTPIC 的。
4. **/init 启动器**：根里 /init 是手搓无 libc 的 bFLT（pack-bflt.sh），只做三件事：把 tty dup3 成 0/1/2 → 挂 ramfs /tmp + proc /proc（失败不阻塞）→ `execve("/bin/sh", ["sh"])`。`/bin/sh` 是 busybox 符号链接，busybox 按 argv[0] 分发——**PID 1 变成 busybox shell**。
5. **NOMMU 连续内存墙（本关最大坑）**：busybox 1.38 的 **ash `depends on !NOMMU`，NOMMU 下 shell 只能是 hush**。且每个外部 applet（ls/cat/ps）都是把整份 busybox 当新进程 exec，需要**连续内存**：566KB 版本每次要 600KB（order-8 块），装不下第二个进程 → `-ENOMEM` → SIGSEGV。解法：**裁 applet + 缩镜像**——第一轮裁到 26 个 applet，busybox 566KB→**255KB**（exec 只要 256KB order-6 块）；镜像 1MB→**384KB**，brd 只写 384KB，initrd 释放出来的 1MB 区域留出 512KB 连续块，能同时放 ash + 一个外部命令。精细裁剪留给 S5。

## 决策（2026-08-31 用户拍板）

- 工具链路线 → **buildroot 当工具链工厂**（`qemu_riscv32_nommu_virt_defconfig` 裁剪掉内核/QEMU，只留工具链+elf2flt+busybox），已建 git 仓库（首提交无改动 `7729990a` + 我们的 defconfig `560114f5`）。
- **修掉浮点坑**：QEMU defconfig 默认 RISC-V 变体 G(imafd)/ilp32d（QEMU CPU 带 F/D），Hazard3 是 RV32IMAC 无 F/D → 改 `BR2_riscv_custom` + 关 F/D + 开 C + `ilp32`，clean 重编。
- busybox 尺寸方案 → **方案 A：扩 ramdisk 到 1MB**（默认 applet 集先跑通，S5 再裁）。

## 目录内容

- `bootloader/` — 本关 bootloader（banner=s4-04）
- `dts/` — 与 S4-03 相同（bootargs `root=/dev/ram rootfstype=ext2 init=/init` 不变）
- `initramfs-src/` — /init 启动器（无 libc bFLT：dup3 + ramfs /tmp + exec /bin/sh）
- `busybox` — buildroot 产物（255KB，26 个 applet，`make busybox-s4-04` 从 buildroot 拷贝）
- `rp2350_minimal_defconfig` — S4-02 配置 + `BLK_DEV_RAM_SIZE=1024`

## 如何复现

### 构建

```sh
make kernel-s4-04        # 重编内核（ramdisk 1MB）→ kernel-Image
make init-s4-04          # /init 启动器 bFLT
make busybox-s4-04       # 从 buildroot 拷 busybox
make image-s4-04         # mkfs.ext2 1024k → rootfs.ext2（busybox + 25 个符号链接）
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s4-04-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s4-04-kernel
make flash-s4-04-dtb
make flash-s4-04-rootfs
```

### 运行观察（UART0，GP16/17，115200）

预期：

1. bootloader：`=== s4-04 busybox bootloader ===`，`copy rootfs ... -> PSRAM 0x11300000`
2. 内核：`RAMDISK: ext2 filesystem found` → deprecated 警告（预期）→ `VFS: Mounted root (ext2 filesystem) readonly on device 1:0.` → `Run /init as init process`
3. `S4-04 busybox`（启动器 banner）→ ash 提示符（`/bin/sh #` 或 `# `）
4. 敲命令验证 applet：`ls /bin`、`echo hello`、`uname -a`、`ps`（shell 是 hush，提示符/内建命令照常）

## 已知边界 / 排查

- **GOTPIC bFLT 首次真机验证是本关最大不确定点**：内核 `binfmt_flat` 的 GOTPIC 路径（GOT 头 + 加基址）代码核实过、QEMU 没跑过（QEMU 回归欠账未修）；如果 exec busybox 崩/卡，用调试器抓第一现场（`scripts/start-openocd.sh` + `gdb-dump.sh`，vmlinux 在 `/home/developer/linux-7.2/build-rv32-s4-04/vmlinux`）。
- **NOMMU 内存墙**：每个外部 applet exec 需要 ~256KB 连续内存（busybox 255KB）；ash/hush 本身占一份，所以同时只能跑有限的几个进程。镜像已缩到 384KB 保证 initrd 释放区留 512KB 连续块；再压不下就得上 XIP（S5）。
- 根默认只读：hush/applet 只读够用，/tmp 是 ramfs 可写（启动器挂的）；要写根给 bootargs 加 `rw`。
- `ps`/`dmesg` 等读 /proc 的 applet：本关内核 `CONFIG_PROC_FS=y`（默认开），启动器会挂 /proc，应该能用。
- `clear` 等少数 applet 没编进默认 busybox-minimal.config，符号链接没建；需要就调 busybox 配置重编。
- buildroot 重编/换配置记得 `make clean`（工具链选项变更必须 clean）；宿主环境两个坑见学习地图（PATH 空格路径 + uutils install 绕过）。
