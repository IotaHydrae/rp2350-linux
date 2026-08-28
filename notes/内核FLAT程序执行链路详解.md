# 内核 FLAT 程序执行链路详解（从 exec 到 bFLT 跑起来）

> rp2350-linux 移植笔记 · 面向"用户态程序（我们的 /init）是怎么被内核加载执行"的完整链路：exec 系统调用 → 文件打开与权限检查 → binfmt 分发 → binfmt_flat 加载 → 跳进用户态。源码基于 linux-7.2，核对于 S3-05（2026-08-28）。配套：`notes/bFLT格式与手搓打包详解.md`（文件格式与打包）。

## 一句话

`kernel_execve("/init")` 打开文件 → 依次试内核注册的二进制格式（NOMMU 下只有 FLAT）→ `load_flat_binary()` 按 bFLT 头把 text/data/bss/栈布局进内存 → `start_thread()` 设好 PC（入口）和 SP（栈顶）→ 返回用户态执行。**ETXTBSY 卡点发生在最前面——文件打开阶段，还没到格式加载。**

## 调用链（按实际执行顺序）

```text
kernel_init()                      init/main.c —— PID 1 启动后执行 init
  └─ run_init_process("/init")     按 ramdisk_execute_command → execute_command → 默认路径依次试
       └─ kernel_execve()
            └─ do_execveat_common(AT_FDCWD, "/init", ...)   fs/exec.c
                 └─ bprm_execve()
                      ├─ do_open_execat()     打开文件 + 权限检查（★ ETXTBSY 在这里）
                      ├─ exec_binprm()
                      │    └─ search_binary_handler()  遍历 binfmt 格式
                      │         └─ load_flat_binary()  binfmt_flat 的加载器
                      │              ├─ load_flat_file()  按 bFLT 头布局内存
                      │              └─ start_thread()    设 PC/SP，交棒用户态
```

## 第一关：do_open_execat（★ 当前卡点 ETXTBSY 在这）

`fs/exec.c` 的 `do_open_execat()`：

1. `do_file_open()` 打开 `/init`（O_LARGEFILE | O_RDONLY | __FMODE_EXEC）；
2. 检查 `path_noexec()`（挂载点 noexec → EACCES）；
3. `exe_file_deny_write_access(file)`：

```c
static inline int deny_write_access(struct file *file)
{
	struct inode *inode = file_inode(file);
	return atomic_dec_unless_positive(&inode->i_writecount) ? 0 : -ETXTBSY;
}
```

`i_writecount > 0`（还有谁把这个文件以写方式开着）→ **-ETXTBSY**。这是 Linux 的经典保护：不允许执行"正在被写"的文件。

**当前调试**（S3-05，2026-08-28）：真板报 `Failed to execute /init (error -26)`。已加临时打印 `[dbg] exec %s -> ETXTBSY, i_writecount=%d`，等真板数据确认是哪个环节把 /init 的写引用留住了（怀疑 initramfs 解包器的 fput 延迟路径）。

## 第二关：search_binary_handler（格式分发）

`fs/exec.c`：遍历全局 `formats` 链表，逐个调用 `fmt->load_binary(bprm)`；返回 `-ENOEXEC` 就试下一个，其它错误直接返回。

- ELF 格式：`CONFIG_BINFMT_ELF` **依赖 MMU**，NOMMU 内核没有注册；
- FLAT 格式：`flat_format = { .load_binary = load_flat_binary }`，`CONFIG_BINFMT_FLAT=y` 时注册；
- 脚本格式：`BINFMT_SCRIPT`（#!/ 解释器行）也在列。

所以 riscv32 NOMMU 上 `/init` 只能是 bFLT，格式不对就是 `-ENOEXEC` → panic "No working init found"。

## 第三关：load_flat_binary（binfmt_flat.c）

### 1. 栈尺寸预算

```c
stack_len += PAGE_SIZE * MAX_ARG_PAGES - bprm->p;  /* 参数字符串 */
stack_len += (argc + 1) * sizeof(char *);          /* argv 数组 */
stack_len += (envc + 1) * sizeof(char *);          /* envp 数组 */
stack_len = ALIGN(stack_len, FLAT_STACK_ALIGN);
```

栈 = 加载器给的 `stack_size`（bFLT 头）+ 参数区。防用户传超长参数打爆栈。

### 2. load_flat_file：按头布局内存

（RAM 模式，NOMMU 路径；细节与头字段对应见 bFLT 文档）

- 校验：magic `bFLT`、rev==4（`FLAT_VERSION`）、各长度 < 28 位、ZFLAT 标志检查；
- `text_len = data_start`（**含 64 字节头**）、`data_len = data_end - data_start`、`bss_len = bss_end - data_end`、`stack_len = stack_size`；
- `begin_new_exec(bprm)`：换掉旧 mm、清进程状态（binfmt handler 回调用，见 fs/exec.c 注释）；
- 分配 `text+data+bss+stack` 连续内存（NOMMU 下 `vm_mmap` 一整块）：
  - 文件 `[0, data_start)` → textpos（头也被拷进去，无害）；
  - 文件 `[data_start, data_end)` → datapos = `ALIGN(textpos + data_start, 0x20)`；
  - bss 区清零（文件末尾的 `clear_user`）；
- 设置 mm 边界：`start_code/end_code = textpos+32 .. textpos+data_start`，`start_data/end_data = datapos .. datapos+data_len`，`start_brk = datapos+data_len+bss_len`；
- 重定位（reloc_count > 0 时）：`calc_reloc()` 逐个把"绝对地址槽"加上基址；GOTPIC 模式先处理数据段开头的 GOT 表（-1 结尾）。**我们的 /init 无重定位（reloc_count=0），这段直接跳过**；
- `entry = textpos + (hdr->entry & 0xffffff)`——entry 是文件偏移，textpos 对应文件 0 偏移；
- `start_stack = (end_brk + stack_len) & ~3`，然后 `transfer_args_to_stack()` + `create_flat_tables()` 把 argc/argv/envp 摆到用户栈上。

### 3. start_thread：交棒用户态

```c
start_addr = libinfo.lib_list[0].entry;   /* 主程序入口 */
start_thread(regs, start_addr, current->mm->start_stack);
```

`start_thread` 把 `regs->epc = 入口`、`regs->sp = 栈顶`，返回路径（`ret_from_fork` / `ret_from_exception`）用 **mret** 回到 U-mode（M-mode 内核下用户态跑 U-mode，`mstatus.MPP=0`），第一条指令就是 bFLT 的 entry。此后用户程序用 `ecall` 发系统调用（a7=号），陷入 M-mode 内核处理。

## 我们手搓 bFLT 与加载器的对应关系

| 打包时写的字段 | 加载器怎么用 | 我们的值 |
|---|---|---|
| entry = 64 | `textpos + entry` = 第一条指令 | `_start` 在 .text 开头，text 从文件偏移 64 开始 |
| data_start = 64+text | `text_len`（含头）、datapos 起点 | 96 |
| data_end | data_len | 116 |
| bss_end | bss_len（清零） | = data_end（无 bss） |
| stack_size | 栈分配 | 0x10000 |
| reloc_count = 0 | 跳过重定位 | 0 |
| flags = FLAT_FLAG_RAM | 走 RAM 加载路径 | 1 |

## 与当前调试的关系

- ETXTBSY 发生在第一关（文件打开），**还没进 binfmt 加载**——所以 bFLT 格式没问题不代表能执行；
- `Run /init as init process` 出现 = 文件存在且可执行（`init_eaccess` 过了），卡在"执行时发现还有人握着写引用"；
- 等 `[dbg]` 打印的 `i_writecount` 值定位是谁没放手（怀疑 initramfs 解包器 fput 延迟路径，见 `notes/内核initramfs与rootfs启动链路详解.md` 第 3 节）。
