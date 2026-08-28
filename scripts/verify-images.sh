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

echo "===== 校验工程: $PROJ ====="

# 1) 内核 Image 一致性
IMG="$PROJ/kernel-Image"
BUILD_IMG="$BUILD_DIR/arch/riscv/boot/Image"
if [ -f "$IMG" ] && [ -f "$BUILD_IMG" ]; then
	a=$(sha256sum "$IMG" | awk '{print $1}')
	b=$(sha256sum "$BUILD_IMG" | awk '{print $1}')
	if [ "$a" = "$b" ]; then
		echo "✔ 内核 Image 一致 ($a)"
	else
		echo "✘ 内核 Image 不一致！"
		echo "   工程:  $a  $IMG"
		echo "   构建:  $b  $BUILD_IMG"
		echo "   请重新 make kernel-s3-0x"
	fi
else
	echo "⚠ 缺少内核 Image 或构建产物（$IMG / $BUILD_IMG）"
fi

# 2) DTB 反编译抽查
DTB="build/$PROJ/rp2350a-minimal.dtb"
if [ -f "$DTB" ]; then
	if dtc -I dtb -O dts "$DTB" >/dev/null 2>&1; then
		echo "✔ DTB 可正常反编译 ($DTB)"
		dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -c 'compatible' | xargs echo "   节点 compatible 数:"
	else
		echo "✘ DTB 反编译失败（文件可能损坏）"
	fi
else
	echo "⚠ 缺少 DTB: $DTB（先 make build/$PROJ/rp2350a-minimal.dtb）"
fi

# 3) bootloader UF2
UF2="build/$PROJ/s3-03-bootloader.uf2"
if [ -f "$UF2" ]; then
	echo "✔ bootloader UF2 存在 ($UF2, $(stat -c%s "$UF2") 字节)"
else
	echo "⚠ 缺少 bootloader UF2: $UF2（先 make all）"
fi

echo
echo "全部通过即可烧录：make flash-${PROJ#s3/}-kernel / flash-...-dtb"
