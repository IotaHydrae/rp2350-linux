#!/usr/bin/env bash
#
# diff-kernels.sh —— 对比两个内核 vmlinux
#
# 用途：两个内核行为不同（比如改了配置/代码）时，快速看差异：
#   1. 符号表差异（哪些符号新增/删除/地址移动）
#   2. 函数数量/代码段大小
#   3. 可选：.config 差异
#
# 用法：
#   scripts/diff-kernels.sh <vmlinux A> <vmlinux B> [config A] [config B]
#
# 示例：
#   scripts/diff-kernels.sh build-rv32-02/vmlinux build-rv32-03/vmlinux \
#       build-rv32-02/.config build-rv32-03/.config

set -euo pipefail

A="${1:?用法: diff-kernels.sh <vmlinux A> <vmlinux B> [config A] [config B]}"
B="${2:?用法: diff-kernels.sh <vmlinux A> <vmlinux B> [config A] [config B]}"
CFG_A="${3:-}"
CFG_B="${4:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$A" "$B"; do
	[ -f "$f" ] || { echo "Error: file not found: $f" >&2; exit 1; }
done

echo "===== Basic info ====="
for f in "$A" "$B"; do
	printf "  %-70s %s bytes, %s\n" "$f" "$(stat -c%s "$f")" "$(stat -c%y "$f" | cut -d. -f1)"
done

echo
echo "===== Function count ====="
for f in "$A" "$B"; do
	n=$(riscv64-linux-gnu-nm "$f" 2>/dev/null | grep -c ' [tT] ')
	printf "  %-70s %d functions\n" "$f" "$n"
done

echo
echo "===== Symbol table diff (functions) ====="
riscv64-linux-gnu-nm -n "$A" 2>/dev/null | awk '$2 ~ /^[tT]$/ {print $3}' | sort > "$TMP/sym_a"
riscv64-linux-gnu-nm -n "$B" 2>/dev/null | awk '$2 ~ /^[tT]$/ {print $3}' | sort > "$TMP/sym_b"
echo "-- only in A --"
comm -23 "$TMP/sym_a" "$TMP/sym_b" | head -30
echo "-- only in B --"
comm -13 "$TMP/sym_a" "$TMP/sym_b" | head -30
echo "-- same name, different address (top 20) --"
riscv64-linux-gnu-nm -n "$A" 2>/dev/null | awk '$2 ~ /^[tT]$/ {print $3, $1}' | sort > "$TMP/addr_a"
riscv64-linux-gnu-nm -n "$B" 2>/dev/null | awk '$2 ~ /^[tT]$/ {print $3, $1}' | sort > "$TMP/addr_b"
awk 'NR==FNR {a[$1]=$2; next} ($1 in a) && a[$1] != $2 \
	{printf "  %-40s 0x%s -> 0x%s\n", $1, a[$1], $2}' \
	"$TMP/addr_a" "$TMP/addr_b" \
	| head -20

if [ -n "$CFG_A" ] && [ -n "$CFG_B" ] && [ -f "$CFG_A" ] && [ -f "$CFG_B" ]; then
	echo
	echo "===== .config diff ====="
	grep -E '^CONFIG_' "$CFG_A" | sort > "$TMP/cfg_a"
	grep -E '^CONFIG_' "$CFG_B" | sort > "$TMP/cfg_b"
	echo "-- only in A --"
	comm -23 "$TMP/cfg_a" "$TMP/cfg_b" | head -20
	echo "-- only in B --"
	comm -13 "$TMP/cfg_a" "$TMP/cfg_b" | head -20
else
	echo
	echo "(no .config given or files missing; skipping config diff)"
fi
