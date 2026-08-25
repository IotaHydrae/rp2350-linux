/*
 * xip-stress：CPU 侧 XIP 数据读/写可靠性压力测试。
 *
 * 背景：S3-01 调试发现，内核模拟器从 PSRAM/flash 读指令字节时间歇性拿到
 * 0xf0000000，而 GDB（调试模块读）看到的同一地址内容正确——怀疑 CPU 数据
 * 读路径（QMI/XIP）在"从 PSRAM 取指 + 数据访问"混合模式下不可靠。
 *
 * 本测试把一段纯汇编例程拷贝到 PSRAM 并从那里执行，在缓存开/关两种状态下：
 *   A. 全 8MB PSRAM 写 pattern 后读回
 *   B. 反色 pattern 再来一轮
 *   C. 同一地址反复读（抓 0xf0000000 抖动）
 *   D. flash 反复读一致性
 *   E. 读自己的代码区（在 PSRAM 上取指 + 数据读混合）
 */
#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/psram.h"
#include "hardware/xip_cache.h"
#include "hardware/structs/xip.h"

#define PSRAM_BASE   0x11000000u
#define ROUTINE_ADDR 0x117f0000u          /* PSRAM 顶部放例程 */
#define ROUTINE_WORDS (0x10000u / 4u)     /* 例程区 64KB，测试区从它下面开始 */
#define TEST_WORDS    ((0x800000u - 0x10000u) / 4u)  /* 8MB 减例程区 */
#define FLASH_BASE    0x10010000u          /* 分区 0 的 XIP 基址 */

extern unsigned int xip_stress_text_start;
extern unsigned int xip_stress_text_end;
extern int stress_write_readback(uint32_t base, uint32_t pattern, uint32_t words);
extern int stress_read_flake(uint32_t addr, uint32_t count);

typedef int (*wr_fn)(uint32_t base, uint32_t pattern, uint32_t words);
typedef int (*flake_fn)(uint32_t addr, uint32_t count);

static wr_fn stress_wr;
static flake_fn stress_flake;

static void set_cache(bool enable)
{
    if (enable)
        hw_set_bits(&xip_ctrl_hw->ctrl, XIP_CTRL_EN_SECURE_BITS | XIP_CTRL_EN_NONSECURE_BITS);
    else
        hw_clear_bits(&xip_ctrl_hw->ctrl, XIP_CTRL_EN_SECURE_BITS | XIP_CTRL_EN_NONSECURE_BITS);
    xip_cache_invalidate_all();
}

static void run_phase(const char *name, bool cache_en)
{
    set_cache(cache_en);
    printf("\n=== phase %s (cache %s) ===\n", name, cache_en ? "ON" : "OFF");

    /* A/B: 全区域写读回 */
    int m1 = stress_wr(PSRAM_BASE, 0x5a5a5a5a, TEST_WORDS);
    int m2 = stress_wr(PSRAM_BASE, 0xa5a5a5a5, TEST_WORDS);
    printf("wr 5a5a5a5a mismatches=%d\n", m1);
    printf("wr a5a5a5a5 mismatches=%d\n", m2);

    /* C: 同一 PSRAM 地址反复读 */
    uint32_t addrs[] = { PSRAM_BASE, 0x112ab558, PSRAM_BASE + 0x400000 };
    for (int i = 0; i < 3; i++) {
        int f = stress_flake(addrs[i], 10000);
        printf("flake 0x%08x diffs=%d (first=0x%08x)\n",
               (unsigned)addrs[i], f, (unsigned)*(volatile uint32_t *)addrs[i]);
    }

    /* D: flash 反复读一致性 */
    volatile uint32_t *fptr = (volatile uint32_t *)(FLASH_BASE + 0xed32);
    uint32_t first = *fptr;
    int fdiffs = 0;
    for (int i = 0; i < 10000; i++)
        if (*fptr != first)
            fdiffs++;
    printf("flash 0x%08x diffs=%d (first=0x%08x)\n",
           (unsigned)(FLASH_BASE + 0xed32), fdiffs, (unsigned)first);

    /* E: 读自己的代码区（PSRAM 上取指 + 数据读同一区域） */
    int sf = stress_flake(ROUTINE_ADDR, 10000);
    printf("self-code flake diffs=%d\n", sf);
}

int main(void)
{
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);
    stdio_init_all();

    printf("\n=== xip-stress ===\n");
    printf("PSRAM available: %d, size: %u\n",
           psram_is_available(), (unsigned)psram_get_size());

    /* 拷贝例程到 PSRAM（uncached 写保证内容正确），再整体失效缓存 */
    uint32_t len = (uint32_t)&xip_stress_text_end - (uint32_t)&xip_stress_text_start;
    memcpy((void *)(0x14000000u + (ROUTINE_ADDR - 0x10000000u)),
           (const void *)&xip_stress_text_start, len);
    xip_cache_invalidate_all();
    printf("routine: flash %p len 0x%x -> PSRAM 0x%08x\n",
           &xip_stress_text_start, (unsigned)len, (unsigned)ROUTINE_ADDR);

    /* 检查拷过去的内容 */
    if (memcmp((const void *)ROUTINE_ADDR, &xip_stress_text_start, len) != 0) {
        printf("routine copy MISMATCH - halting\n");
        while (true) tight_loop_contents();
    }
    printf("routine copy ok\n");

    stress_wr = (wr_fn)(ROUTINE_ADDR + ((uint32_t)stress_write_readback - (uint32_t)&xip_stress_text_start));
    stress_flake = (flake_fn)(ROUTINE_ADDR + ((uint32_t)stress_read_flake - (uint32_t)&xip_stress_text_start));

    run_phase("1", true);
    run_phase("2", false);

    printf("\ndone\n");
    while (true) tight_loop_contents();
}
