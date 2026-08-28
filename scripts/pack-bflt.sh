#!/usr/bin/env bash
# pack-bflt.sh —— 把 -nostdlib 的静态 ELF 打成 uClinux bFLT 可执行文件
#
# 为什么存在：riscv32 NOMMU 内核 CONFIG_BINFMT_ELF 依赖 MMU（fs/Kconfig.binfmt），
# 用户态只能用 FLAT 格式（CONFIG_BINFMT_FLAT=y）；本机工具链没有 elf2flt，
# 所以手搓 bFLT（格式细节见学习记录 S3-05，加载器内核 fs/binfmt_flat.c）。
#
# bFLT 头是 64 字节（magic 4 + 10 个 __be32 字段 40 + filler[5] 20），text 从文件偏移 64 开始。
# 前提（由 initramfs-src/init.ld 和编译参数保证）：
#   - .text 从 0x0 开始，_start 是第一个符号（bFLT entry = 64 + _start 偏移 = 64）
#   - .data 紧随 .text 且 32 字节对齐（加载器 FLAT_DATA_ALIGN=0x20，datapos 要对齐）
#   - 无运行时重定位（-fPIC -mno-relax -msmall-data-limit=0 + 全内部符号），有则报错
#   - ELF 里有 _data_start / _bss_start / _bss_end 符号（链接脚本定义）
#
# 用法：pack-bflt.sh <elf> <out> [stack_size]
set -euo pipefail

ELF="${1:?usage: pack-bflt.sh <elf> <out> [stack_size]}"
OUT="${2:?usage: pack-bflt.sh <elf> <out> [stack_size]}"
STACK="${3:-65536}"

CROSS="${CROSS:-riscv64-linux-gnu-}"
NM="${NM:-${CROSS}nm}"
OBJCOPY="${OBJCOPY:-${CROSS}objcopy}"
READELF="${READELF:-${CROSS}readelf}"

HDR_SIZE=64   # sizeof(struct flat_hdr)：magic(4) + 10*__be32(40) + filler[5](20)

elf_type=$("$READELF" -h "$ELF" | awk '/Type:/ {print $2}')
if [ "$elf_type" = "DYN" ]; then
	echo "error: ELF 是 PIE/DYN 类型（带动态段），objcopy 输出会被污染——编译请加 -no-pie" >&2
	exit 1
fi

if "$READELF" -r "$ELF" | grep -qE 'R_RISCV_'; then
	echo "error: ELF 里还有运行时重定位，bFLT 需要纯 PC-relative 代码" >&2
	"$READELF" -r "$ELF" >&2
	exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$OBJCOPY" -O binary "$ELF" "$tmp/blob.bin"

entry=$("$NM" "$ELF" | awk '$3=="_start" {print "0x"$1; exit}')
data_start=$("$NM" "$ELF" | awk '$3=="_data_start" {print "0x"$1; exit}')
bss_start=$("$NM" "$ELF" | awk '$3=="_bss_start" {print "0x"$1; exit}')
bss_end=$("$NM" "$ELF" | awk '$3=="_bss_end" {print "0x"$1; exit}')
if [ -z "$entry" ] || [ -z "$data_start" ] || [ -z "$bss_start" ] || [ -z "$bss_end" ]; then
	echo "error: ELF 缺 _start/_data_start/_bss_start/_bss_end 符号" >&2
	exit 1
fi

if [ $((entry)) -ne 0 ]; then
	echo "error: _start 必须在 0x0（当前 $entry），bFLT entry = 64 + _start 偏移" >&2
	exit 1
fi
if [ $((data_start % 32)) -ne 0 ]; then
	echo "error: _data_start 必须 32 对齐（当前 $data_start）" >&2
	exit 1
fi

blob_size=$(stat -c %s "$tmp/blob.bin")
text_len=$((data_start))             # text 段（含 objcopy 补的对齐 pad）
data_len=$((blob_size - text_len))   # 真正落盘的 data
bss_len=$((bss_end - bss_start))

# bFLT 头：64 字节，全部大端（加载器 ntohl），偏移相对文件头
be32() { # $1=值 $2=输出文件
	printf '%b' "\\$(printf '%03o' $(((($1 >> 24) & 255))))" \
		"\\$(printf '%03o' $(((($1 >> 16) & 255))))" \
		"\\$(printf '%03o' $(((($1 >> 8) & 255))))" \
		"\\$(printf '%03o' $(($1 & 255)))" >> "$2"
}

hdr="$tmp/hdr.bin"
printf 'bFLT' > "$hdr"
be32 4 "$hdr"                                           # rev = FLAT_VERSION(4)
be32 $HDR_SIZE "$hdr"                                   # entry = 文件偏移 64（text 起点）
be32 $((HDR_SIZE + text_len)) "$hdr"                    # data_start
be32 $((HDR_SIZE + text_len + data_len)) "$hdr"         # data_end
be32 $((HDR_SIZE + text_len + data_len + bss_len)) "$hdr"  # bss_end
be32 "$STACK" "$hdr"                                    # stack_size
be32 0 "$hdr"                                           # reloc_start
be32 0 "$hdr"                                           # reloc_count
be32 1 "$hdr"                                           # flags = FLAT_FLAG_RAM
be32 0 "$hdr"                                           # build_date
printf '%b' "\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000" >> "$hdr"

cat "$hdr" "$tmp/blob.bin" > "$OUT"
chmod 755 "$OUT"
echo "packed $OUT: entry=$HDR_SIZE text=$text_len data=$data_len bss=$bss_len stack=$STACK total=$(stat -c %s "$OUT")"
