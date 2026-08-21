/*
 * fake-image: S1 的假镜像。
 * 无 SDK、无运行时，链接在 PSRAM 0x11000000，由 bootloader 拷入后跳转执行。
 * UART0 由 bootloader 配好（115200, GP16/17），这里直接写 PL011 寄存器打印。
 */
#include <stdint.h>

#define UART0_BASE 0x40070000u
#define UART_DR    (*(volatile uint32_t *)(UART0_BASE + 0x000))
#define UART_FR    (*(volatile uint32_t *)(UART0_BASE + 0x018))
#define UART_FR_TXFF (1u << 5) // TX FIFO full: 等它空再写

static void uart_putc(char c) {
    while (UART_FR & UART_FR_TXFF) {}
    UART_DR = (uint32_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_hex(uint32_t v) {
    static const char hex[] = "0123456789abcdef";
    for (int i = 28; i >= 0; i -= 4) {
        uart_putc(hex[(v >> i) & 0xf]);
    }
}

void main_c(uint32_t hart, void *dtb) {
    uart_puts("\r\n[Fake Image] running from PSRAM!\r\n");
    uart_puts("a0 (hartid) = 0x");
    uart_hex(hart);
    uart_puts("\r\n");
    uart_puts("a1 (dtb)    = 0x");
    uart_hex((uint32_t)dtb);
    uart_puts("\r\n");

    // 自检：从 0x11000000 读回自己的第一条指令
    uint32_t first = *(volatile uint32_t *)0x11000000u;
    uart_puts("self-check: word at 0x11000000 = 0x");
    uart_hex(first);
    uart_puts("\r\n");

    uart_puts("[Fake Image] done, looping.\r\n");
    for (;;) {
        __asm__ volatile("" ::: "memory");
    }
}
