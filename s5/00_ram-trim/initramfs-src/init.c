/*
 * S5-00 rootfs /init —— busybox 启动器（PID 1）
 *
 * 行为：open /dev/ttyAMA0 → dup3 安到 0/1/2 → banner → 挂 ramfs 到 /tmp
 * （失败不阻塞）→ execve("/bin/sh", ["sh"], env)——/bin/sh 是 busybox 的
 * 符号链接，busybox 按 argv[0] 分发成 hush，PID 1 就变成 busybox hush。
 *
 * S5-00 起 rootfs 机制从 legacy initrd（ext2 on brd）切回 cpio initramfs：
 * 内核 CONFIG_BLOCK/EXT2/BLK_DEV_RAM 全关，bootloader 把 buildroot 出的
 * rootfs.cpio 拷到 0x11300000，populate_rootfs 解包成初始 rootfs。
 * 这里只负责把 stdio、可写 /tmp、/proc、/sys 准备好，然后把控制权交给 hush。
 *
 * 无 libc：NOMMU 内核只有 FLAT 格式，bFLT 由 scripts/pack-bflt.sh 手搓；
 * 系统调用用 ecall 内联汇编。
 */
typedef unsigned long ul;

static inline long do_syscall6(long n, long a0, long a1, long a2, long a3, long a4, long a5)
{
	register long r_a0 __asm__("a0") = a0;
	register long r_a1 __asm__("a1") = a1;
	register long r_a2 __asm__("a2") = a2;
	register long r_a3 __asm__("a3") = a3;
	register long r_a4 __asm__("a4") = a4;
	register long r_a5 __asm__("a5") = a5;
	register long r_a7 __asm__("a7") = n;

	__asm__ __volatile__("ecall\n"
		: "+r"(r_a0)
		: "r"(r_a1), "r"(r_a2), "r"(r_a3), "r"(r_a4), "r"(r_a5), "r"(r_a7)
		: "memory");

	return r_a0;
}

static inline long do_write(int fd, const char *buf, ul len)
{
	return do_syscall6(64, fd, (long)buf, (long)len, 0, 0, 0);
}

static inline long do_close(int fd)
{
	return do_syscall6(57, fd, 0, 0, 0, 0, 0);
}

static inline long do_openat(const char *path, int flags)
{
	return do_syscall6(56, -100, (long)path, (long)flags, 0, 0, 0);
}

/* asm-generic 没有 dup2（只有 dup/dup3），dup3(fd, new, 0) 等价 dup2 */
static inline long do_dup3(int oldfd, int newfd)
{
	return do_syscall6(24, oldfd, newfd, 0, 0, 0, 0);
}

static inline long do_mkdirat(const char *path, int mode)
{
	return do_syscall6(34, -100, (long)path, (long)mode, 0, 0, 0);
}

static inline long do_mount(const char *src, const char *tgt, const char *type)
{
	return do_syscall6(40, (long)src, (long)tgt, (long)type, 0, 0, 0);
}

static inline long do_execve(const char *path, const char **argv, const char **envp)
{
	return do_syscall6(221, (long)path, (long)argv, (long)envp, 0, 0, 0);
}

static const char banner[] = "S5-00 ram-trim\n";
static const char tty_path[] = "/dev/ttyAMA0";
static const char sh_path[] = "/bin/sh";

/* .text.start 段由 init.ld 放在 .text 最前：保证 _start 在偏移 0（bFLT entry 要求） */
__attribute__((section(".text.start"))) void _start(void)
{
	const char *argv[2];
	const char *envp[3];
	int fd;

	fd = do_openat(tty_path, 2);	/* O_RDWR */
	if (fd < 0) {
		/* 初始 rootfs 没有 /dev/console，内核没建 0/1/2，写哪里都白搭，只能干等 */
		for (;;) {
			__asm__ __volatile__("" ::: "memory");
		}
	}
	do_dup3(fd, 0);
	do_dup3(fd, 1);
	do_dup3(fd, 2);
	if (fd > 2)
		do_close(fd);

	do_write(1, banner, sizeof(banner) - 1);

	/* 根是 initramfs（ramfs），给 hush/applet 一个独立可写 /tmp（失败不阻塞） */
	do_mkdirat("/tmp", 01777);
	do_mount("ramfs", "/tmp", "ramfs");
	/* ps/dmesg 等 applet 读 /proc（内核 CONFIG_PROC_FS=y，失败不阻塞） */
	do_mkdirat("/proc", 0555);
	do_mount("proc", "/proc", "proc");
	/* 设备树/驱动信息在 /sys（sysfs 虚拟文件系统，失败不阻塞） */
	do_mkdirat("/sys", 0555);
	do_mount("sysfs", "/sys", "sysfs");

	/* 栈上现拼 argv/envp（静态指针数组会产生数据重定位，pack-bflt.sh 会拒） */
	argv[0] = "sh";
	argv[1] = 0;
	envp[0] = "PATH=/bin:/sbin:/usr/bin:/usr/sbin";
	envp[1] = "HOME=/";
	envp[2] = 0;

	do_execve(sh_path, argv, envp);

	/* exec 失败才到这：PID 1 不能退出，干等（真出错看内核日志的 exec 错误） */
	for (;;) {
		__asm__ __volatile__("" ::: "memory");
	}
}
