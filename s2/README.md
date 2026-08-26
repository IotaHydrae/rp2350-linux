# S2 · QEMU 跑真内核（riscv32 NOMMU M-mode）

> RP2350 Linux 移植 · 工程：S2。构建 riscv32 noMMU M-mode 内核，在 **QEMU virt** 上验证
> 启动协议（内核入口 / 链接地址 / 命令行 / earlycon），为真板 S3 铺路——**QEMU 首跑通过**。

## 这个工程验证什么

1. 内核构建：riscv32 + NOMMU + M-mode（`nommu_virt_defconfig` + `s2/rv32-nommu.config`）；
2. QEMU 里 `-kernel Image` 直接启动（`-bios none`，无 OpenSBI）；
3. earlycon 出字 + 启动日志推进到 rootfs（**rootfs panic 是预期断点**，S4 前无 rootfs）。

## 目录内容

- `run-qemu.sh` — 一键启动脚本（`KERNEL_SRC`/`BUILD_DIR`/`IMAGE` 可覆盖，额外参数透传给 qemu）
- `kernel-Image` — 预编译内核副本（脚本找不到时回退构建目录）
- `rv32-nommu.config` — 配置碎片（riscv32 + NOMMU + M-mode + 单核）

## 运行

```sh
make qemu                # 等价于 ./s2/run-qemu.sh
./s2/run-qemu.sh         # 退出 QEMU：Ctrl-A X
```

预期：Linux banner → 启动日志 → `earlycon: uart8250` → 内存信息 → **rootfs panic**（`/dev/vda` 找不到，
S4 前正常）。

## 内核构建（如需重编）

```sh
cd /home/developer/linux-7.2
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 nommu_virt_defconfig
cd build-rv32 && ../scripts/kconfig/merge_config.sh -m .config \
    /home/developer/iotahydrae/rp2350-linux/s2/rv32-nommu.config
cd .. && make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 -j$(nproc) Image
cp build-rv32/arch/riscv/boot/Image /home/developer/iotahydrae/rp2350-linux/s2/kernel-Image
```

## 注意（与真板的差异）

- QEMU virt 的 UART 是 **8250**（earlycon=`uart8250,mmio32,0x10000000`），DTB 由 QEMU 生成；
- 真板 RP2350 是 **PL011**（UART0 `0x40070000`）+ 自写 DTB（memory/clint 等）——S3 系列工程；
- 真板工程的内核构建已改为**完整 defconfig**（`make kernel-s3-0x`），不再用碎片，见 `notes/环境搭建.md`。

## 实验记录与参考

- `notes/实验日志/2026-08-21_S2_QEMU首跑.md`
- `notes/学习记录/S2 · QEMU 跑真内核.md`
- `notes/QEMU-virt-DTB参考.md`（QEMU 自动生成的 DTB 长什么样）
