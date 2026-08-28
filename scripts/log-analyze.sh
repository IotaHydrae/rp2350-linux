#!/usr/bin/env bash
#
# log-analyze.sh —— 内核串口日志快速体检（精简输出）
#
# 功能：
#   1. 异常/告警关键词行（WARNING / panic / BUG / Oops / mcause 等）
#   2. 日志末尾 N 行（看卡死前的现场）
#   3. Call Trace 裸地址批量翻译成 函数名 + 源文件:行号
#      （vmlinux 开了 DEBUG_INFO 就有行号；地址自动减基址）
#
# 用法：
#   scripts/log-analyze.sh <vmlinux> <日志文件> [末尾行数] [基址]
#     末尾行数可选，默认 30
#     基址可选，默认 0x11000000
#
# 示例：
#   scripts/log-analyze.sh /home/developer/linux-7.2/build-rv32-03/vmlinux \
#       /tmp/kern.log 20

set -euo pipefail

VMLINUX="${1:?用法: log-analyze.sh <vmlinux> <日志文件> [末尾行数] [基址]}"
LOG="${2:?用法: log-analyze.sh <vmlinux> <日志文件> [末尾行数] [基址]}"
TAIL_N="${3:-30}"
BASE="${4:-0x11000000}"

[ -f "$VMLINUX" ] || { echo "错误: 找不到 vmlinux: $VMLINUX" >&2; exit 1; }
[ -f "$LOG" ] || { echo "错误: 找不到日志: $LOG" >&2; exit 1; }

echo "## 异常/告警"
grep -nE 'WARNING:|Kernel panic|BUG:|Oops|Unable to handle|mcause|mepc|mtval' \
	"$LOG" || true

echo
echo "## 末尾 ${TAIL_N} 行"
tail -n "$TAIL_N" "$LOG"

echo
echo "## Call Trace"
grep -oP '\[<[0-9a-fA-F]+>\]' "$LOG" \
	| tr -d '[<>]' \
	| sort -u \
	| while read -r addr; do
		a=$((16#$addr))
		b=$((BASE))
		v=$((a >= b ? a - b : a))
		info=$(riscv64-linux-gnu-addr2line -e "$VMLINUX" -f -C \
			"$(printf '0x%x' "$v")" 2>/dev/null)
		func=$(printf '%s\n' "$info" | sed -n '1p')
		loc=$(printf '%s\n' "$info" | sed -n '2p' \
			| sed -E 's#/[^/]+/\.\./##g')
		[ "$loc" = "??:?" ] && loc=""
		printf "  0x%s  %s  %s\n" "$addr" "${func:-??}" "$loc"
	done
