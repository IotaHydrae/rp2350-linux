/*
 * S4-02 rootfs /init —— ext2 真实文件系统（brd RAM 块设备）
 *
 * 行为：banner → 挂 devtmpfs → open tty → 把 /rootfs.ext2 镜像拷进 /dev/ram0
 * → mount /dev/ram0 /mnt（ext2）→ 写/读一个测试文件 → 打印结果 → shell 提示符。
 *
 * 为什么用 brd + ext2：真板没有块设备硬件，PSRAM/RAM 用内核 brd 驱动模拟
 * /dev/ram0；ext2 是内核已内置的真实文件系统格式（inode/目录/位图），
 * PC 上 mkfs.ext2 做镜像。断电即失正好演示"持久化"概念。
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

static inline long do_mkdirat(const char *path, int mode)
{
	return do_syscall6(34, -100, (long)path, (long)mode, 0, 0, 0);
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

static const char banner[] = "S4-02 ext2 on brd\n";
static const char prompt[] = "# ";
static const char open_fail[] = "open tty failed\n";
static const char copy_fail[] = "copy image failed\n";
static const char mount_fail[] = "mount ext2 failed\n";
static const char test_write_fail[] = "write test failed\n";
static const char test_read_fail[] = "read test failed\n";
static const char ext2_ok[] = "ext2 OK: ";
static const char devtmpfs[] = "devtmpfs";
static const char dev_dir[] = "/dev";
static const char tty_path[] = "/dev/ttyAMA0";
static const char image_path[] = "/rootfs.ext2";
static const char ramdev[] = "/dev/ram0";
static const char mnt_dir[] = "/mnt";
static const char test_path[] = "/mnt/test.txt";
static const char test_data[] = "hello ext2\n";

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

/* 把 rootfs 里的 ext2 镜像拷进 /dev/ram0（brd 块设备） */
static int copy_image(void)
{
	char buf[512];
	int sfd = do_openat(image_path, 0);	/* O_RDONLY */
	int dfd = do_openat(ramdev, 2);		/* O_RDWR */
	long r;

	if (sfd < 0 || dfd < 0)
		return -1;
	while ((r = do_read(sfd, buf, sizeof(buf))) > 0) {
		long off = 0;
		while (off < r) {
			long w = do_write(dfd, buf + off, r - off);
			if (w <= 0)
				return -1;
			off += w;
		}
	}
	do_close(sfd);
	do_close(dfd);
	return r < 0 ? -1 : 0;
}

/* 挂载后写/读一个测试文件，验证真实文件系统链路 */
static void ext2_test(void)
{
	char buf[64];
	int fd;
	long n;

	fd = do_openat(test_path, 577);	/* O_CREAT|O_WRONLY|O_TRUNC */
	if (fd < 0 || do_write(fd, test_data, sizeof(test_data) - 1) < 0) {
		do_write(1, test_write_fail, sizeof(test_write_fail) - 1);
		return;
	}
	do_close(fd);

	fd = do_openat(test_path, 0);	/* O_RDONLY */
	if (fd < 0) {
		do_write(1, test_read_fail, sizeof(test_read_fail) - 1);
		return;
	}
	n = do_read(fd, buf, sizeof(buf) - 1);
	do_close(fd);
	if (n < 0)
		return;
	buf[n] = 0;

	do_write(1, ext2_ok, sizeof(ext2_ok) - 1);
	do_write(1, buf, (ul)n);
}

/* .text.start 段由 init.ld 放在 .text 最前：保证 _start 在偏移 0（bFLT entry 要求） */
__attribute__((section(".text.start"))) void _start(void)
{
	char c;
	int fd;

	do_write(1, banner, sizeof(banner) - 1);

	/* devtmpfs：prepare_namespace 被跳过不自动挂，先挂上出 /dev 节点 */
	do_mount(devtmpfs, dev_dir, devtmpfs);
	fd = do_openat(tty_path, 2);	/* O_RDWR */
	if (fd < 0) {
		do_write(1, open_fail, sizeof(open_fail) - 1);
		for (;;) {
			__asm__ __volatile__("" ::: "memory");
		}
	}
	setup_raw(fd);

	if (copy_image() != 0) {
		do_write(1, copy_fail, sizeof(copy_fail) - 1);
		for (;;) {
			__asm__ __volatile__("" ::: "memory");
		}
	}
	do_mkdirat(mnt_dir, 0755);
	if (do_mount(ramdev, mnt_dir, "ext2") != 0) {
		do_write(1, mount_fail, sizeof(mount_fail) - 1);
		for (;;) {
			__asm__ __volatile__("" ::: "memory");
		}
	}
	ext2_test();

	do_write(fd, prompt, sizeof(prompt) - 1);
	for (;;) {
		if (do_read(fd, &c, 1) != 1)
			continue;
		if (c == '\r' || c == '\n') {
			do_write(fd, "\r\n", 2);
			do_write(fd, prompt, sizeof(prompt) - 1);
		} else if (c == 127 || c == 8) {
			do_write(fd, "\b \b", 3);
		} else {
			do_write(fd, &c, 1);
		}
	}
}
