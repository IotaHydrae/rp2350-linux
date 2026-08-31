# 双核方案分析：SMP 为什么不做，AMP 怎么做（S7）

> RP2350 双核（两个 Hazard3 RISC-V 核）· 结论：**SMP 不做；AMP（Linux core0 + 裸机/RTOS core1 + rpmsg 通信）可行，列为 S7 方向**（2026-08-28 用户拍板，阶段拆分待定）。本文记录结论依据与方案形状。

## 一、背景与结论

RP2350 的 RISC-V 变体有两个 **Hazard3** 核（RV32IMAC+），共享同一个物理地址空间（无 MMU）。我们的内核是 riscv32 NOMMU、M 模式、单核（SMP=n）。

两个核**同构**：都是 Hazard3，没有"大核/小核"之分。所以把 core1 当"异构核"用的说法，准确讲是 **AMP（非对称多处理）**——非对称体现在**软件分工**（core0 跑 Linux、core1 跑裸机/RTOS），不在硬件。

## 二、为什么 SMP 不可行

### 2.1 Linux SMP 机制依赖什么

主线 Linux 的 riscv SMP 不是"多跑一个核"这么简单，它依赖一套现成机制：

1. **secondary hart 启动协议**：`smp_callin`/`secondary_start_sbi` 一整套，由 SBI（或 ACLINT）把从核从低层启动状态拉进内核调度；
2. **核间中断（IPI）**：调度器、tlb shootdown 全靠 IPI，riscv 上由 SBI `send_ipi` 或 ACLINT 提供；
3. **per-CPU 上下文隔离**：每核的页表、irq 栈、percpu 变量区，靠 MMU 的地址映射实现"各核各一份、互不串扰"；
4. **内存管理假设**：`mm_struct`/页表切换/`__pa_symbol` 等全是 MMU 语义。

### 2.2 我们缺什么

- **NOMMU**：没有每核地址空间，Linux 的内存管理与 per-CPU 隔离假设全不成立。这不是"少个功能"，是整套机制的承重墙没了。
- **M 模式、无 SBI**：riscv SMP 的 secondary boot 和 IPI 标准路径都挂在 SBI/ACLINT 上；我们是 M 模式裸机内核，两者皆无。
- Kconfig 层面 riscv 的 `SMP` 选项没有显式 `depends on MMU`（只有 `NUMA` 是 `SMP && MMU`），**但实现代码全是 MMU/SBI 语义**——强行打开等于拿到一个跑不起来的配置，重写整套启动和中断分发。
- **单地址空间共享**：两个核天然共享全部内存，没有隔离，Linux 的锁/调度/内存假设进一步失效。

### 2.3 结论

收益为零、成本是重写内核启动与中断子系统 → **SMP 不做**。

## 三、为什么 AMP 可行（硬件证据，手册）

AMP 是 MCU 领域的标准形态（OpenAMP 就是为它设计的：Linux 占一个核，另一个核跑 RTOS/裸机，共享内存 + mailbox 通信）。RP2350 的硬件几乎是照着这个形态长的：

### 3.1 SIO 双邮箱 FIFO（手册 3.1.5）

SIO 里有**两个 32 位 × 4 深的 FIFO**，一个只能 core0→core1 写、另一个只能 core1→core0 写——天然的方向性消息通道，正好当 rpmsg 的"敲门/通知"机制（mailbox）。

### 3.2 32 个硬件自旋锁（手册 3.1.4）

SIO 提供 32 个硬件 spinlock，用于跨核临界区。手册明确说：**共享 SRAM 变量用 SIO spinlock 保护**，因为排他访问（LR/SC）的语义跨核不保证（这也是我们 S3 撞过的 PSRAM 原子墙的近亲——SRAM 上 LR/SC 单核可用，但双核共享要用专门的自旋锁）。

### 3.3 定时器：MTIME 共享、MTIMECMP 每核一份（手册 3.2）

- **MTIME**：单个 64 位计数器，两核共享——clocksource 天然一致，Linux 的 `get_cycles` 直接可用；
- **MTIMECMP**：**每核一份**（同地址、每核私有），各自触发本核的定时器中断——core0 的 Linux 定时器链和 core1 裸机程序的定时需求互不干扰。

### 3.4 Xh3irq 中断：路由到两核、每核视角（手册 3.8.6.1）

- "All interrupts route to both cores, and the core's internal interrupt controller selects the interrupt"——中断送两核，各核自己的 enable/force 数组决定要不要；
- **MEIEA/MEIFA 是每核副本**（我们 S3-03 驱动里读的 `MEIEA[0]`/`MEIFA[2]` 是 core0 视角，要按核访问）；
- **MEICONTEXT 每核一份优先级栈**（S3-03 的坑：非 MEIP 陷阱清 MRETEIRQ 导致栈不弹——双核下要各自保存/恢复）。

## 四、AMP 方案设计（S7，阶段拆分待定）

### 4.1 启动：bootloader 拉起 core1

core1 由 bootloader 按 **SDK multicore 协议**启动（写 magic 值到约定 SRAM 地址 + 触发唤醒，或直接用 SDK 的 `multicore_launch_core1`）——core1 程序可以是裸机循环或 FreeRTOS，链接地址要按划分好的内存地盘放。

### 4.2 通信：三层递进（建议的验收路径）

1. **最小验证**：core1 往 SIO FIFO 写一个字，Linux（core0）读出来——先证明"核间通路"通了；
2. **共享内存协议**：划一块共享 buffer + FIFO 当通知 + spinlock 保护，先手写简单的消息格式；
3. **rpmsg**：接入 Linux rpmsg 框架。两种传输形态：
   - **virtio-rpmsg（OpenAMP 标准）**：共享内存里放 vrings，SIO FIFO 当 kick/通知，core1 侧用 libmetal/virtio；
   - **自定义 rpmsg 传输**：不依赖 virtio，直接用 SIO FIFO + 共享内存实现 rpmsg 通道（内核有先例：Qualcomm SMD 就是非 virtio 的 rpmsg 传输）。

### 4.3 坑 / 边界清单

- **共享地址空间画地盘**：SRAM/PSRAM 要明确划分（Linux 用哪些、core1 用哪些、共享 buffer 放哪），避免踩脚；内存节点/保留区域要在 DTB 和 core1 链接脚本两处对齐；
- **跨核临界区用 SIO spinlock**，不要假设 LR/SC 跨核可用；
- **Xh3irq 驱动要支持按核访问** enable/force 数组（当前只用了 core0 视角）；
- **MEICONTEXT 每核保存/恢复**，core1 的异常路径同样要处理；
- **中断归属**：哪些外设中断路由给 core1（比如它私有的设备），要在驱动里按核配置；
- **Linux 不能假装 core1 不存在**：共享外设（UART/PSRAM/flash）的互斥要考虑；
- rpmsg/virtio 在 NOMMU 上可行（框架架构无关），但 virtio 的 dma/共享内存语义要按 NOMMU 核对。

## 五、与后续阶段的衔接

- **S6 DMA**：核间共享内存搬运可能是 DMA 的好应用（搬运大块数据不占 CPU），两个方向互相铺垫；
- **S8 电源管理**：双核的功耗/唤醒是 PM 的自然话题（比如 core1 空闲时停 clock/WFI），AMP 通信做完后 PM 的验收场景更真实。

## 相关事实出处

- RP2350 datasheet：3.1.4 硬件自旋锁、3.1.5 邮箱 FIFO、3.2 RISC-V 定时器（MTIME/MTIMECMP）、3.8.6.1 Xh3irq
- 内核源码：`arch/riscv/Kconfig`（SMP/NUMA）、`arch/riscv/kernel/smp*`（SBI 依赖的启动/IPI 路径）、`fs/binfmt_flat.c`（NOMMU 用户态 FLAT）
- 项目状态：`学习地图.md`（S7 行 + 关键更正）、`PLAN.md`（双核路线）
