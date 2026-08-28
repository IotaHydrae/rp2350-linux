/*
 * S4-03 rootfs /init —— 根切 ext2 后的根里 shell
 *
 * 行为：banner → open /dev/ttyAMA0 → dup3 安到 0/1/2 → raw 模式 → "# " 提示符，
 * 字符回显，回车解析；hello → vfork + execve("/bin/hello")，父进程 waitid。
 *
 * 和 S4-01/02 的差别：
 *  - 不再自己挂 devtmpfs：legacy initrd 走 prepare_namespace，内核 mount_root 后
 *    自动 devtmpfs_mount，/dev/ttyAMA0 已经存在。
 *  - 自己把 tty dup3 成 0/1/2：初始 rootfs 是空 ramfs，没有 /dev/console，
 *    console_on_rootfs() 打不开，内核没给我们建好 stdin/stdout/stderr；
 *    子进程 exec 后继承的 fd 1 也必须指向 tty，hello 的 printf 才看得见。
 *
 * 无 libc：NOMMU 内核只有 FLAT 格式（BINFMT_ELF 依赖 MMU），工具链没有
 * elf2flt，bFLT 由 scripts/pack-bflt.sh 手搓；系统调用用 ecall 内联汇编。
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

static inline long do_read(int fd, char *buf, ul len)
{
	return do_syscall6(63, fd, (long)buf, (long)len, 0, 0, 0);
}

static inline long do_close(int fd)
{
	return do_syscall6(57, fd, 0, 0, 0, 0, 0);
}

static inline long do_ioctl(int fd, ul req, void *arg)
{
	return do_syscall6(29, fd, (long)req, (long)arg, 0, 0, 0);
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

static inline long do_clone(ul flags, ul newsp, ul ptid, ul ctid, ul tls)
{
	return do_syscall6(220, (long)flags, (long)newsp, (long)ptid, (long)ctid, (long)tls, 0);
}

static inline long do_execve(const char *path, const char **argv, const char **envp)
{
	return do_syscall6(221, (long)path, (long)argv, (long)envp, 0, 0, 0);
}

static inline long do_waitid(long pid)
{
	/* riscv32 的 asm-generic 表没有 wait4，等子进程用 waitid(95)：
	 * waitid(P_PID, pid, NULL, WEXITED, NULL)；options 必须显式含 WEXITED(4)。 */
	return do_syscall6(95, 1 /* P_PID */, pid, 0, 4 /* WEXITED */, 0, 0);
}

static inline void do_exit(int code)
{
	do_syscall6(93, code, 0, 0, 0, 0, 0);
}

/* asm-generic termios：riscv32 无填充，36 字节 */
#define TCGETS 0x5401
#define TCSETS 0x5402
#define ISIG   0000001
#define ICANON 0000002
#define ECHO   0000010
#define VMIN   6
#define VTIME  5

/* clone flags（include/uapi/linux/sched.h）：vfork = 共享 VM + 父等子 exec/exit */
#define CLONE_VM    0x00000100
#define CLONE_VFORK 0x00004000
#define SIGCHLD     0x00000011

struct termios {
	unsigned int c_iflag;
	unsigned int c_oflag;
	unsigned int c_cflag;
	unsigned int c_lflag;
	unsigned char c_line;
	unsigned char c_cc[19];
};

static const char banner[] = "S4-03 root ext2\n";
static const char prompt[] = "# ";
static const char unknown[] = "unknown command\n";
static const char exec_fail[] = "exec /bin/hello failed\n";
static const char tty_path[] = "/dev/ttyAMA0";
static const char hello_path[] = "/bin/hello";

static char line[128];
static int line_len;

static int is_hello(void)
{
	static const char h[] = "hello";
	int i;

	if (line_len != 5)
		return 0;
	for (i = 0; i < 5; i++)
		if (line[i] != h[i])
			return 0;
	return 1;
}

static void setup_raw(int fd)
{
	struct termios t;

	if (do_ioctl(fd, TCGETS, &t) != 0)
		return;
	t.c_lflag &= ~(ISIG | ICANON | ECHO);
	t.c_cc[VMIN] = 1;
	t.c_cc[VTIME] = 0;
	do_ioctl(fd, TCSETS, &t);
}

/*
 * vfork + execve：子进程借用父地址空间（CLONE_VM），父阻塞（CLONE_VFORK）
 * 直到子进程 exec/exit；子进程 exec 后拥有自己的新地址空间。
 * argv/envp 必须在栈上现拼（静态指针数组会产生数据重定位，pack-bflt.sh 会拒）。
 */
static void run_hello(void)
{
	const char *argv[2];
	const char *envp[1];
	long pid;

	argv[0] = hello_path;
	argv[1] = 0;
	envp[0] = 0;

	pid = do_clone(CLONE_VM | CLONE_VFORK | SIGCHLD, 0, 0, 0, 0);
	if (pid == 0) {
		/* 子进程：exec 成功就变成 /bin/hello；失败必须 _exit，不能 return */
		do_execve(hello_path, argv, envp);
		do_write(1, exec_fail, sizeof(exec_fail) - 1);
		do_exit(127);
	}
	if (pid > 0) {
		do_waitid(pid);
	}
}

/* .text.start 段由 init.ld 放在 .text 最前：保证 _start 在偏移 0（bFLT entry 要求） */
__attribute__((section(".text.start"))) void _start(void)
{
	char c;
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
	setup_raw(0);

	do_write(1, prompt, sizeof(prompt) - 1);
	line_len = 0;

	for (;;) {
		if (do_read(0, &c, 1) != 1)
			continue;
		if (c == '\r' || c == '\n') {
			do_write(1, "\r\n", 2);
			if (is_hello()) {
				run_hello();
			} else if (line_len > 0) {
				do_write(1, unknown, sizeof(unknown) - 1);
			}
			line_len = 0;
			do_write(1, prompt, sizeof(prompt) - 1);
		} else if (c == 127 || c == 8) {
			if (line_len > 0) {
				line_len--;
				do_write(1, "\b \b", 3);
			}
		} else if (line_len < (int)sizeof(line) - 1) {
			line[line_len++] = c;
			do_write(1, &c, 1);
		}
	}
}
