/*
 * psram-test-sfe: 与 psram-test 相同的写读自检，但 PSRAM 初始化改用
 * SparkFun 的 sfe_psram.c（QMI 直通模式裸操作）。
 * 用途：排除硬件 / 对比两条驱动路径。
 */
#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "sfe_psram.h"

#define PSRAM_BASE 0x11000000u

#ifndef PICO_PSRAM_CS_PIN
#error "board header must define PICO_PSRAM_CS_PIN"
#endif
#define SFE_PSRAM_CS_PIN PICO_PSRAM_CS_PIN // QMI CS1 引脚取自板卡头文件

static uint32_t failures = 0;

// 异常报告器：与 psram-test 相同，必须放 RAM（向量表 JAL ±1MB 限制）
void __not_in_flash_func(isr_riscv_machine_exception)(void) {
    uint32_t mcause, mepc, mtval;
    __asm__ volatile("csrr %0, 0x342" : "=r"(mcause)); // MCAUSE
    __asm__ volatile("csrr %0, 0x341" : "=r"(mepc));   // MEPC
    __asm__ volatile("csrr %0, 0x343" : "=r"(mtval));  // MTVAL

    printf("\n*** MACHINE EXCEPTION ***\n");
    printf("mcause = 0x%08lx (低12位: 5=load访问fault, 7=store/AMO访问fault)\n",
           (unsigned long)mcause);
    printf("mepc   = 0x%08lx (出事的指令地址)\n", (unsigned long)mepc);
    printf("mtval  = 0x%08lx (Hazard3 恒为 0)\n", (unsigned long)mtval);

    // 按数据手册建议：非法指令时自己读 mepc 处的指令字节
    const uint8_t *insn = (const uint8_t *)mepc;
    printf("insn bytes @ mepc: %02x %02x %02x %02x\n",
           insn[0], insn[1], insn[2], insn[3]);

    while (true) tight_loop_contents();
}

static void test_region(uint32_t offset, uint32_t length, uint32_t seed) {
    volatile uint32_t *base = (volatile uint32_t *)(PSRAM_BASE + offset);
    uint32_t words = length / 4;

    printf("  region @0x%08x write...\n", (unsigned)(PSRAM_BASE + offset));
    for (uint32_t i = 0; i < words; i++) {
        base[i] = seed + i;
    }
    printf("  region @0x%08x read...\n", (unsigned)(PSRAM_BASE + offset));
    for (uint32_t i = 0; i < words; i++) {
        if (base[i] != seed + i) {
            printf("  MISMATCH @ 0x%08x: wrote 0x%08x, read 0x%08x\n",
                   (unsigned)(PSRAM_BASE + offset + i * 4),
                   (unsigned)(seed + i), (unsigned)base[i]);
            failures++;
            if (failures >= 10) return;
        }
    }
    printf("  region @0x%08x PASS\n", (unsigned)(PSRAM_BASE + offset));
}

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);

    stdio_init_all();

    printf("\n=== psram-test-sfe ===\n");
    printf("sys clock: %lu Hz\n", (unsigned long)clock_get_hz(clk_sys));

    size_t psram_size = sfe_setup_psram(SFE_PSRAM_CS_PIN);
    printf("sfe_setup_psram(%d) -> size: %u bytes (0x%08x)\n",
           SFE_PSRAM_CS_PIN, (unsigned)psram_size, (unsigned)psram_size);

    if (psram_size == 0) {
        printf("PSRAM not found - check CS pin / wiring!\n");
        while (true) tight_loop_contents();
    }

    printf("write/read self-test on PSRAM...\n");
    test_region(0x000000, 4 * 1024, 0x11111111);               // start
    test_region(psram_size / 2, 4 * 1024, 0x22222222);         // middle
    test_region(psram_size - 4 * 1024, 4 * 1024, 0x33333333);  // end

    if (failures == 0) {
        printf("PASS: PSRAM is alive at 0x11000000 (sfe driver)\n");
    } else {
        printf("FAIL: %u mismatches\n", (unsigned)failures);
    }

    printf("done\n");
    while (true) tight_loop_contents();
}
