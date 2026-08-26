# S3-00 · AMO 墙定位（真板引导最小 DTB）

> RP2350 Linux 移植 · 工程 00：bootloader 加载真内核 + 最小 DTB，原计划 earlycon 出字后看到 init_IRQ panic。
> 本工程**没有通关**——它的价值是撞上并定位了 RP2350 移植的第一堵真墙：**PSRAM AMO 墙**。

## 这个工程验证什么

1. bootloader 从分区表读取真内核（3MB）和 DTB，拷到 PSRAM（内核 @ `0x11000000`、DTB @ `0x11700000`），按 RISC-V 协议跳转（a0=hartid，a1=DTB 地址）。
2. DTB 故意**不加** `timebase-frequency` 和 `riscv,cpu-intc`（原计划：earlycon 出字后看到 init_IRQ panic）。
3. 实际结果：内核在 earlycon 之前就死在第一条原子操作上——**PSRAM 不支持 AMO**，完全静默。

## 目录内容

- `bootloader/main.c` — 分区表 bootloader（KERNEL id0 / DTB id1 拷贝 + a1 跳转）
- `dts/rp2350a.dtsi` + `dts/rp2350a-minimal.dts` — 最小设备树（SoC 级 / 板级拆分，按需增量）
- `partition_table.json` — KERNEL @64K 3MB、DTB @3M+64K 64K
- `kernel-Image` — 本工程内核镜像（构建自 `/home/developer/linux-7.2`，`O=build-rv32-00`）
- `rp2350_amowall_defconfig` — **完整**内核 defconfig（= 01 的 `rp2350_minimal_defconfig` **去掉** `CONFIG_RISCV_AMO_EMULATION`，即"没有模拟器"的版本，用来复现撞墙）；只放工程内，构建时拷进 `build-rv32-00/.config` 再 `olddefconfig`
- 详细分析：`../../notes/学习记录/S3-00 · earlycon 工程：真板静默调试全过程.md`

## 如何复现

### 1. 构建

```sh
make all                      # 编译 bootloader + 各测试（不要 sudo！）
make build/s3/00_amowall/rp2350a-minimal.dtb   # 编译 DTB
```

内核重建（本工程用独立构建目录 `build-rv32-00`）：

```sh
make kernel-s3-00    # 工程根目录：配置 → 编译 → 拷贝到 s3/00_amowall/kernel-Image
```

手动等价命令：

```sh
cd /home/developer/linux-7.2
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32-00 rp2350_amowall_defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32-00 -j$(nproc) Image
cp build-rv32-00/arch/riscv/boot/Image \
    /home/developer/iotahydrae/rp2350-linux/s3/00_amowall/kernel-Image
```

### 2. 烧录（BOOTSEL 模式）

```sh
make flash-s3-00-bootloader   # 烧 bootloader（内嵌分区表）
# 拔线 → 按住 BOOTSEL 重新插线（分区表生效需要重启再进 BOOTSEL）
make flash-s3-00-kernel       # 内核 → 分区 0
make flash-s3-00-dtb          # DTB → 分区 1
```

### 3. 运行观察

正常上电。bootloader 日志（USB ttyACM0 / UART0）：

```
partition 0 sectors [16, 783] -> flash 0x10010000, size 0x300000
partition 1 sectors [784, 799] -> flash 0x10310000, size 0x10000
copy kernel 3145728 bytes ...
disable irqs, jump to 0x11000000 (a0=0 hartid, a1=0x11700000 dtb)
```

之后**内核零输出**（预期复现点：PSRAM AMO 墙，早于 earlycon）。

> **确认静默卡死后，下一步就是拿出调试器抓第一现场**——不要只停留在"没输出"，
> 用 GDB 停在内核异常入口，确认 mcause/mepc 是不是 AMO 墙（下面第 4 节）。

### 4. 调试器抓第一现场（复现 AMO 墙的关键动作）

```sh
# 终端 1：启动 OpenOCD（RP2350 RISC-V 核 0）
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"
# 终端 2：连 GDB（用本工程的 vmlinux：build-rv32-00）
gdb-multiarch ../../linux-7.2/build-rv32-00/vmlinux   # 或 riscv32-unknown-elf-gdb
```

```gdb
(gdb) set architecture riscv:rv32      # 必须显式设 rv32，否则报 "bfd requires xlen 8"！
(gdb) target remote localhost:3333
(gdb) hbreak *0x11196718               # handle_exception 入口（本内核实测值）
                                       # 换内核后重新查：nm build-rv32-00/vmlinux | grep handle_exception
                                       # 运行时地址 = link 地址 + 0x11000000
(gdb) monitor reset halt
(gdb) continue
```

停住后（第一次异常）：

```sh
(gdb) monitor reg mcause       # 一次只查一个寄存器！
(gdb) monitor reg mepc
(gdb) monitor reg mtval
(gdb) x/4i $mepc
```

预期（本内核实测）：

```
mcause = 0x00000007                  # Store/AMO 访问 fault
mepc   = 0x1100e94a                  # set_cpu_online 里的 amoor.w.aqrl a4,a3,(a5)
mtval  = 0x00000000                  # RP2350 对 AMO fault 不写 mtval（以 mepc 为准）
```

`x/4i $mepc` 应看到：

```
0x1100e94a:  amoor.w.aqrl    a4,a3,(a5)
```

这就是 PSRAM AMO 墙的第一现场：内核第一条原子操作（写 `__cpu_online_mask`）触发 mcause=7，
早于任何 printk/earlycon，所以真板完全静默。抓到这一现场，S3-00 就算完整闭环。

> 调试小坑：OpenOCD halt/step 会弄脏 `mscratch`（GDB 里看到 `mscratch=0x1120f3c0` 是假象）；
> 正常启动时 mscratch=0。本工程"静默"排查方法论见 `notes/学习记录/S3-01 · 从AMO墙到earlycon出字：完整踩坑历程.md`。

### 5. amo-test 对照实验（确认硬件行为）

```sh
make flash-amo-test            # 会覆盖 flash 开头的 bootloader（正常）
```

预期输出：

```
SRAM  AMO: ok, var=1
PSRAM AMO: TRAP mcause=0x00000007 mepc=0x100001cc mtval=0x00000000
           AMO 被跳过，变量=0
```

跑完测试想回到内核实验：重新执行第 2 步烧 bootloader。

## 已知结论

- RP2350 Hazard3 把 AMO 实现为"排他读-写对"，排他访问只在 SRAM 支持（手册 3.1.5）→ PSRAM 上 AMO → mcause=7。
- 内核第一条原子操作在 `boot_cpu_init() → set_cpu_online()`（早于任何 printk）→ 完全静默。
- 正路修法：M 模式 AMO 模拟器（trap 里解码 AMO、单核 + 中断关 = 原子性成立），下个工程。

## 内核镜像同步

`kernel-Image` 是 `s2/kernel-Image` 的副本。重新构建内核后：

```sh
cp s2/kernel-Image s3/00_amowall/kernel-Image
```
