# RISC-V 汇编指令速查（ARM 对照版）

> 给懂 ARM 汇编、刚开始碰 RISC-V 的人用。原则：先讲**结构性差异**（这是 ARM 思维最容易翻车的地方），再给指令表（每条挂 ARM 对照）。本文以 RV32 为主（RP2350 的 Hazard3 是 RV32IMAC + Zb* 扩展）。

## 0. 和 ARM 最不一样的五个点（先记住这些）

1. **没有标志位寄存器（CPSR 那类东西）**。ARM 的 `cmp` + `bne` 两步，在 RISC-V 里是一条指令直接比较两个寄存器：`bne a0, a1, label`。加减法不产生任何「进位/零/负」状态。
2. **PC 不能直接读写**。ARM 可以 `mov pc, ...` / 读 r15；RISC-V 里拿当前地址要靠 `auipc`（见下）。跳转也只靠 `jal` / `jalr` 两种。
3. **只有一种寻址模式**：基址寄存器 + 12 位有符号立即数（`lw a0, 8(a1)`）。ARM 的花样（前变址、后变址、寄存器偏移、字面量池）都没有。
4. **x0 是恒 0 寄存器**。写它被丢弃，读它得 0。很多「丢弃结果」的写法都用 x0 当目标（比如 `ret` 其实是 `jalr x0, 0(ra)`）。
5. **立即数很小**：I 型指令立即数只有 12 位（-2048 ~ 2047）。大常数要 `lui` + `addi` 拼，大地址要 `auipc` + `addi` 拼（编译器/汇编器用 `li` / `la` 伪指令替你拼）。

## 1. 寄存器（对照 ARM）

| RISC-V | ABI 名 | 用途 | ARM 对照 |
|---|---|---|---|
| x0 | zero | 恒 0 | 无（类似「读 0 / 丢弃写」的惯例） |
| x1 | ra | 返回地址 | lr |
| x2 | sp | 栈指针 | sp |
| x3 | gp | 全局指针（一般不用） | — |
| x4 | tp | 线程指针 | — |
| x5-x7 | t0-t2 | 临时（调用者保存） | r0-r3 等临时 |
| x8 | s0/fp | 保存寄存器 / 帧指针 | r4-r11 里当帧指针的那个 |
| x9 | s1 | 保存寄存器 | r4-r11 |
| x10-x17 | a0-a7 | 参数 / 返回值（a0,a1） | r0-r3 |
| x18-x27 | s2-s11 | 保存寄存器 | r4-r11 |
| x28-x31 | t3-t6 | 临时 | r0-r3 等临时 |

关键点：**函数参数在 a0-a7，返回地址在 ra，栈在 sp**——这就是启动协议里 `a0 = hartid`、`a1 = DTB` 能生效的原因（跳转时参数就摆在 a0/a1 里）。

## 2. 常用指令速查

### 数据传输（加载立即数/地址）

| 指令 | 作用 | ARM 对照 |
|---|---|---|
| `li rd, imm`（伪指令） | 加载任意 32 位立即数（拆成 lui+addi） | `movw`+`movt` / `ldr rd, =imm` |
| `la rd, symbol`（伪指令） | 取符号地址（auipc+addi） | `adr` / `ldr rd, =symbol` |
| `lui rd, imm20` | 立即数放进高 20 位，低 12 位清零 | `movw` 高半部分 |
| `auipc rd, imm20` | PC + 高 20 位立即数（拿「当前地址附近」的地址） | 无直接对照（ARM 有 PC 相对的字面量池） |

### 访存（只有基址+偏移）

| 指令 | 作用 | ARM 对照 |
|---|---|---|
| `lw rd, imm(rs1)` | 读 32 位 | `ldr` |
| `lb` / `lbu` | 读 8 位（符号扩展 / 零扩展） | `ldrsb` / `ldrb` |
| `lh` / `lhu` | 读 16 位 | `ldrsh` / `ldrh` |
| `sw rs2, imm(rs1)` | 写 32 位 | `str` |
| `sb` / `sh` | 写 8 / 16 位 | `strb` / `strh` |

没有 `ldr rd, [rs1, rs2]`（寄存器偏移）——先 `add` 再 `lw`。没有 `ldm/stm`——逐个来。

### 算术 / 逻辑

| 指令 | 作用 | ARM 对照 |
|---|---|---|
| `add` / `addi` | 加（寄存器 / 立即数） | `add` / `add r, r, #imm` |
| `sub` | 减 | `sub` |
| `and` / `or` / `xor`（+`andi` 等） | 逻辑 | 同名 |
| `slli` / `srli` / `srai` | 左移 / 逻辑右移 / 算术右移 | `lsl` / `lsr` / `asr` |
| `mul` / `div` / `rem` | 乘 / 除 / 余数 | 无（ARM 用乘法器指令或库） |
| `not rd, rs`（伪指令） | 取反 | `mvn` |
| `neg rd, rs`（伪指令） | 取负 | `rsb rd, rs, #0` |
| `seqz` 等（伪指令） | 比较结果为 0/1 | `cset`（A64） |

### 比较与分支（注意：没有 cmp，没有标志位）

| 指令 | 作用 | ARM 对照 |
|---|---|---|
| `beq` / `bne` | 相等 / 不等则跳 | `cmp` + `beq`/`bne` |
| `blt` / `bge` | 有符号小于 / 大于等于则跳 | `cmp` + `blt`/`bge` |
| `bltu` / `bgeu` | 无符号版本 | `cmp` + `blo`/`bhs` |

ARM 的 `cmp r0, #5` + `beq`，RISC-V 写成 `li t0, 5` + `beq a0, t0, label`——比较对象直接进分支指令。

### 跳转与调用

| 指令 | 作用 | ARM 对照 |
|---|---|---|
| `jal rd, offset` | 跳转并把下一条地址存进 rd（省略 rd 默认 ra） | `bl` |
| `jalr rd, imm(rs1)` | 寄存器间接跳转，rd 存返回地址 | `blx` |
| `ret`（伪指令） | 返回：`jalr x0, 0(ra)` | `bx lr` |
| `j label` / `jr rs1`（伪指令） | 无条件跳转（不存返回地址） | `b` / `bx` |
| `call func`（伪指令） | 远距离调用（auipc+jalr） | `bl` |
| `ebreak` | 调试断点 | `bkpt` |

函数指针跳转（我们的 bootloader 干的事）：`jalr x0, 0(目标寄存器)`——x0 当目标 = 不保存返回地址，就是「跳过去不回来」。

### CSR（控制状态寄存器，对照 MRS/MSR）

| 指令 | 作用 | ARM 对照 |
|---|---|---|
| `csrr rd, csr` | 读 CSR | `mrs` |
| `csrw csr, rs1` | 写 CSR | `msr` |
| `csrrw` / `csrrs` / `csrrc` | 交换 / 置位 / 清位 | `msr`（无原子置位） |

常用 CSR：`mstatus`（机器模式状态，bit3 = MIE 全局中断使能）、`mtvec`（异常入口地址）、`mcause` / `mepc` / `mtval`（异常三件套，见调试速查）、`mhartid`（核编号）、`mie` / `mip`（中断使能/挂起）。

## 3. 具体例子（全部来自本项目 + 随手编译）

指令表是字典，这一节是用法。每个例子都标了来源，可以对着源码和反汇编来回看。

### 3.1 一个完整的函数：main_c（栈帧 + 调用 + 死循环）

来源：`fake-image/main.c`（链接在 0x11000000 的裸机假镜像）。这是真实反汇编：

```asm
11000062 <main_c>:
	addi	sp,sp,-16      # 开 16 字节栈帧（sp 往下挪）
	sw	s0,8(sp)       # 保存调用者保存寄存器 s0（函数会调用别人，s0 不能被弄丢）
	sw	ra,12(sp)      # 保存返回地址 ra（等价 ARM push {lr}）
	sw	s1,4(sp)       # 保存 s1
	mv	s0,a0          # 参数1（hartid）挪进 s0，腾出 a0 给调用用
	mv	s1,a1          # 参数2（dtb）挪进 s1
	addi	a0,a5,204      # a0 = 字符串地址（"running from PSRAM"）
	jal	11000008 <uart_puts>  # 调用，返回地址自动进 ra
	...
	mv	a0,s0          # 把刚才存的 hartid 拿回来
	jal	1100002c <uart_hex>   # 再调用
	...
110000c8:	j	110000c8     # 死循环：等价 while(1)
```

看点：参数进 a0/a1；函数要调用别人，先把 ra 和调用者保存寄存器压栈（ARM 的 push {lr}）；这个函数永不返回，所以编译器连「恢复寄存器 + ret」的收尾都省了。

### 3.2 循环 + 数组访问：sum_array（编译器怎么写循环）

随手编译的 C（`-O2`，就是我们在 pico-sdk 里用的优化等级）：

```c
int sum_array(int *a, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}
```

```asm
sum_array:
	ble	a1,zero,退出       # if (n <= 0) 直接返回 0 —— 无标志位，直接比较
	slli	a1,a1,2           # n * 4（int 是 4 字节）
	mv	a5,a0              # p = a
	add	a3,a0,a1          # end = a + n*4
	li	a0,0              # s = 0
循环:
	lw	a4,0(a5)          # tmp = *p          ← 唯一的访存形式：基址+0 偏移
	addi	a5,a5,4           # p++（指针步进）
	add	a0,a0,a4          # s += tmp
	bne	a5,a3,循环        # while (p != end)
	ret
```

看点：编译器把 `i < n` 优化成了指针比较（`p != end`），循环体里只有 lw / addi / add / bne 四条指令。ARM 同款循环至少要多一条 `cmp`。

### 3.3 字符串打印：uart_puts（外设轮询）

来源：`fake-image/main.c`。逐字符发送，先等 UART 发送 FIFO 空再写：

```asm
11000008 <uart_puts>:
	lbu	a3,0(a0)          # c = *s（零扩展读字节）
	beqz	a3,结束           # if (c == 0) 字符串到头了
	lui	a4,0x40070        # a4 = UART 基址高 20 位
	addi	a4,a4,24          # a4 = &UART_FR（0x40070018，状态寄存器）
	lw	a5,0(a4)          # 读状态
	andi	a5,a5,32          # 只留 bit5（TX FIFO full）
	bnez	a5,等FIFO空       # 满了就继续等
	sw	a3,0(a2)          # 写 UARTDR（0x40070000），发送这个字符
	...（读下一个字符，回到循环头）
	ret
```

看点：外设寄存器就是普通地址，`lui + addi` 拼出地址、`lw/sw` 读写；「测某一位」用 `andi` + `bnez`，ARM 里则是 `tst` + `bne`。

### 3.4 查表 + 位移：uart_hex（把数字转成十六进制字符）

```asm
	srl	a5,a0,a3          # v >> i（右移，i 从 28 开始）
	andi	a5,a5,15          # & 0xf，取出 4 位
	add	a5,a5,a1          # a1 = "0123456789abcdef" 表地址，加下标
	lbu	a2,0(a5)          # 取字符
	...（等 FIFO，发送）
	addi	a3,a3,-4          # i -= 4
	bne	a3,a6,循环        # while (i != -4)，8 位都发完
```

看点：查表 = 基址 + 下标相加再 `lbu`。`a1` 是函数入口处 `lui + addi` 拼出来的表地址。

### 3.5 异常处理：csrr 三件套 + 清中断

来源：`tests/psram-test/main.c` 的异常报告器、`bootloader/main.c` 的跳转前清理：

```asm
csrr	a0, 0x342    # 读 mcause（异常类型）
csrr	a1, 0x341    # 读 mepc（出事指令地址）
csrr	a2, 0x343    # 读 mtval（Hazard3 恒 0）

csrci	mstatus, 0x8 # 清 mstatus 的 bit3（MIE），关全局中断再跳转
```

### 3.6 函数指针跳转：bootloader 怎么跳过去

来源：`bootloader/main.c` 的 `((image_entry_t)PSRAM_BASE)(0, NULL)`，编译器最终会生成类似：

```asm
li	a0, 0          # 参数1：hartid
li	a1, 0          # 参数2：DTB（S1 没有，传 NULL）
lui	t0, 0x11000    # t0 = 入口地址 0x11000000
jalr	x0, 0(t0)      # 跳过去不回来（x0 丢弃返回地址）← 这就是 ret 的反向用法
```

### 3.7 从 C 看汇编（自学工作流）

这是最快的学习方式：写 C，让编译器翻译，看它怎么选指令。

```bash
# 写个 demo.c，然后：
/home/developer/toolchain/bin/riscv32-unknown-elf-gcc \
    -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
    -O2 -S -o - demo.c        # 只看汇编，不链接

# 或者编译成目标文件再看最终二进制：
/home/developer/toolchain/bin/riscv32-unknown-elf-gcc ... -c -o demo.o demo.c
/home/developer/toolchain/bin/riscv32-unknown-elf-objdump -d demo.o
```

建议对照法：同一个函数分别用 `-O0`（啰嗦、一条 C 对应好几条汇编）和 `-O2`（精简、编译器花样多）各看一遍；再删一行 C，看汇编少了什么——改动前后的差异就是那块认知。

### 3.8 ARM 对照：同一个 sum 函数

RISC-V（见 3.2）vs ARM（示意）：

```asm
@ ARM 版本（示意）
sum_array:
	movs	r2, #0          @ s = 0
	lsls	r3, r1, #2      @ n * 4
	add	r3, r0, r3      @ end
	b	.check
.loop:
	ldr	r4, [r0], #4    @ tmp = *p++（后变址！RISC-V 没有）
	add	r2, r2, r4
.check:
	cmp	r0, r3          @ 先比较
	bne	.loop           @ 再跳
	mov	r0, r2
	bx	lr
```

差异点：ARM 的 `ldr [r0], #4` 后变址（读+改地址一步），RISC-V 要 `lw` + `addi` 两步；ARM 的 `cmp` + `bne`，RISC-V 一条 `bne` 直接比寄存器。

## 4. 自学工作流：写 C，看汇编

见 3.7。核心一句话：**让编译器当老师**——你写 C，它翻译，你读。遇到不懂的指令，改 C 重新生成看差异，比硬背指令表快得多。

## 5. 压缩指令（C 扩展，16 位）

反汇编里 `c.` 开头的就是 16 位压缩指令（`c.addi`、`c.mv`、`c.sw`、`c.j`、`c.li`、`c.lwsp`、`c.swsp`……）。它们和 32 位版本功能相同，只是寄存器范围受限（比如 `c.sw` 的基址只能 x8-x15）。两条规则：

- 16 位指令地址必须 2 字节对齐（Hazard3 上「指令取指对齐异常不会发生」，因为 C 扩展开着）；
- 看反汇编时 `c.` 前缀 = 这条只占 2 字节，地址每次 +2，别按 4 字节数。

我们 fake-image 的 `_start` 就是个例子（真实反汇编）：

```asm
11000000 <_start>:
11000000:	117ff137    lui   sp,0x117ff      # sp = 0x117ff000（摆栈）
11000004:	28b9        jal   11000062 <main_c> # 调用主函数（2 字节压缩）
11000006:	a001        j     11000006        # 死循环（2 字节）
```

## 6. 从 ARM 思维翻译的四个例子

| 想做的事 | ARM | RISC-V |
|---|---|---|
| 相等则跳 | `cmp r0, r1` → `beq label` | `beq a0, a1, label` |
| 加载大常量 | `ldr r0, =0x12345678`（字面量池） | `li a0, 0x12345678` |
| 读当前地址 | `adr r0, label` | `la a0, label`（auipc+addi） |
| 函数返回 | `bx lr` | `ret` |

## 7. 读反汇编的实用提示

- objdump 每行格式：`地址 机器码   指令 操作数`，机器码字节序是小端（`87ae` 在内存里是 `ae 87`，以 objdump 反汇编结果为准，别手算）。
- `lui` + `addi` 连在一起看 = 大概率是某个 `li` / 加载地址。
- 看到 `c.` 前缀 = 2 字节；`jal`/`call` 后面跟着 `ret` 的成对出现 = 函数调用骨架。
- 怀疑某条指令不认识 → 拿汇编器「对答案」（见 `notes/RISC-V调试与反汇编速查.md` 第 2.5 节）。

## 8. 本工程里你会反复看到的模式

```asm
# 启动协议（bootloader 跳转假镜像/内核前摆好的环境）
a0 = hartid        # 哪个核在跑
a1 = DTB 地址      # 设备树物理地址（S1 假镜像传 NULL）
sp  = 已初始化的栈
# 跳转 = jalr x0, 0(入口地址)
```

```asm
# 异常处理里读三件套（tests/psram-test 的异常报告器）
csrr a0, 0x342   # mcause
csrr a1, 0x341   # mepc
csrr a2, 0x343   # mtval
```

需要展开哪一块（比如 Zb* 位操作扩展、S 模式/内核视角的汇编、链接脚本怎么看）随时说。
