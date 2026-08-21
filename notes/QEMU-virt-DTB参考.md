# QEMU virt DTB 参考

> S2 用到的 QEMU virt 机器设备树。完整反编译在同目录 `QEMU-virt-DTB.dts`。

## DTB 从哪来

- QEMU 启动时**动态生成**，不在磁盘上。导出：

```bash
qemu-system-riscv32 -M virt -machine dumpdtb=/tmp/virt.dtb
dtc -I dtb -O dts /tmp/virt.dtb
```

- 传给内核的方式：启动时 DTB 地址放在 `a1` 寄存器（RISC-V 启动协议）。OpenSBI 场景下日志里 `Domain0 Next Arg1: 0x87e00000` 就是它在内存里的位置（128MB RAM 顶端附近）。

## 关键节点与启动日志的对应

| DTB 节点 | 地址 | 启动日志里的行 |
|---|---|---|
| `memory@80000000` | 128MB | `Memory: 126832K/131072K available` |
| `serial@10000000`（ns16550a） | 0x10000000 | `10000000.serial: ttyS0 at MMIO 0x10000000 ... 16550A` |
| `clint@2000000` | 0x2000000 | `clint: clint@2000000: timer running at 10000000 Hz` |
| `plic@c000000` | 0xc000000 | `riscv-plic: plic@c000000: mapped 96 interrupts` |
| `virtio_mmio@10001000`…`10008000` ×8 | — | `root=/dev/vda` 指的就是 virtio 磁盘（没接盘所以 panic） |
| `chosen/stdout-path` | — | earlycon 用它选串口 |

## 对 S3 的意义

真板上没有 QEMU 自动生成的 DTB——我们要**自己写一份**给 `rp2350a_minimal`：结构照这个形状（memory / cpus / soc / chosen），但节点换成 RP2350 的（memory@11000000 的 PSRAM、serial@40070000 的 PL011、SIO mtime、XH3IRQ 中断控制器）。
