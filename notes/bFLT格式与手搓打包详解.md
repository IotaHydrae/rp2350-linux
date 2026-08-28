# bFLT 格式与手搓打包详解（elf2flt 的替代）

> rp2350-linux 移植笔记 · 为什么 NOMMU 用户态只能用 FLAT、bFLT 文件长什么样、加载器怎么把它跑起来、我们怎么不装 elf2flt 直接手搓。源码基于 linux-7.2，核对于 S3-05（2026-08-28）。工具：`scripts/pack-bflt.sh`。

## 为什么需要 bFLT

- `fs/Kconfig.binfmt` 里 `CONFIG_BINFMT_ELF` **`depends on MMU`** → riscv32 NOMMU 内核根本没有 ELF 支持，用户态只能用 uClinux FLAT（bFLT，`CONFIG_BINFMT_FLAT=y`）。
- 本机没有 elf2flt（`which elf2flt` 找不到、apt 也没有）→ 手搓打包。
- elf2flt 是 uClinux 的标准工具：编译出普通 ELF，再转成 bFLT。我们的做法等价——直接生成 bFLT 文件，只是多承担了格式细节。

## bFLT 文件格式（include/linux/flat.h，全字段大端 __be32）

`struct flat_hdr` **64 字节**（magic 4 + 10 个 `__be32` 字段 40 + `filler[5]` 20），后面依次是 text、data、bss（bss 不在文件里）：

| 偏移 | 字段 | 说明 |
|---|---|---|
| 0 | magic | `"bFLT"` |
| 4 | rev | `FLAT_VERSION` = 4 |
| 8 | entry | 入口指令的**文件偏移**（text 从偏移 64 开始，所以一般 = 64） |
| 12 | data_start | 数据段起始的文件偏移（= 64 + text 长度） |
| 16 | data_end | 数据段结束的文件偏移 |
| 20 | bss_end | bss 结束的文件偏移（data_end..bss_end 是 bss，不落盘） |
| 24 | stack_size | 栈大小（加载器分配） |
| 28 | reloc_start | 重定位记录偏移（无 = 0） |
| 32 | reloc_count | 重定位条数（无 = 0） |
| 36 | flags | `FLAT_FLAG_RAM` = 1（整段载入 RAM） |
| 40 | build_date | 0 |
| 44 | filler[5] | 0 |

## 加载器行为（fs/binfmt_flat.c，RAM 模式）

- `text_len = data_start`（**包含 64 字节头**）；`data_len = data_end - data_start`；`bss_len = bss_end - data_end`。
- 分配 text+data+bss+stack 连续内存；把文件 `[0, data_start)` 拷到 textpos（头被拷进去也无害），data 从文件 `data_start` 拷到 datapos。
- `datapos = ALIGN(textpos + data_start + DATA_START_OFFSET_WORDS*4, FLAT_DATA_ALIGN=0x20)` → **data 的文件偏移必须 32 字节对齐**，否则 datapos 和 textpos+data_start 之间出现缝隙，链接器算好的 PC-relative 偏移全部错位。
- bss 清零；栈指针由加载器设置（`start_thread(regs, start_addr, start_stack)`）。
- 入口 `start_addr = textpos + entry`（entry 是文件偏移，`_start` 在 text 开头时 entry=64）。

## 为什么我们的代码可以"无重定位"

bFLT 不携带加载地址，加载器想放哪放哪 → 代码必须位置无关且**没有重定位**。编译参数与原因：

- `-fPIC`：内部符号访问走 PC-relative（auipc/addi），链接期就算死成立即数，运行期与加载地址无关；
- `-mno-relax`：禁止链接器再动这些 PC-relative 对（否则可能留下 R_RISCV_RELAX），保证最终 ELF 无重定位；
- `-msmall-data-limit=0`：所有数据进 .data/.bss，禁用 gp 相对访问（gp 需要 crt 初始化，我们没有 crt）；
- `-nostdlib`：无 libc，杜绝外部符号/GOT/函数指针表；
- 只用内部 static 数据 + ecall 内联汇编发系统调用（U-mode → M-mode，a7=系统调用号，如 write=64）。
- 打包脚本用 `readelf -r` 检查：出现任何 R_RISCV 重定位就报错。

## 链接脚本（s3/05_shell/initramfs-src/init.ld）

- `.text` 从 0x0 开始，`_start` 是第一个符号（entry 可写死 32，脚本有 0x0 校验兜底）；
- `.data` 紧随 .text 且 `ALIGN(0x20)`（满足 datapos 对齐，脚本有校验）；
- 定义 `_data_start` / `_bss_start` / `_bss_end` 符号供打包脚本取尺寸；
- `PHDRS`：text R+X、data R+W（链接器硬要求，顺带避免 RWX 段）。

## 打包操作（make init-s3-05）

1. gcc 编译链接 → `build/init-s3-05.elf`；
2. `objcopy -O binary` → blob（text + 对齐缝隙补零 + data）；
3. 脚本从 `nm` 取符号：`_start`（必须 0x0）、`_data_start`（必须 32 对齐）、`_bss_start`/`_bss_end`；
4. 拼 64 字节大端头 + blob → `initramfs/init`；chmod 755；
5. `initramfs.list`（gen_init_cpio 清单）把 `/init` 和 `/dev/console` 编进内核 Image。

## 本地验证（2026-08-28）

- `od` 头（修复后）：`bFLT` / rev=4 / entry=0x40(64) / data_start=0x60(96) / data_end=0x74(116) / bss_end=0x74 / stack=0x10000 / flags=1 ✓；文件偏移 64 处 = `4505`（li a0,1）✓；
- `readelf -r`：无重定位 ✓；
- `objdump`：`write(1, banner@0x80, 19)` + 死循环，banner 字符串在 .data 0x80 ✓。

## 已知风险/易错点（先记着，踩到再改）

- **bFLT 头是 64 字节不是 32**（2026-08-28 真板踩过）：`struct flat_hdr` 有 `filler[5]`，`entry` 必须 = 64（text 起点）。曾按 32 算，entry 指向头的 filler 零区 → 执行时 SIGILL（`unhandled signal 4` at 入口，`Code:` 全零）。改 `pack-bflt.sh` 的 `HDR_SIZE=64`。
- **链接必须 `-no-pie`**（同次踩过）：默认 PIE 的 ELF 带 `.interp/.dynsym/.dynamic/.got` 动态段，objcopy -O binary 输出被污染（text 前多出 32 字节零/错位），加载器入口落零。已加 `-no-pie` + 链接脚本 `/DISCARD/` 动态段 + 打包脚本"ELF 类型必须 EXEC"校验。
- **依赖链接脚本与编译参数的配合**：改 init.c 用了 64 位除法 / memcpy / 任何 libgcc 辅助函数、或引入外部符号 → 要么产生重定位（脚本报错），要么出现 gp 访问（乱跑）。对策：`-fno-builtin`、避免 64 位运算、必要时自己写小 memcpy。
- **entry 写死 32**：`_start` 必须是 .text 第一个符号；插了其它段会错（脚本 0x0 校验兜底）。
- **data 32 对齐**：链接脚本 ALIGN(0x20) + 脚本校验双保险。
- **bss 尺寸**：目前 bss=0；以后加全局变量靠 `_bss_start/_bss_end` 符号，链接脚本顺序错（bss 后还有数据）会出错。
- **stack_size=64KB**：深递归/大数组可能爆栈，届时调大。
- **elf2flt 才是标准做法**：以后装上 elf2flt（或网络通了）可以换标准工具链，pack-bflt.sh 留作教学与兜底。
