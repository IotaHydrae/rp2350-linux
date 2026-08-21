/*
 * s1 bootloader: 读 flash 固定偏移（64KB）的假镜像 -> 拷到 PSRAM 0x11000000
 * -> 按 RISC-V 协议跳转（a0 = hartid, a1 = DTB；S1 没有 DTB，传 NULL）。
 */
#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/psram.h"

#define FAKE_IMAGE_FLASH_XIP 0x10010000u // flash 偏移 64KB 的 XIP 地址
#define FAKE_IMAGE_SIZE      0x1000u     // 固定 4KB 槽位
#define PSRAM_BASE           0x11000000u

typedef void (*image_entry_t)(uint32_t hart, void *dtb);

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);
    stdio_init_all();

    printf("\n=== s1 bootloader ===\n");
    printf("PSRAM available: %d, size: %u\n",
           psram_is_available(), (unsigned)psram_get_size());

    const uint8_t *src = (const uint8_t *)FAKE_IMAGE_FLASH_XIP;
    uint8_t *dst = (uint8_t *)PSRAM_BASE;

    printf("copy %u bytes: flash 0x%08x -> PSRAM 0x%08x\n",
           FAKE_IMAGE_SIZE, (unsigned)src, (unsigned)dst);
    memcpy(dst, src, FAKE_IMAGE_SIZE);
    printf("copy done. first bytes: %02x %02x %02x %02x\n",
           dst[0], dst[1], dst[2], dst[3]);

    printf("disable irqs, jump to 0x%08x (a0=0 hartid, a1=NULL)\n", PSRAM_BASE);
    __asm__ volatile("csrci mstatus, 0x8"); // 清 MIE，避免中断干扰镜像
    ((image_entry_t)PSRAM_BASE)(0, NULL);

    printf("should never reach here\n");
    while (true) tight_loop_contents();
}
