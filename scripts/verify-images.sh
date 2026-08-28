#!/usr/bin/env bash
#
# verify-images.sh —— 烧录前校验产物
#
# 用途：防止"烧了旧文件/文件不匹配"这类低级问题。检查：
#   1. 工程 kernel-Image 与内核构建产物 sha256 是否一致
#   2. DTB 能否正常反编译（dtc 抽查）
#   3. bootloader UF2 是否存在
#
# 用法：
#   scripts/verify-images.sh [工程目录] [内核构建目录]
#     工程目录默认 s3/03_irq
#     内核构建目录默认 /home/developer/linux-7.2/build-rv32-03
#
# 示例：
#   scripts/verify-images.sh s3/02_timer /home/developer/linux-7.2/build-rv32-02

set -euo pipefail

PROJ="${1:-s3/03_irq}"
BUILD_DIR="${2:-/home/developer/linux-7.2/build-rv32-03}"

echo "===== Verifying project: $PROJ ====="

# 1) 内核 Image 一致性
IMG="$PROJ/kernel-Image"
BUILD_IMG="$BUILD_DIR/arch/riscv/boot/Image"
if [ -f "$IMG" ] && [ -f "$BUILD_IMG" ]; then
	a=$(sha256sum "$IMG" | awk '{print $1}')
	b=$(sha256sum "$BUILD_IMG" | awk '{print $1}')
	if [ "$a" = "$b" ]; then
		echo "[OK] kernel Image matches ($a)"
	else
		echo "[FAIL] kernel Image MISMATCH!"
		echo "  repo:   $a  $IMG"
		echo "  build:  $b  $BUILD_IMG"
		echo "  rerun make kernel-s3-0x"
	fi
else
	echo "[WARN] missing kernel Image or build output ($IMG / $BUILD_IMG)"
fi

# 2) DTB 反编译抽查
DTB="build/$PROJ/rp2350a-minimal.dtb"
if [ -f "$DTB" ]; then
	if dtc -I dtb -O dts "$DTB" >/dev/null 2>&1; then
		echo "[OK] DTB decompiles cleanly ($DTB)"
		dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -c 'compatible' | xargs echo "  compatible nodes:"
	else
		echo "[FAIL] DTB decompile failed (file may be corrupt)"
	fi
else
	echo "[WARN] missing DTB: $DTB (run make build/$PROJ/rp2350a-minimal.dtb first)"
fi

# 3) bootloader UF2
UF2="build/$PROJ/s3-03-bootloader.uf2"
if [ -f "$UF2" ]; then
	echo "[OK] bootloader UF2 present ($UF2, $(stat -c%s "$UF2") bytes)"
else
	echo "[WARN] missing bootloader UF2: $UF2 (run make all first)"
fi

echo
echo "When all pass: make flash-${PROJ#s3/}-kernel / flash-...-dtb"
