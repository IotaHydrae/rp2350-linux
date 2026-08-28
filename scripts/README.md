# tools/ —— 内核排查小工具

内核卡死/异常时定位问题用的脚本。都依赖 RISC-V 工具链（`riscv64-linux-gnu-*`）和 vmlinux。

| 脚本 | 作用 | 用法 |
|---|---|---|
| `pc-locate.sh` | 把 PC 值翻译成符号/源文件/反汇编片段 | `scripts/pc-locate.sh <pc> <vmlinux> [基址]` |
| `gdb-dump.sh` | 一键连 GDB 抓现场（寄存器/异常三件套/反汇编/栈回溯）+ 自动定位 pc | `scripts/gdb-dump.sh <vmlinux> [gdb 端口]` |
| `start-openocd.sh` | 启动 OpenOCD（参数化速度/核，防重复启动） | `scripts/start-openocd.sh [速度] [核]` |
| `log-analyze.sh` | 串口日志体检：提取告警/panic 关键词、末尾 N 行、Call Trace 地址批量翻译 | `scripts/log-analyze.sh <日志> [vmlinux] [末尾行数]` |
| `verify-images.sh` | 烧录前校验：kernel-Image 一致性、DTB 反编译、bootloader 存在性 | `scripts/verify-images.sh [工程目录] [构建目录]` |
| `diff-kernels.sh` | 对比两个 vmlinux：函数数量、符号表差异、可选 .config 差异 | `scripts/diff-kernels.sh <vmlinux A> <vmlinux B> [config A] [config B]` |

典型流程（真板卡死时）：

1. `scripts/start-openocd.sh` 起调试器；
2. `scripts/gdb-dump.sh /home/developer/linux-7.2/build-rv32-03/vmlinux`——一键拿到寄存器、反汇编、栈回溯和 pc 的符号定位；
3. 或者把串口日志存下来，`scripts/log-analyze.sh 日志.txt <vmlinux>` 批量体检；
4. 烧录前 `scripts/verify-images.sh` 防低级错误。
