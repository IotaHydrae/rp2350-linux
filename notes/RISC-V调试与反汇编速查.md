# RISC-V 调试与反汇编速查

> 整理自 2026-08-20 排查 psram-test「非法指令」异常的真实案例（mcause=2 @ 0x100000f4）。
> 适用场景：拿到一个地址（mepc / PC / 断点），想搞清楚「这里是什么代码、机器码是什么、为什么异常」。

## 0. 异常三件套（先记住这个）

RISC-V 机器异常发生时，硬件填好三个 CSR，然后跳到 mtvec 指向的入口：

| CSR | 地址 | 装什么 |
|---|---|---|
| mcause | 0x342 | 异常类型：0x2=非法指令，0x1=取指 fault，0x5=load fault，0x7=store/AMO fault…（完整表见数据手册 MCAUSE） |
| mepc | 0x341 | 出事的指令地址 |
| mtval | 0x343 | fault 时被访问的地址。⚠️ RP2350 的 Hazard3 把它硬连线为 0（手册 3.8.4.1），mtval=0 不代表没有目标地址 |

拿到 mcause 先查数据手册（`rp2350-datasheet.txt` 里 grep "MCAUSE"）；手册明确建议：模拟非法指令时自己 dereference mepc 读指令字节。

## 1. 工具清单（本仓库工具链）

| 工具 | 用途 | 路径 |
|---|---|---|
| riscv32-unknown-elf-addr2line | 地址 → 函数名 + 源码行 | /home/developer/toolchain/bin/ |
| riscv32-unknown-elf-objdump | 反汇编 / 看原始字节 | 同上 |
| riscv32-unknown-elf-nm | 符号表（找函数地址） | 同上 |
| riscv32-unknown-elf-as | 汇编器（对答案用） | 同上 |
| gdb-multiarch | 第二个反汇编器 + 读内存 | /usr/bin/gdb-multiarch |

前提：编译带符号（-g，pico-sdk 默认带），elf 别 strip。我们的 elf 在 `build/psram-test.elf`。

## 2. 命令速查（全部是本次真实用法）

### 2.1 地址 → 函数 + 源码行

```bash
riscv32-unknown-elf-addr2line -e build/psram-test.elf -f -C 0x100000f4
# 输出：test_region / tests/psram-test/main.c:43
```

### 2.2 反汇编某一段

```bash
riscv32-unknown-elf-objdump -d --start-address=0x100000e0 --stop-address=0x10000114 build/psram-test.elf
```

### 2.3 看原始字节（确认闪存/elf 里到底是什么）

```bash
riscv32-unknown-elf-objdump -s --start-address=0x100000f0 --stop-address=0x100000fa build/psram-test.elf
```

### 2.4 找函数在内存里的位置

```bash
riscv32-unknown-elf-nm -n build/psram-test.elf | grep test_region
```

### 2.5 汇编器「对答案」：验证某条指令的机器码

```bash
printf 'mv a5, a1\nsw a5, 0(a4)\n' > /tmp/check.s
riscv32-unknown-elf-as -march=rv32imac_zicsr_zifencei_zba_zbb_zbs_zbkb -o /tmp/check.o /tmp/check.s
riscv32-unknown-elf-objdump -d /tmp/check.o
```

### 2.6 gdb 第二意见（另一个反汇编器 + 读目标内存字节）

```bash
gdb-multiarch -batch \
  -ex 'set architecture riscv:rv32' \
  -ex 'x/4bx 0x100000f4' \
  -ex 'x/2i 0x100000f4' \
  build/psram-test.elf
```

## 3. 完整排查流程（本次案例复盘）

1. 现象：psram-test 自检停住，异常报告器打印 `mcause=2`、`mepc=0x100000f4`、`mtval=0`。
2. mcause=2 → 查数据手册：非法指令。
3. addr2line → 出事的代码在 `test_region`（main.c:43），即 PSRAM 写循环。
4. objdump -d → 0x100000f4 显示 `mv a5,a1`，合法指令？矛盾。
5. objdump -s + 汇编器对答案 → 字节 `ae 87` = `mv a5,a1`（两个工具自洽）。
6. gdb 交叉验证 → 同样结果。三个独立工具一致，反汇编可信。
7. 结论：异常上报与反汇编对不上 → 嫌疑转向硬件/芯片（后来换正常板验证：同代码大概率直接 PASS，该异常是坏芯片的连锁现象）。

## 4. 心法（踩过的坑）

- 反汇编别手算机器码：手算 c.mv 编码翻过车。以 objdump + gdb + 汇编器三者一致为准。
- 两个独立工具结论一致才可信：objdump 和 gdb 用的是不同解码实现，交叉验证成本极低。
- 看异常先分「中断 vs 异常」：mcause 第 31 位 = 1 是中断，= 0 是异常。
- 数据手册是最终裁判：Hazard3 的 mtval 恒 0、异常向量不偏移等特性都在手册 3.8.4 节。
- 链接错误 `relocation truncated to fit: R_RISCV_JAL`：向量表在 SRAM，JAL 跳转 ±1MB 够不着 flash 里的处理函数 → 用 `__not_in_flash_func()` 把函数放 RAM。

## 5. 以后遇到类似问题，按这个顺序走

1. 板子异常 → 先打印 mcause / mepc / mtval（异常报告器代码在 tests/psram-test/main.c，可直接复制）。
2. mepc → addr2line → objdump -d 附近。
3. 反汇编结果可疑 → objdump -s 看字节 → 汇编器对答案 → gdb 第二意见。
4. 还是对不上 → 怀疑硬件 / 时序 / 勘误，查数据手册对应章节，换板对照。
5. 每步把现象和结论记进学习记录。
