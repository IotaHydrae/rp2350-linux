/*
 * S4-01 /bin/hello —— 外部程序（第二个手搓 bFLT）
 *
 * 无 libc：NOMMU 用户态只有 FLAT 格式，工具链无 elf2flt；
 * printf 用 write() 内联实现（打印 Hello, world!）。
 * 由 shell vfork + execve 拉起；继承 shell 的 fd 1（console → ttyAMA0）。
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

static inline void do_exit(int code)
{
	do_syscall6(93, code, 0, 0, 0, 0, 0);
}

static const char msg[] = "Hello, world!\n";

void _start(void)
{
	do_write(1, msg, sizeof(msg) - 1);
	do_exit(0);
}
