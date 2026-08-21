#!/usr/bin/env bash
# S2: 启动 QEMU 测试 riscv32 noMMU 内核
# 用法：./s2/run-qemu.sh [额外 qemu 参数...]   （退出 QEMU：Ctrl-A X）
set -e

KERNEL_SRC="${KERNEL_SRC:-/home/developer/linux-7.2}"
BUILD_DIR="${BUILD_DIR:-$KERNEL_SRC/build-rv32}"
IMAGE="$BUILD_DIR/arch/riscv/boot/Image"

if [ ! -f "$IMAGE" ]; then
    echo "找不到内核镜像: $IMAGE"
    echo "请先编译："
    echo "  cd $KERNEL_SRC"
    echo "  make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=$BUILD_DIR nommu_virt_defconfig"
    echo "  cd $BUILD_DIR && ../scripts/kconfig/merge_config.sh -m .config <仓库>/s2/rv32-nommu.config"
    echo "  make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=$BUILD_DIR -j\$(nproc)"
    exit 1
fi

exec qemu-system-riscv32 -M virt -m 128M -bios none \
    -kernel "$IMAGE" \
    -nographic \
    -append "earlycon=uart8250,mmio32,0x10000000 console=ttyS0" "$@"
