/*
 * psram-test: prove that the 8MB PSRAM at 0x11000000 is alive.
 *
 * Steps:
 *   1. clock + UART (eyes for debugging)
 *   2. PSRAM init: done automatically by pico-sdk hardware_psram at
 *      runtime init (board header: CS1 = GPIO47, size 8MB, auto-detect size)
 *   3. print availability + size (size comes from reading the chip ID)
 *   4. write/read self-test on the 0x11000000 region
 */
#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/psram.h"

#define PSRAM_BASE 0x11000000u

static uint32_t failures = 0;

// --- 异常报告器 ---
// crt0 里机器异常入口是弱符号，默认实现 = 静默睡死（等调试器）。
// 我们接管它，把死因打印出来：mcause = 异常类型，mepc = 出事指令，
// mtval = 访问 fault 时被访问的地址。
// 必须放 RAM（.time_critical）：向量表在 SRAM，JAL 跳转范围只有 ±1MB，
// 放 flash 会链接失败（relocation truncated to fit）。
void __not_in_flash_func(isr_riscv_machine_exception)(void) {
    uint32_t mcause, mepc, mtval;
    __asm__ volatile("csrr %0, 0x342" : "=r"(mcause)); // MCAUSE
    __asm__ volatile("csrr %0, 0x341" : "=r"(mepc));   // MEPC
    __asm__ volatile("csrr %0, 0x343" : "=r"(mtval));  // MTVAL

    printf("\n*** MACHINE EXCEPTION ***\n");
    printf("mcause = 0x%08lx (低12位: 5=load访问fault, 7=store/AMO访问fault)\n",
           (unsigned long)mcause);
    printf("mepc   = 0x%08lx (出事的指令地址)\n", (unsigned long)mepc);
    printf("mtval  = 0x%08lx (被访问的地址)\n", (unsigned long)mtval);

    while (true) tight_loop_contents();
}

static void test_region(uint32_t offset, uint32_t length, uint32_t seed) {
    volatile uint32_t *base = (volatile uint32_t *)(PSRAM_BASE + offset);
    uint32_t words = length / 4;

    for (uint32_t i = 0; i < words; i++) {
        base[i] = seed + i;
    }

    for (uint32_t i = 0; i < words; i++) {
        if (base[i] != seed + i) {
            printf("  MISMATCH @ 0x%08x: wrote 0x%08x, read 0x%08x\n",
                   (unsigned)(PSRAM_BASE + offset + i * 4),
                   (unsigned)(seed + i), (unsigned)base[i]);
            failures++;
            if (failures >= 10) return;
        }
    }
}

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true); // datasheet nominal, no overclock

    // USB CDC + UART0 (GP16/17) 双路日志，Linux 接管前都用它看日志
    stdio_init_all();

    printf("\n=== psram-test ===\n");
    printf("sys clock: %lu Hz\n", (unsigned long)clock_get_hz(clk_sys));

    size_t psram_size = psram_get_size();
    printf("psram_is_available: %d\n", psram_is_available());
    printf("psram size: %u bytes (0x%08x)\n",
           (unsigned)psram_size, (unsigned)psram_size);

    if (!psram_is_available() || psram_size == 0) {
        printf("PSRAM not found - check CS pin / wiring!\n");
        while (true) tight_loop_contents();
    }

    printf("write/read self-test on PSRAM...\n");
    test_region(0x000000, 4 * 1024, 0x11111111);               // start
    test_region(psram_size / 2, 4 * 1024, 0x22222222);         // middle
    test_region(psram_size - 4 * 1024, 4 * 1024, 0x33333333);  // end

    if (failures == 0) {
        printf("PASS: PSRAM is alive at 0x11000000\n");
    } else {
        printf("FAIL: %u mismatches\n", (unsigned)failures);
    }

    printf("done\n");
    while (true) tight_loop_contents();
}
