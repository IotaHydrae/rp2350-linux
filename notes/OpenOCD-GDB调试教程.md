# OpenOCD + GDB 调试教程（RP2350 RISC-V 实战）

> 以本项目 RP2350A-Minimal 为例：DAPLink（CMSIS-DAP）→ SWD → RISC-V 核。
> 配套速查：`RISC-V调试与反汇编速查.md`（异常三件套表 + objdump 反汇编命令）。
> 实战案例（AMO 墙定位全过程）：`学习记录/S3-00 · earlycon 工程：真板静默调试全过程.md`。

## 0. 架构：OpenOCD 和 GDB 各干什么

```
你 → gdb（前端：符号/断点/源码/分屏）
      ↓ TCP 3333（GDB 远程协议）
   OpenOCD（中间人：停核/读写寄存器内存/单步/复位）
      ↓ USB
   DAPLink（CMSIS-DAP 调试器）
      ↓ SWD
   RP2350 的 RISC-V 调试模块（riscv-dm，核内）
```

一句话：**OpenOCD 管"硬件动作"，GDB 管"人怎么用"**。GDB 通过 TCP 3333 发命令给 OpenOCD，OpenOCD 翻译成 SWD 上的调试事务。

## 1. 环境准备

### 1.1 OpenOCD：必须带 RP2350 RISC-V 支持

系统自带 OpenOCD 的 riscv 驱动是旧版，`rp2350.cfg` 里 `riscv -dap` 会报 `Unknown param: -dap`。本项目用的是从 `raspberrypi/openocd` 源码重编译的版本（`/home/developer/sources/openocd/src/openocd` 或已装到系统）。验证：`openocd --version` 后能正常 `Examined RISC-V core` 即为可用。

### 1.2 接线

DAPLink 的 `SWDIO / SWCLK / GND`（可选 3V3）接板子 SWD 焊盘。`lsusb` 应看到 CMSIS-DAP 设备（本项目 VID:PID 0x1a86:0x7021）。

### 1.3 免 root（可选）

OpenOCD 访问 USB 调试器需要权限；可用 udev 规则（见仓库 `udev/`）或 `sudo`。

## 2. 启动 OpenOCD（终端 1）

```sh
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"
```

关键点：
- `set USE_CORE rv0` 必须在 `-f target/rp2350.cfg` 之前——该配置文件默认建双 Cortex-M33 核，必须显式选 RISC-V 核 0。
- 启动日志里看到 `Examined RISC-V core`、`XLEN=32`、`Listening on port 3333 for gdb connections` 才算就绪。
- 三个端口：3333 = GDB、4444 = telnet（可直接敲 OpenOCD 命令）、6666 = Tcl。

## 3. 启动 GDB 并连接（终端 2）

```sh
gdb-multiarch /home/developer/linux-7.2/build-rv32/vmlinux
```

或裸机工具链的 `riscv32-unknown-elf-gdb`。连接：

```
(gdb) target remote localhost:3333
```

如果没加载 ELF 文件就连接，先设架构：

```
(gdb) set architecture riscv:rv32
```

### 3.1 符号问题：内核是 PIE，链接地址 ≠ 运行地址

vmlinux 的符号链接在地址 0，但内核实际跑在 `0x11000000`。直接 `break start_kernel` 会断在错误地址。两种办法：

**办法 A：给 GDB 一个重定位基址**（符号能用，断点/反汇编带函数名）：

```
(gdb) add-symbol-file /home/developer/linux-7.2/build-rv32/vmlinux 0x11000000
```

**办法 B：直接用绝对地址**（最稳，本项目实战用的）：

```sh
# 用 nm 查符号偏移，手工加 0x11000000
riscv64-linux-gnu-nm vmlinux | grep handle_exception   # → 0x195378
# 运行时地址 = 0x11000000 + 0x195378 = 0x11195378
```

注意：当前 vmlinux **只有符号表、没有行号调试信息**（`No debugging symbols found`），所以 `list` 看不到源码行。想看行号级源码，需要 `CONFIG_DEBUG_INFO=y` 重新编译内核。

## 4. 基础调试流程（本项目实战）

### 4.1 抓"现在停在哪"

板子卡住时：

```
(gdb) monitor halt
(gdb) info registers pc ra sp a0 a1
(gdb) monitor reg mcause
(gdb) monitor reg mepc
(gdb) x/8i $pc-16
```

⚠️ `monitor reg` 一次只查一个寄存器（`monitor reg mcause mepc` 会协议错误）。

解读：
- `pc` 在 `0x11000xxx` = 内核里；`0x1000xxxx` = flash（bootloader）；`0x20000000` 段 = SRAM。
- `mcause` 低 12 位 = 异常原因（见速查文档：2=非法指令、5=load fault、6/7=store/AMO fault、11=外部中断）。
- `mepc` = 出事指令地址，`mtval` = 被访问地址（Hazard3 恒 0）。

### 4.2 抓"第一次异常"（寄存器还没被处理逻辑弄脏）

在异常入口下硬件断点，复位重跑：

```
(gdb) hbreak *0x11195378      # handle_exception 入口（先 nm 查偏移）
(gdb) monitor reset halt
(gdb) continue
```

停住后立刻查 `mcause`/`mepc`/`mtval`——这就是**第一现场**。本项目靠这招定位到 `amoor.w` 撞 PSRAM AMO 墙。

## 5. GDB 常用指令教学

### 5.1 源码查看

```
(gdb) list                      # 当前行前后各 10 行
(gdb) list 100,120              # 指定行范围
(gdb) list function_name        # 某函数源码
(gdb) dir /path/to/src          # 追加源码搜索路径
(gdb) info source               # 当前源码文件信息
(gdb) disassemble /m function   # 源码+汇编混合（需要调试信息）
(gdb) disassemble /r $pc        # 汇编+机器码
```

> 前提：目标 ELF 带 DWARF 调试信息。本项目 vmlinux 目前没有，看汇编用 `x/i` 或 `disassemble`。

### 5.2 寄存器

```
(gdb) info registers            # 常用寄存器
(gdb) info all-registers        # 全部（含 CSR，若有）
(gdb) p/x $pc                   # 打印 PC（十六进制）
(gdb) p/x $sp
(gdb) set $pc = 0x11195378      # 直接改 PC（慎用）
```

CSR 若 GDB 不认（`$mcause` 未定义），走 OpenOCD：`monitor reg mcause`。

### 5.3 内存查看

```
(gdb) x/4wx 0x200103f0          # 4 个 32 位字，十六进制
(gdb) x/16i 0x1100e940          # 16 条反汇编指令
(gdb) x/s 0x11000000            # 字符串
(gdb) p *(uint32_t*)0x112ab558  # 按类型读内存（C 表达式）
```

格式说明：`x/<数量><格式><大小>`，格式 `x`=hex、`i`=指令、`s`=字符串、`d`=十进制；大小 `b/h/w/g`=1/2/4/8 字节。

### 5.4 断点

```
(gdb) break start_kernel        # 软件断点（符号，需重定位正确）
(gdb) hbreak *0x1100005c        # 硬件断点（绝对地址）
(gdb) break file.c:100          # 源码行号断点
(gdb) watch var                 # 数据写断点
(gdb) rwatch var                # 数据读断点
(gdb) break foo if x == 3       # 条件断点
(gdb) tbreak *0x...             # 一次性断点
(gdb) info breakpoints          # 列出断点
(gdb) disable 1 / enable 1 / delete 1
```

### 5.5 单步 / 继续

```
(gdb) continue / c              # 继续跑
(gdb) stepi / si                # 单步一条指令（进函数）
(gdb) nexti / ni                # 单步一条指令（不进的语义在汇编层一样）
(gdb) step / s                  # 单步一行源码（需调试信息）
(gdb) next / n                  # 单步一行源码，跳过函数调用
(gdb) finish                    # 跑完当前函数
(gdb) until                     # 跑出当前循环
```

### 5.6 调用栈

```
(gdb) bt                        # backtrace 调用栈
(gdb) frame 2                   # 切到第 2 帧
(gdb) up / down                 # 栈上/下移
(gdb) info args                 # 当前帧参数
(gdb) info locals               # 当前帧局部变量
```

### 5.7 TUI 分屏（重点）

```
(gdb) layout src                # 源码窗口
(gdb) layout asm                # 汇编窗口
(gdb) layout regs               # 寄存器窗口
(gdb) layout split              # 源码+汇编分屏
(gdb) tui reg general           # 寄存器窗口显示通用寄存器组
(gdb) focus asm / focus regs    # 焦点切换（方向键控制当前窗口）
(gdb) winheight asm +5          # 调整窗口高度
(gdb) refresh                   # 刷新（画面花时用）
(gdb) tui enable / tui disable
```

快捷键：`Ctrl-X A` 退出 TUI；`Ctrl-L` 刷新；方向键在焦点窗口滚动。单步时 `layout split` 会跟着 PC 高亮当前行/指令，是最常用的组合。

### 5.8 其他实用

```
(gdb) set pagination off        # 关掉分页（长输出不卡）
(gdb) set confirm off           # 关确认
(gdb) info functions pattern    # 查函数
(gdb) info variables pattern    # 查变量
(gdb) ptype struct pt_regs      # 看结构体定义
(gdb) monitor reset halt        # 复位并停住
(gdb) monitor resume            # 恢复运行
(gdb) maintenance packet "qTStatus"   # 低级调试（不常用）
```

## 6. 实战案例：抓 RP2350 AMO 墙（完整流程）

```sh
# 终端 1
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"

# 终端 2
gdb-multiarch /home/developer/linux-7.2/build-rv32/vmlinux
```

```
(gdb) target remote localhost:3333
(gdb) hbreak *0x11195378          # handle_exception
(gdb) monitor reset halt
(gdb) continue
Breakpoint 1, 0x11195378 in ?? ()
(gdb) monitor reg mcause          # → 0x7
(gdb) monitor reg mepc            # → 0x1100e94a
(gdb) x/4i $mepc                  # → amoor.w.aqrl a4,a3,(a5)
```

拿到 mepc 后，用 nm 找符号、objdump 看上下文（详见速查文档）：

```sh
riscv64-linux-gnu-objdump -d --start-address=0xe920 --stop-address=0xe980 build-rv32/vmlinux
```

## 7. 常见坑

1. **`monitor reg` 传多个寄存器** → 协议错误（`Protocol error with Rcmd`）。一次一个。
2. **符号地址不对** → 内核 PIE，符号要 `add-symbol-file ... 0x11000000` 或手动加偏移。
3. **`-dap` 参数报错** → OpenOCD 版本太旧，用 `raspberrypi/openocd` 重编译。
4. **连不上 3333** → OpenOCD 没起来或端口被占；看终端 1 日志。
5. **halt 后寄存器是乱码** → 可能是嵌套异常现场，别信第一次 halt 的上下文，用 `hbreak` 抓第一次异常。
6. **reset halt 后板子重跑** → 正常：会重新跑 bootloader → 内核，断点会在内核路径上命中。

## 8. 命令速查表

| 目的 | 命令 |
|---|---|
| 连接 | `target remote localhost:3333` |
| 停/继续 | `monitor halt` / `continue` / `monitor resume` |
| 复位并停 | `monitor reset halt` |
| 寄存器 | `info registers` / `p/x $pc` / `monitor reg mcause` |
| 内存 | `x/4wx addr` / `x/8i $pc` / `p *(uint32_t*)addr` |
| 断点 | `break` / `hbreak *addr` / `watch var` |
| 单步 | `si` / `ni` / `s` / `n` / `finish` |
| 调用栈 | `bt` / `frame` / `up` / `down` |
| 源码 | `list` / `dir` / `disassemble /m` |
| 分屏 | `layout split` / `layout regs` / `focus` / `winheight` |
| 异常三件套 | `monitor reg mcause` + `mepc` + `mtval` |
