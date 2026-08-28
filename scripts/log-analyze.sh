#!/usr/bin/env bash
#
# log-analyze.sh —— 内核串口日志快速体检（精简输出）
#
# 功能：
#   1. 异常/告警关键词行（WARNING / panic / BUG / Oops / mcause 等）
#   2. Call Trace 裸地址批量翻译成 函数名 + 源文件:行号
#      （vmlinux 开了 DEBUG_INFO 就有行号；地址自动减基址）
#
# 用法：
#   scripts/log-analyze.sh <vmlinux> <日志文件> [基址]
#     基址可选，默认 0x11000000
#
# 示例：
#   scripts/log-analyze.sh /home/developer/linux-7.2/build-rv32-03/vmlinux \
#       /tmp/kern.log

set -euo pipefail

VMLINUX="${1:?Usage: log-analyze.sh <vmlinux> <logfile> [base]}"
LOG="${2:?Usage: log-analyze.sh <vmlinux> <logfile> [base]}"
BASE="${3:-0x11000000}"

[ -f "$VMLINUX" ] || { echo "Error: vmlinux not found: $VMLINUX" >&2; exit 1; }
[ -f "$LOG" ] || { echo "Error: log file not found: $LOG" >&2; exit 1; }

echo "## Warnings/errors"
grep -nE 'WARNING:|Kernel panic|BUG:|Oops|Unable to handle|mcause|mepc|mtval' \
	"$LOG" || true

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
		# addr2line 会输出 .../build-rv32-03/../arch/... 这种带 .. 的路径，
		# 去掉 <dir>/.. 段（保留其后的 '/'，否则会把两个目录名焊在一起）
		loc=$(printf '%s\n' "$info" | sed -n '2p' \
			| sed -E 's#/[^/]+/\.\.##g')
		[ "$loc" = "??:?" ] && loc=""
		printf "  0x%s  %s  %s\n" "$addr" "${func:-??}" "$loc"
	done
