#!/usr/bin/env bash
#
# pc-locate.sh —— 把 GDB/日志里抓到的 PC 值翻译成可读信息
#
# 用途：内核卡死/异常时，GDB 抓到 pc（如 0x1108b7cc），用本脚本查：
#   1. 对应哪个符号/函数
#   2. 源码文件:行号（需要 vmlinux 带调试信息；没有就只给函数名）
#   3. 函数边界 + 该地址附近的反汇编片段（带指令字节）
#
# 用法：
#   tools/pc-locate.sh <pc> <vmlinux> [基址]
#     pc      可以是 PSRAM 加载地址（0x1108b7cc，默认基址 0x11000000）
#             也可以是 vmlinux 偏移（0x8b7cc，脚本自动识别）
#     vmlinux 内核符号文件（如 /home/developer/linux-7.2/build-rv32-03/vmlinux）
#     [基址]  可选，默认 0x11000000（本项目内核加载地址）
#
# 示例：
#   tools/pc-locate.sh 0x1108b7cc /home/developer/linux-7.2/build-rv32-03/vmlinux

set -euo pipefail

PC_ARG="${1:?用法: pc-locate.sh <pc> <vmlinux> [基址]}"
VMLINUX="${2:?用法: pc-locate.sh <pc> <vmlinux> [基址]}"
BASE="${3:-0x11000000}"

NM=riscv64-linux-gnu-nm
OBJDUMP=riscv64-linux-gnu-objdump
ADDR2LINE=riscv64-linux-gnu-addr2line

if [ ! -f "$VMLINUX" ]; then
	echo "错误: 找不到 vmlinux: $VMLINUX" >&2
	exit 1
fi

# ---- PC 转 vmlinux 偏移：PSRAM 加载地址减基址；纯偏移直接用 ----
pc=$((PC_ARG))          # bash 支持 0x 前缀
base=$((BASE))
if [ "$pc" -ge "$base" ]; then
	off=$((pc - base))
else
	off=$pc
fi
off_hex=$(printf '0x%x' "$off")

echo "PC: $PC_ARG -> vmlinux 偏移: $off_hex"
echo

# ---- 1) 函数符号：nm 按地址排序，取 <= off 的最后一个符号 ----
best=""
while read -r addr type name; do
	[ -z "$addr" ] && continue
	[[ "$addr" =~ ^[0-9a-fA-F]+$ ]] || continue
	a=$((16#$addr))
	if [ "$a" -le "$off" ]; then
		best="$addr $type $name"
	fi
done < <("$NM" -n "$VMLINUX" 2>/dev/null)

if [ -n "$best" ]; then
	read -r func_addr func_type func_name <<<"$best"
	echo "符号: $func_name  (0x$func_addr, $func_type)"
	func_off=$((off - 16#$func_addr))
	echo "      pc 距函数起点 +0x$(printf '%x' "$func_off")"
else
	echo "符号: (未找到，地址可能不在任何函数内)"
	func_addr=""
fi
echo

# ---- 2) 源文件:行号（addr2line，需要 DWARF 调试信息）----
echo "源文件:"
"$ADDR2LINE" -e "$VMLINUX" -f -C "$off_hex" 2>/dev/null || true
echo

# ---- 3) 反汇编片段：从函数起点（或 pc-16）到 pc+32 ----
if [ -n "$func_addr" ]; then
	start=$((16#$func_addr))
else
	start=$((off - 16))
fi
end=$((off + 48))
start_hex=$(printf '0x%x' "$start")
end_hex=$(printf '0x%x' "$end")
echo "反汇编 [$start_hex .. $end_hex]:"
"$OBJDUMP" -d "$VMLINUX" --start-address="$start_hex" --stop-address="$end_hex" 2>/dev/null \
	|| "$OBJDUMP" -d "$VMLINUX" --start-address="$start" --stop-address="$end"
echo

# ---- 4) 顺带给出 GDB 里可直接用的命令 ----
echo "GDB 速查:"
echo "  x/12i \$pc-16        # 反汇编（已连 GDB 时）"
echo "  info line *0x$off_hex   # 对应源码行（有调试信息时）"
