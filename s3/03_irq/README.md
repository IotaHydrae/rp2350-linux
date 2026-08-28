# S3-03 · Xh3irq 外设中断：中断链验收

> RP2350 Linux 移植 · 工程 03：写 Hazard3 自定义中断控制器（Xh3irq）的 Linux 驱动，把 52 条系统中断线接进内核，验收"内核能响应外设中断"。

## 这个工程验证什么

S3-02 建好了中断基础设施的一半：`riscv,cpu-intc`（本地中断，定时器走 MTIP/cause 7）。外设中断走的是另一条路：**Xh3irq 把 52 条系统中断线聚合到 MIP.MEIP（cause 11）**。

Xh3irq 是 Hazard3 的**自定义**中断控制器，不是标准 PLIC，Linux 没有现成驱动。它不用 MMIO 寄存器，而是用一组 **CSR 数组**管理：

| CSR | 偏移 | 作用 |
|---|---|---|
| MEIEA | 0xbe0 | 中断使能数组（mask/unmask） |
| MEIPA | 0xbe1 | 中断挂起数组（只读） |
| MEIFA | 0xbe2 | 中断强制数组（软件触发） |
| MEIPRA | 0xbe3 | 优先级数组（4 位/线，16 级） |
| MEINEXT | 0xbe4 | 下一个要处理的中断（号 << 2），MSB=无 |
| MEICONTEXT | 0xbe5 | 抢占优先级上下文 |

数组 CSR 的玩法：写入值低 5 位选 16 位窗口（irq/16），高 16 位是数据（bit = irq%16）。分发循环核心：**读 MEINEXT（带 UPDATE 同指令）取最高优先级中断号 → generic_handle_domain_irq 分发 → 再读，读到 MSB 置位为止**。

本工程驱动（`drivers/irqchip/irq-rp2350-xh3irq.c`）：
- irq domain（52 线 linear）+ chip（mask/unmask 操作 MEIEA）；
- chained handler（挂在父中断 cause 11 上）循环读 MEINEXT 分发；
- 启动时清空 MEIEA（复位有幽灵位）+ 无 handler 的 IRQ 直接 mask（防电平风暴）；
- **全同优先级**（16 级抢占留作后续）。

## 目录内容

- `bootloader/`、`dts/`、`partition_table.json` — 照 02 模式；DTB 新增 `xh3irq` 节点；serial 用 `arm,sbsa-uart` + `interrupts-extended=<&xh3irq 33>` + `current-speed=<115200>`（RISC-V 无 AMBA 总线，`arm,pl011` 的 amba 驱动 probe 不到；SBSA 是 platform 驱动，零内核 serial 改动）
- `kernel-Image` — 新内核（`irq-rp2350-xh3irq` 驱动），构建自 `/home/developer/linux-7.2`，`O=build-rv32-03`
- `rp2350_minimal_defconfig` — 完整 defconfig：02 基础上加 `CONFIG_RP2350_XH3IRQ=y`

## 如何复现

### 构建

```sh
make all                        # bootloader（不要 sudo）
make build/s3/03_irq/rp2350a-minimal.dtb
make kernel-s3-03               # 配置 → 编译 → 拷贝
```

### 烧录（BOOTSEL 模式）

```sh
make flash-s3-03-bootloader
# 拔线 → 按住 BOOTSEL 重新插线
make flash-s3-03-kernel
make flash-s3-03-dtb
```

### 运行观察（UART0，GP16/17，115200）

预期日志：

1. `interrupt-controller: 52 external interrupts mapped`（xh3irq 驱动注册）
2. `ttyAMA0 at MMIO 0x40070000 (irq = 33, base_baud = 0) is a SBSA`（sbsa-uart probe 成功，中断号 33 解析正确）
3. `printk: console [ttyAMA0] enabled` + `legacy bootconsole [pl11] disabled` 后日志**继续从 ttyAMA0 出**（真 console 接管，S3-04 核心现象提前打通）
4. 无 `masking unhandled irq` 风暴（MEIEA 已清零）

### 验收：force 触发中断链

无 shell 阶段无法 open `/dev/ttyAMA0`，PL011 RX 中断不会使能（tty open 依赖）。验收用 **MEIFA force**（软件强制 pending）触发 IRQ 33，串口直接看到测试 handler 输出的 `!`（TEMP 测试代码已删，验收现象记录在实验日志）。

## 验收记录（2026-08-28 ✅）

完整调试过程见 `notes/实验日志/2026-08-28_S3-03外设中断验收.md`。最终现象：force 触发 IRQ 33 → MEINEXT 读出 33 → MEIP → cpu-intc → chained handler → generic_handle_domain_irq → handler 写 `!`，串口行首出现 `!`。

### 施工中撞过的墙（速查）

1. **IRQ 14（USBCTRL）中断风暴**：MEIEA 复位后不是全 0（幽灵位）+ USBCTRL 源复位后一直 assert → MEINEXT 无限返回 14。修复：驱动 init 清空 MEIEA + chained handler 对无 handler 的 IRQ 直接 mask。
2. **RISC-V 上 PL011 不 probe**：`arm,pl011` 是 amba 驱动，RISC-V 无 AMBA 总线 → 改 `arm,sbsa-uart`（platform 驱动）。
3. **UART RX 中断不触发**：PL011 RX 中断要 tty open 才使能，console 不 open tty → 验收改用 MEIFA force。
4. **分发调用被误删**：chained handler 里 `generic_handle_domain_irq()` 在补丁迭代中丢失，导致"只查不办"（handler 永不执行）——handler 计数器为 0 时先查分发调用是否存在。

## 已知边界

- **全同优先级**：MEIPRA 未配置（默认全 0），无中断嵌套；16 级抢占 + MEICONTEXT 保存恢复留作后续。
- **console 自动接管**：sbsa 驱动注册 console 后 printk 自动切换，bootargs 无需 console= 参数；S3-04 收尾时恢复 `CONFIG_VT` 等。
- Xh3irq 的 `irq_eoi` 语义由 chained handler 的 MEINEXT 读取承担，chip 未单独实现 eoi。
- 真实 UART RX 中断需要 tty open（S6 有 shell 后自然可用）；S3-03 用 MEIFA force 验证的是中断链本身。
