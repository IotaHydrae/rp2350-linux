/*
 * S3-05 initramfs /init —— 简单 shell（部件 I+T）
 *
 * 行为：banner → 挂 devtmpfs → open /dev/ttyAMA0 → raw 模式 → "# " 提示符，
 * 字符回显，回车解析，只支持 hello → "Hello, world!"。PID 1 不能退出。
 *
 * 为什么挂 devtmpfs：initramfs 直接当根时 prepare_namespace 被跳过，
 * devtmpfs 不会自动挂，/dev/ttyAMA0 不存在。
 * 为什么 raw 模式：关掉 ldisc 的 ECHO/ICANON/ISIG，避免双回显和 Ctrl-C
 * 给 PID 1 发信号（默认动作是终止 → panic）。
 *
 * 无 libc：NOMMU 内核只有 FLAT 格式（BINFMT_ELF 依赖 MMU），工具链没有
 * elf2flt，bFLT 由 scripts/pack-bflt.sh 手搓；系统调用用 ecall 内联汇编
 * （用户态 U-mode → 内核 M-mode）。
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

static inline long do_ioctl(int fd, ul req, void *arg)
{
	return do_syscall6(29, fd, (long)req, (long)arg, 0, 0, 0);
}

static inline long do_openat(const char *path, int flags)
{
	return do_syscall6(56, -100, (long)path, (long)flags, 0, 0, 0);
}

static inline long do_mount(const char *src, const char *tgt, const char *type)
{
	return do_syscall6(40, (long)src, (long)tgt, (long)type, 0, 0, 0);
}

/* asm-generic termios：riscv32 无填充，36 字节 */
#define TCGETS 0x5401
#define TCSETS 0x5402
#define ISIG   0000001
#define ICANON 0000002
#define ECHO   0000010
#define VMIN   6
#define VTIME  5

struct termios {
	unsigned int c_iflag;
	unsigned int c_oflag;
	unsigned int c_cflag;
	unsigned int c_lflag;
	unsigned char c_line;
	unsigned char c_cc[19];
};

static const char banner[] = "S3-05 initramfs OK\n";
static const char prompt[] = "# ";
static const char hello_out[] = "Hello, world!\n";
static const char unknown[] = "unknown command\n";
static const char open_fail[] = "open tty failed\n";
static const char devtmpfs[] = "devtmpfs";
static const char dev_dir[] = "/dev";
static const char tty_path[] = "/dev/ttyAMA0";

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

void _start(void)
{
	char c;
	int fd;

	do_write(1, banner, sizeof(banner) - 1);

	/* prepare_namespace 被跳过 → devtmpfs 没挂，先挂上让 /dev/ttyAMA0 出现 */
	do_mount(devtmpfs, dev_dir, devtmpfs);
	fd = do_openat(tty_path, 2);	/* O_RDWR */
	if (fd < 0) {
		do_write(1, open_fail, sizeof(open_fail) - 1);
		for (;;) {
			__asm__ __volatile__("" ::: "memory");
		}
	}
	setup_raw(fd);

	do_write(fd, prompt, sizeof(prompt) - 1);
	line_len = 0;

	for (;;) {
		if (do_read(fd, &c, 1) != 1)
			continue;
		if (c == '\r' || c == '\n') {
			do_write(fd, "\n", 1);
			if (is_hello())
				do_write(fd, hello_out, sizeof(hello_out) - 1);
			else if (line_len != 0)
				do_write(fd, unknown, sizeof(unknown) - 1);
			line_len = 0;
			do_write(fd, prompt, sizeof(prompt) - 1);
		} else if (c == 127 || c == 8) {
			if (line_len > 0) {
				line_len--;
				do_write(fd, "\b \b", 3);
			}
		} else if (line_len < (int)sizeof(line) - 1) {
			line[line_len++] = c;
			do_write(fd, &c, 1);
		}
	}
}
