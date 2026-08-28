# 进程创建：fork 与 vfork 详解（NOMMU 视角）

> rp2350-linux 移植笔记 · 为什么 shell 要"先造子进程再 exec"、fork 和 vfork 到底差在哪、NOMMU 上为什么用 vfork。S4-01 实做（2026-08-28），源码基于 linux-7.2。

## 一、为什么 shell 不能自己 exec

`execve()` 会**替换当前进程的镜像**：代码、数据、栈全部换成新程序，PID 不变。shell 是 PID 1——如果它自己 exec `/bin/hello`，hello 打印完 `_exit(0)` 时退出的就是 PID 1，内核立刻 `Kernel panic - not syncing: Attempted to kill init!`。

所以"跑一个外部程序"必须是三步：

1. **造子进程**（clone/fork/vfork）——进程数变 2；
2. 子进程 execve 新程序——子进程的镜像被替换，父进程原样不动；
3. 父进程 wait4 等子进程结束并回收。

## 二、经典 fork：复制 + COW

MMU 系统上 `fork()` 的效果是"复制一份父进程"，但几乎不花钱——因为页表**共享**，只在有人写的时候才复制那一页（Copy-On-Write，写时复制）。父进程和子进程最初看到同一份内存，各自写各自的不互相干扰。之后子进程 exec，把自己的地址空间整个换成新程序。

## 三、NOMMU 上 fork 为什么重

没有 MMU = 没有页表 = 没有 COW。NOMMU 内核的 `fork()` 必须**把父进程的地址空间全量拷贝**一份给子进程（内存多大拷多大）。对小程序无所谓，但对大进程、频繁 fork（shell 每敲一条命令 fork 一次）就是灾难。

## 四、vfork：不复制，借用

`vfork()` 的思路：既然子进程马上要 exec（exec 后有自己的新地址空间，旧空间白拷），那就**不拷**——

- `CLONE_VM`：子进程**借用**父进程的地址空间（同一份内存、同一个栈）；
- `CLONE_VFORK`：父进程**阻塞**，直到子进程 exec 或 exit（内核里是一个 completion 等待）。

子进程 exec 成功后，内核给它分配全新的地址空间（bFLT 加载），借用的旧空间自然交还；父进程被唤醒继续跑。**uClinux（NOMMU Linux）传统就是 vfork 跑 shell。**

## 五、系统调用层面：没有 fork/vfork 号

asm-generic 系统调用表里**只有 `clone`(220)**，没有 fork/vfork 号。libc 的 `fork()`/`vfork()` 都是 `clone` 的包装：fork ≈ `clone(SIGCHLD, ...)`，vfork ≈ `clone(CLONE_VM|CLONE_VFORK|SIGCHLD, ...)`。我们无 libc，直接调 clone。

## 六、S4-01 的实现

```c
pid = clone(CLONE_VM | CLONE_VFORK | SIGCHLD, 0, 0, 0, 0);   /* vfork 语义 */
if (pid == 0) {
    execve("/bin/hello", argv, envp);   /* 子进程换镜像；成功就不会回来 */
    write(1, "exec failed\n", ...);     /* exec 失败才到这 */
    _exit(127);                          /* 失败必须 _exit，不能 return */
}
if (pid > 0)
    wait4(pid, NULL, 0, NULL);           /* 父进程回收 */
```

## 七、vfork 的坑（必须记住）

- **exec 之前子进程和父进程共用同一块栈**：子进程不能 return（会破坏父进程的栈帧），必须立即 exec 或 `_exit`；
- 未 exec 前子进程改任何内存都会改到父进程的——所以别在子进程里做"先准备再 exec"的复杂逻辑；
- argv/envp 必须在**父进程的栈上现拼**（`argv[0] = path; argv[1] = 0;`）：如果写成静态指针数组 `static const char *argv[] = {...}`，数组里存的是指针常量，会产生**数据重定位**（R_RISCV_32），我们的 pack-bflt.sh 会直接拒绝（bFLT 无重定位）。

## 八、对比表

| | fork | vfork |
|---|---|---|
| 内存 | 复制（MMU 下 COW，NOMMU 下全量拷） | 借用父地址空间（CLONE_VM） |
| 父进程 | 不阻塞（继续跑） | 阻塞直到子 exec/exit（CLONE_VFORK） |
| 子进程约束 | 独立，随便用 | exec 前不能 return、不能乱改父内存 |
| 适用 | MMU 通用 | NOMMU shell（uClinux 传统） |
| 系统调用 | clone(SIGCHLD) | clone(CLONE_VM\|CLONE_VFORK\|SIGCHLD) |
