#!/usr/bin/env bash
#
# gdb-dump.sh —— 一键抓内核现场（内核卡死/异常时用）
#
# 连接 OpenOCD（localhost:3333），halt CPU，抓：
#   - pc/sp/ra 等关键寄存器 + mcause/mepc/mtval/mstatus（异常三件套）
#   - pc 附近反汇编
#   - 栈回溯 bt
# 然后用 pc-locate.sh 自动把 pc 翻译成符号/源文件/函数。
#
# 用法：
#   tools/gdb-dump.sh <vmlinux> [gdb 端口]
#     vmlinux 如 /home/developer/linux-7.2/build-rv32-03/vmlinux
#     端口默认 3333
#
# 前置：OpenOCD 已在跑（见 README 调试节）

set -euo pipefail

VMLINUX="${1:?用法: gdb-dump.sh <vmlinux> [gdb 端口]}"
PORT="${2:-3333}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cmds.gdb" <<'EOF'
set pagination off
set confirm off
set architecture riscv:rv32
target remote :PORT
monitor halt
printf "\n===== 寄存器 =====\n"
info registers pc ra sp tp
printf "\n===== 异常三件套 (OpenOCD) =====\n"
monitor reg mcause mepc mtval mstatus
printf "\n===== pc 附近反汇编 =====\n"
x/16i $pc-16
printf "\n===== 栈回溯 =====\n"
bt
printf "\n===== 栈顶 16 字 =====\n"
x/16wx $sp
quit
EOF

sed -i "s/:PORT/:$PORT/" "$TMP/cmds.gdb"

echo "===== GDB 现场抓取（$VMLINUX）====="
gdb-multiarch -batch -x "$TMP/cmds.gdb" "$VMLINUX" 2>&1 | tee "$TMP/out.txt"

# ---- 从输出提取 pc，自动定位符号/源文件/反汇编 ----
pc=$(grep -oP '^\s*pc\s+0x[0-9a-fA-F]+' "$TMP/out.txt" | grep -oP '0x[0-9a-fA-F]+' | head -1)
if [ -n "$pc" ]; then
	echo
	echo "===== PC 定位 ====="
	"$SCRIPT_DIR/pc-locate.sh" "$pc" "$VMLINUX"
else
	echo "（未从 GDB 输出提取到 pc，请手动执行 tools/pc-locate.sh <pc> $VMLINUX）"
fi
