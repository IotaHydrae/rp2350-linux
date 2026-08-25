# S3-00 · earlycon（真板只接串口）

> RP2350 Linux 移植 · 工程 00：bootloader 加载真内核 + 最小 DTB + earlycon。
> 本工程**没有通关**——它的价值是撞上并定位了 RP2350 移植的第一堵真墙：**PSRAM AMO 墙**。

## 这个工程验证什么

1. bootloader 从分区表读取真内核（3MB）和 DTB，拷到 PSRAM（内核 @ `0x11000000`、DTB @ `0x11700000`），按 RISC-V 协议跳转（a0=hartid，a1=DTB 地址）。
2. DTB 故意**不加** `timebase-frequency` 和 `riscv,cpu-intc`（原计划：earlycon 出字后看到 init_IRQ panic）。
3. 实际结果：内核在 earlycon 之前就死在第一条原子操作上——**PSRAM 不支持 AMO**，完全静默。

## 目录内容

- `bootloader/main.c` — 分区表 bootloader（KERNEL id0 / DTB id1 拷贝 + a1 跳转）
- `dts/rp2350a.dtsi` + `dts/rp2350a-minimal.dts` — 最小设备树（SoC 级 / 板级拆分，按需增量）
- `partition_table.json` — KERNEL @64K 3MB、DTB @3M+64K 64K
- `kernel-Image` — 内核镜像副本（从 `s2/kernel-Image` 拷入，保证本工程可独立复现）
- `rv32-nommu.config` — 本工程内核配置碎片（riscv32 + NOMMU + M-mode，即 S2 配置）
- 详细分析：`../../notes/学习记录/S3-00 · earlycon 工程：真板静默调试全过程.md`

## 如何复现

### 1. 构建

```sh
make all                      # 编译 bootloader + 各测试（不要 sudo！）
make build/s3/00_earlycon/rp2350a-minimal.dtb   # 编译 DTB
```

内核重建（本工程用独立构建目录 `build-rv32-00`）：

```sh
cd /home/developer/linux-7.2
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32-00 nommu_virt_defconfig
scripts/kconfig/merge_config.sh -O build-rv32-00 \
    /home/developer/iotahydrae/rp2350-linux/s3/00_earlycon/rv32-nommu.config
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32-00 -j$(nproc) Image
cp build-rv32-00/arch/riscv/boot/Image \
    /home/developer/iotahydrae/rp2350-linux/s3/00_earlycon/kernel-Image
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

### 4. GDB 看第一现场（复现 AMO 墙）

```sh
# 终端 1
sudo openocd -f interface/cmsis-dap.cfg -c "set USE_CORE rv0" -f target/rp2350.cfg -c "adapter speed 2000"
# 终端 2
gdb-multiarch ../../linux-7.2/build-rv32/vmlinux   # 或 riscv32-unknown-elf-gdb
(gdb) target remote localhost:3333
(gdb) hbreak *0x11195378       # handle_exception 入口（随内核构建变化，用 nm 查）
(gdb) monitor reset halt
(gdb) continue
# 停住后：
(gdb) monitor reg mcause       # 一次只查一个寄存器！
(gdb) monitor reg mepc
(gdb) x/4i $mepc
```

预期：`mcause=0x7`，`mepc` = `amoor.w.aqrl` 指令（`set_cpu_online` 写 `__cpu_online_mask`，PSRAM）。

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
cp s2/kernel-Image s3/00_earlycon/kernel-Image
```
