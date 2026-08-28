# 2026-08-28 · S4-00 bootloader 拷 initramfs 验收

板子：RP2350A-Minimal（自研）；内核 sha `6e186867`（无内置 initramfs）；工程 `s4/00_boot-initramfs/`。

## 首次启动（四件套烧录）

```
=== s4-00 boot-initramfs bootloader ===
PSRAM available: 1, size: 8388608
partition 0 sectors [16, 783] -> flash 0x10010000, size 0x300000
partition 1 sectors [784, 799] -> flash 0x10310000, size 0x10000
partition 2 sectors [800, 1055] -> flash 0x10320000, size 0x100000
copy kernel 3145728 bytes: flash 0x10010000 -> PSRAM 0x11000000
copy done.
copy dtb 65536 bytes: flash 0x10310000 -> PSRAM 0x11700000
copy done.
copy initramfs 1048576 bytes: flash 0x10320000 -> PSRAM 0x11300000
copy done.
verify: kernel mismatches=0, dtb mismatches=0, initramfs mismatches=0
first bytes: b1 a8 00 00
disable irqs, jump to 0x11000000 (a0=0 hartid, a1=0x11700000 dtb)
```

内核无内置 initramfs，按 DTB `linux,initrd-start/end` 解包 bootloader 提供的 rootfs → `S3-05 initramfs OK` → shell 正常。

## 独立烧录验证（只烧分区 2）

rootfs 换成 S4-00 自有 /init（banner `S4-00 rootfs via bootloader OK`）→ `make flash-s4-00-rootfs` → 复位：

```
S4-00 rootfs via bootloader OK
# hello
Hello, world!
```

bootloader/内核/DTB 全部未重烧，新 rootfs 生效。

## 结论

- 固定约定链路通：DTB 写死 initrd-start/end + bootloader 拷到约定地址 + 内核 reserve/解包/释放。
- **rootfs 独立烧录成立**：改 rootfs 只烧分区 2。
