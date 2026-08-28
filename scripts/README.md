# tools/ —— 内核排查小工具

内核卡死/异常时定位问题用的脚本。都依赖 RISC-V 工具链（`riscv64-linux-gnu-*`）和 vmlinux。

| 脚本 | 作用 | 用法 |
|---|---|---|
| `pc-locate.sh` | 把 PC 值翻译成符号/源文件/反汇编片段 | `tools/pc-locate.sh <pc> <vmlinux> [基址]` |
| `gdb-dump.sh` | 一键连 GDB 抓现场（寄存器/异常三件套/反汇编/栈回溯）+ 自动定位 pc | `tools/gdb-dump.sh <vmlinux> [gdb 端口]` |

典型流程（真板卡死时）：

1. 跑着 OpenOCD；
2. `tools/gdb-dump.sh /home/developer/linux-7.2/build-rv32-03/vmlinux`——一键拿到寄存器、反汇编、栈回溯和 pc 的符号定位；
3. 如果从日志里拿到 pc（比如 panic 打印的 `[<11008e70>]`），直接 `tools/pc-locate.sh 0x11008e70 <vmlinux>`。
