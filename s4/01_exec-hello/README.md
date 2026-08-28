# S4-01 · shell 调用外部程序：/bin/hello

> RP2350 Linux 移植 · 工程 01（S4 文件系统篇）：shell 解析 `hello` 时不再自己打印，而是**进程创建**——vfork + execve 拉起 rootfs 里的 `/bin/hello`（独立 bFLT），父 shell wait4 等它结束再回提示符。NOMMU 首次做多进程。

## 机制

shell 是 PID 1：不能自己 exec（exec 替换 PID 1 后退出即 panic），必须先造子进程。NOMMU 无 COW → fork 要全量拷贝内存；用 **vfork 语义**（`clone(CLONE_VM|CLONE_VFORK|SIGCHLD)`）：子进程借用父地址空间，父阻塞直到子进程 exec/exit；子进程 exec 后拥有自己的新地址空间。

系统调用：`clone`(220) + `execve`(221) + `wait4`(260)。argv/envp 在栈上现拼（静态指针数组会产生数据重定位，pack-bflt.sh 会拒）。

详情见 `notes/进程创建fork与vfork详解.md`。

## rootfs 内容

- `/init` — shell（`make init-s4-01`），hello 命令 → `run_hello()`
- `/bin/hello` — 外部程序（`make hello-s4-01`），write() 打印 `Hello, world!` 后 `_exit(0)`

## 如何复现

### 构建

```sh
make all                    # bootloader（不要 sudo）
make init-s4-01             # shell bFLT
make hello-s4-01            # /bin/hello bFLT
make rootfs-s4-01           # gen_init_cpio → rootfs.cpio（含 /bin/hello）
make build/s4/01_exec-hello/rp2350a-minimal.dtb
```

内核与 S4-00 相同（本关无内核改动），`kernel-Image` 为 S4-00 拷贝。

### 烧录（BOOTSEL 模式）

板子上已是 S4-00 的 bootloader/kernel/dtb 时，只需：

```sh
make flash-s4-01-rootfs
```

### 运行观察（UART0，GP16/17，115200）

预期：

1. `S4-01 shell exec /bin/hello`（新 banner）
2. `# hello` → **`Hello, world!`（由 /bin/hello 打印，不是 shell）** → `# `
3. `# abc` → `unknown command`

## 已知边界

- vfork 语义下子进程未 exec 前与父共享内存/栈，必须立即 exec 或 _exit，不能 return/改父内存。
- 无 libc：printf 用 write() 替代；hello 目前忽略 argc/argv（后续可加参数解析）。
