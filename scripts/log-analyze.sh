#!/usr/bin/env bash
#
# log-analyze.sh —— 内核串口日志快速体检
#
# 用途：喂一个串口日志文件，自动提取：
#   1. 异常/告警关键词行（WARNING / panic / BUG / Oops / mcause / mepc 等）
#   2. 日志末尾 N 行（默认 30，看卡死前的现场）
#   3. panic Call Trace 里的裸地址 [<0x...>] 批量翻译成符号（给 vmlinux 时）
#
# 用法：
#   scripts/log-analyze.sh <日志文件> [vmlinux] [末尾行数] [基址]
#     vmlinux 可选：给了就把 Call Trace 地址翻译成函数名
#     末尾行数可选，默认 30
#     基址可选，默认 0x11000000（内核加载地址；日志里的地址是 PSRAM 加载地址，
#      翻译前要减基址转成 vmlinux 符号表偏移）
#
# 示例：
#   scripts/log-analyze.sh notes/实验日志/2026-08-28_S3-03外设中断验收.md \
#       /home/developer/linux-7.2/build-rv32-03/vmlinux

set -euo pipefail

LOG="${1:?用法: log-analyze.sh <日志文件> [vmlinux] [末尾行数]}"
VMLINUX="${2:-}"
TAIL_N="${3:-30}"
BASE="${4:-0x11000000}"

if [ ! -f "$LOG" ]; then
	echo "错误: 找不到日志文件: $LOG" >&2
	exit 1
fi

echo "===== 1) 异常/告警关键词 ====="
grep -nE 'WARNING:|Kernel panic|BUG:|Oops|Unable to handle|mcause|mepc|mtval|No working init|Cannot open root' \
	"$LOG" || echo "（没有匹配到关键词）"

echo
echo "===== 2) 末尾 $TAIL_N 行 ====="
tail -n "$TAIL_N" "$LOG"

if [ -n "$VMLINUX" ] && [ -f "$VMLINUX" ]; then
	echo
	echo "===== 3) Call Trace 地址翻译 ====="
	# 提取 [<0x...>] 形式的地址（如 [<11008e70>]），去重后逐个查符号
	grep -oP '\[<[0-9a-fA-F]+>\]' "$LOG" \
		| tr -d '[<>]' \
		| sort -u \
		| while read -r addr; do
			a=$((16#$addr))
			b=$((BASE))
			if [ "$a" -ge "$b" ]; then
				v=$((a - b))     # PSRAM 加载地址 -> vmlinux 偏移
			else
				v=$a             # 本来就是偏移则直接用
			fi
			sym=$(riscv64-linux-gnu-addr2line -e "$VMLINUX" -f -C \
				"$(printf '0x%x' "$v")" 2>/dev/null \
				| head -1)
			printf "  0x%s -> %s\n" "$addr" "${sym:-??}"
		done
else
	echo
	echo "（未给 vmlinux，跳过 Call Trace 翻译。用法: log-analyze.sh <日志> <vmlinux>）"
fi
