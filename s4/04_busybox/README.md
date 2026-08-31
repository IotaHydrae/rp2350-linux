# S4-04 · busybox 移植（riscv32 NOMMU，bFLT）

> RP2350 Linux 移植 · 工程 05（S4 文件系统篇）：把真正的 busybox（buildroot 编的 uClibc-ng + bFLT）请进根文件系统，PID 1 从"自写 shell"升级成 **busybox ash**，敲 ls/cat/grep 等 25 个 applet。

## 机制（本关新链）

1. **工具链**：riscv32 NOMMU 用户态只能 bFLT，libc 只能用 uClibc-ng（musl/glibc 不支持 NOMMU）。buildroot（`/home/developer/buildroot-2026.05.2`）生成整套：`riscv32-buildroot-linux-uclibc-gcc` + elf2flt + busybox。
2. **bFLT 转换**：buildroot 的包框架给目标 CFLAGS/LDFLAGS 自动加 `-Wl,-elf2flt=-r -static`（`package/Makefile.in:222`），所以 busybox 编出来直接是 `BFLT v4 ram gotpic`。脱离 buildroot 手编时自己带这套 flag。
3. **GOTPIC**：elf2flt 产的 bFLT 带 GOTPIC 标志，内核 `binfmt_flat` 的 GOTPIC 路径（GOT 在 data 头部、加载时加基址）第一次真机验证——之前 S3-05 手搓的 bFLT 都是无重定位、无 GOTPIC 的。
4. **/init 启动器**：根里 /init 是手搓无 libc 的 bFLT（pack-bflt.sh），只做三件事：把 tty dup3 成 0/1/2 → 挂 ramfs 到 /tmp（失败不阻塞）→ `execve("/bin/sh", ["sh"])`。`/bin/sh` 是 busybox 符号链接，busybox 按 argv[0] 分发成 ash——**PID 1 变成 busybox ash**。
5. **ramdisk 扩到 1MB**：busybox 566KB，512KB 的 brd 装不下 → `CONFIG_BLK_DEV_RAM_SIZE=512→1024`，内核重编。

## 决策（2026-08-31 用户拍板）

- 工具链路线 → **buildroot 当工具链工厂**（`qemu_riscv32_nommu_virt_defconfig` 裁剪掉内核/QEMU，只留工具链+elf2flt+busybox），已建 git 仓库（首提交无改动 `7729990a` + 我们的 defconfig `560114f5`）。
- **修掉浮点坑**：QEMU defconfig 默认 RISC-V 变体 G(imafd)/ilp32d（QEMU CPU 带 F/D），Hazard3 是 RV32IMAC 无 F/D → 改 `BR2_riscv_custom` + 关 F/D + 开 C + `ilp32`，clean 重编。
- busybox 尺寸方案 → **方案 A：扩 ramdisk 到 1MB**（默认 applet 集先跑通，S5 再裁）。

## 目录内容

- `bootloader/` — 本关 bootloader（banner=s4-04）
- `dts/` — 与 S4-03 相同（bootargs `root=/dev/ram rootfstype=ext2 init=/init` 不变）
- `initramfs-src/` — /init 启动器（无 libc bFLT：dup3 + ramfs /tmp + exec /bin/sh）
- `busybox` — buildroot 产物（566KB，`make busybox-s4-04` 从 buildroot 拷贝）
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
4. 敲命令验证 applet：`ls /bin`、`echo hello`、`cat /etc/passwd`（可能没有这个文件，正常）、`uname -a`

## 已知边界 / 排查

- **GOTPIC bFLT 首次真机验证是本关最大不确定点**：内核 `binfmt_flat` 的 GOTPIC 路径（GOT 头 + 加基址）代码核实过、QEMU 没跑过（QEMU 回归欠账未修）；如果 exec busybox 崩/卡，用调试器抓第一现场（`scripts/start-openocd.sh` + `gdb-dump.sh`，vmlinux 在 `/home/developer/linux-7.2/build-rv32-s4-04/vmlinux`）。
- 根默认只读：ash/applet 只读够用，/tmp 是 ramfs 可写（启动器挂的）；要写根给 bootargs 加 `rw`。
- `ps`/`dmesg` 等读 /proc 的 applet：本关内核 `CONFIG_PROC_FS=y`（默认开），启动器会挂 /proc，应该能用。
- `clear` 等少数 applet 没编进默认 busybox-minimal.config，符号链接没建；需要就调 busybox 配置重编。
- buildroot 重编/换配置记得 `make clean`（工具链选项变更必须 clean）；宿主环境两个坑见学习地图（PATH 空格路径 + uutils install 绕过）。
