/*
 * amo-test: 对照实验——同一个 AMO 指令在 SRAM 上成功、在 PSRAM 上触发
 * Store/AMO Fault（mcause=7）。
 *
 * 背景：RP2350 的 Hazard3 把 AMO 实现为"排他读-写对"（手册 3.1.5），
 * 排他访问只在 SRAM 上支持；内核跑在 PSRAM 上，第一条原子操作
 * （boot_cpu_init -> set_cpu_online -> amoor.w）就撞墙（已在 GDB 下确认）。
 * 这个实验把硬件行为亲手钉死，为内核侧 AMO 模拟器做铺垫。
 *
 * 预期输出：
 *   SRAM  AMO: ok, var=1（原子 OR 生效）
 *   PSRAM AMO: TRAP mcause=0x7（指令被 mtvec 跳过，变量保持 0）
 */
#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/psram.h"

#define PSRAM_BASE 0x11000000u

volatile uint32_t trap_mcause;
volatile uint32_t trap_mepc;
volatile uint32_t trap_mtval;
volatile uint32_t trap_hit;

/*
 * 自定义 mtvec：记录死因（mcause/mepc/mtval）并把 mepc += 4 跳过
 * 出事的 AMO 指令后 mret，让测试继续跑。
 * 注意：会改写 t0/t1，用中断现场的 sp 压栈保存/恢复。
 */
__attribute__((naked, aligned(4)))
void amo_trap_handler(void) {
    __asm__ volatile(
        "addi sp, sp, -8\n"
        "sw   t0, 0(sp)\n"
        "sw   t1, 4(sp)\n"

        "csrr t0, 0x342\n"         // mcause
        "la   t1, trap_mcause\n"
        "sw   t0, 0(t1)\n"

        "csrr t0, 0x341\n"         // mepc
        "la   t1, trap_mepc\n"
        "sw   t0, 0(t1)\n"

        "csrr t0, 0x343\n"         // mtval
        "la   t1, trap_mtval\n"
        "sw   t0, 0(t1)\n"

        "li   t0, 1\n"
        "la   t1, trap_hit\n"
        "sw   t0, 0(t1)\n"

        "csrr t0, 0x341\n"         // mepc += 4：跳过出事的 AMO
        "addi t0, t0, 4\n"
        "csrw 0x341, t0\n"

        "lw   t1, 4(sp)\n"
        "lw   t0, 0(sp)\n"
        "addi sp, sp, 8\n"
        "mret\n"
    );
}

static void amo_or(uint32_t *addr) {
    __asm__ volatile("amoor.w.aqrl zero, %1, (%0)"
                     :: "r"(addr), "r"(1u) : "memory");
}

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);
    stdio_init_all();

    printf("\n=== amo-test ===\n");
    printf("PSRAM available: %d, size: %u\n",
           psram_is_available(), (unsigned)psram_get_size());

    // 接管机器异常：mtvec 指向我们的处理器（直接模式，4 字节对齐）
    __asm__ volatile("csrw 0x305, %0" :: "r"(amo_trap_handler));

    // --- SRAM：AMO 应该成功 ---
    static uint32_t sram_var = 0;   // .bss -> SRAM
    amo_or(&sram_var);
    printf("SRAM  AMO: ok, var=%u (期望 1)\n", (unsigned)sram_var);

    // --- PSRAM：普通写 OK，AMO 应该触发 mcause=7 ---
    volatile uint32_t *psram = (volatile uint32_t *)PSRAM_BASE;
    *psram = 0;                     // 普通 store：PSRAM 支持
    trap_hit = 0;
    amo_or((uint32_t *)psram);
    if (trap_hit) {
        printf("PSRAM AMO: TRAP mcause=0x%08lx mepc=0x%08lx mtval=0x%08lx\n",
               (unsigned long)trap_mcause, (unsigned long)trap_mepc,
               (unsigned long)trap_mtval);
        printf("           AMO 被跳过，变量=%u (期望仍为 0，AMO 未生效)\n",
               (unsigned)*psram);
    } else {
        printf("PSRAM AMO: no trap?! var=%u\n", (unsigned)*psram);
    }

    printf("done\n");
    while (true) tight_loop_contents();
}
