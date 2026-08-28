# S4-00 · bootloader 拷 initramfs：rootfs 独立烧录

> rp2350-linux 移植 · 这份给人看（复盘文，读=复习）；续学接管看上级文件夹 `学习地图.md`。

```mermaid
flowchart LR
    BL["bootloader（已有·改）<br/>拷 kernel + dtb + initramfs"] -->|分区 2| IR["initramfs → 固定 RAM 地址（新增·承重）"]
    DTB["DTB chosen<br/>linux,initrd-start/end（新增）"] --> K["内核（已有）<br/>reserve + populate_rootfs 解包"]
    IR --> K
    K --> I["/init shell（复用 S3-05）"]
    I -->|# hello| O["Hello, world!（验收）"]
    P["分区表 ROOTFS 分区（填充）<br/>rootfs 单独烧录"] -.-> BL
```

S3-05 把 initramfs 编进内核，改一次 rootfs 就要重编重烧整个内核。S4-00 把它拆成独立分区：bootloader 从分区 2 拷 initramfs 到固定 RAM 地址，DTB 用 `linux,initrd-start/end` 描述，内核照常解包。验收做了两步：首启四件套全通；然后**只烧分区 2**，rootfs 换成 S4-00 自有 /init（新 banner）照样生效——bootloader/内核/DTB 一个没动。

**本阶段拍过的决策**：
- 决策① initramfs RAM 地址 → **固定约定**（DTB 写死 + bootloader 拷约定地址；动态 libfdt 补丁太复杂，不做）
- 决策② 内核 baked-in initramfs → **清空**（rootfs 出错能明确判定是独立文件系统的问题；fallback 等真需要再做）
- 决策③ ROOTFS 分区大小 → **1MB**（手搓阶段够用，不够时改分区表 + DTB initrd-end + 重烧三步扩容）

> 第一个钩子：内核怎么知道 bootloader 把 initramfs 放在哪？
> <details><summary>参考答案</summary>DTB chosen 节点的 `linux,initrd-start/end`。bootloader 的 `INITRAMFS_LOAD_ADDR` 和 DTB 的属性是**双处写死同一个地址**——这是固定约定的全部。</details>

### 第一根枝：固定约定链路

布局：kernel @ 0x11000000（最多 3MB 到 0x11300000）、initramfs @ 0x11300000 ~ 0x11400000（1MB）、DTB @ 0x11700000。bootloader 拷完三份各自校验（verify mismatches=0）再跳转；内核启动时按 DTB 的 initrd 地址 **reserve 内存 → populate_rootfs 解包 → free_initrd_mem 释放**（解包即释放，所以 1MB 临时区不挤占 RAM）。

### 第二根枝：rootfs 独立

分区 2 = ROOTFS（1MB，families=absolute），rootfs.cpio 由 `gen_init_cpio` 从清单独立构建，`make flash-s4-00-rootfs` 单独烧录。内核 `CONFIG_INITRAMFS_SOURCE` 清空（无内置）——rootfs 出问题就是分区 2 的问题，不用怀疑内核里藏着另一份。

### 第三根枝：rootfs 自洽

`initramfs-src/` 从 S3-05 拷贝（同样的 bFLT shell + 链接脚本），banner 换成 `S4-00 rootfs via bootloader OK`，S4 不再跨工程引用 S3-05 的产物。

#### ⚠️ 这一段踩过的小坑
- **双处写死地址必须同步**：改 initramfs RAM 地址要同时改 bootloader `INITRAMFS_LOAD_ADDR` 和 DTB `linux,initrd-start/end`，否则 bootloader 拷 A 处、内核解 B 处。
- **内核只 reserve DTB 说的区域**：bootloader 拷的位置必须和 DTB 一致，否则真正的 rootfs 没被 reserve，可能被内核分配器踩掉（症状飘忽，不一定是立刻 panic）。
- `gen_init_cpio` 复用内核构建产物（build-rv32-05/usr/），Makefile 里 `KERNEL_SRC` 要先定义（`:=` 提前展开会得空路径）。

## 验收（2026-08-28 ✅）

首启：bootloader `partition 2 sectors [800,1055] -> flash 0x10320000, size 0x100000`、`copy initramfs ... -> PSRAM 0x11300000`、`verify: ... initramfs mismatches=0` → 内核无内置 initramfs 仍正常解包 → shell 照常。

独立烧录：只跑 `make flash-s4-00-rootfs` → 新 banner `S4-00 rootfs via bootloader OK` + shell 照常。

**自测**（盖住答案）
- Q1：固定约定由哪两处共同保证？
  <details><summary>参考答案</summary>bootloader 的 INITRAMFS_LOAD_ADDR（拷到哪）和 DTB 的 linux,initrd-start/end（内核去哪找），双处写死同一地址。</details>
- Q2：内核为什么要 reserve initrd 区域？
  <details><summary>参考答案</summary>防止页分配器把还没解包的 initramfs 内存当普通内存用掉；解包完才 free。</details>
- Q3：只烧分区 2 为什么能换 rootfs？
  <details><summary>参考答案</summary>rootfs 完全由 bootloader 从分区 2 拷入，内核/DTB 不知道 rootfs 内容，只按地址解包。</details>
- Q4：内核没有 baked-in initramfs 的好处？
  <details><summary>参考答案</summary>诊断隔离：rootfs 出错就是独立分区的问题，不存在"内核里还藏着一份"的干扰。</details>
- Q5（迁移四问）：U-Boot 把 rootfs 拷到任意地址，固定约定还成立吗？怎么改？
  <details><summary>参考答案</summary>不成立（DTB 写死的地址对不上）；要么 U-Boot 配置成拷到约定地址，要么启动前用 fdt set 动态补丁 linux,initrd-start/end；坑：内核只 reserve DTB 说的区域，地址不一致会踩内存；验：串口看解包/init/shell，负验不传 initrd 应看到 VFS panic。</details>
