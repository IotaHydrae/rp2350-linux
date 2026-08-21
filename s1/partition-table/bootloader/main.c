/*
 * s1 bootloader（分区表版）:
 * 从 picobin 分区表定位 FAKE 分区（id 0，flash 偏移 64K）
 * -> 拷到 PSRAM 0x11000000 -> 按 RISC-V 协议跳转（a0 = hartid, a1 = DTB；S1 没有 DTB，传 NULL）。
 */
#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "boot/picobin.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/psram.h"
#include "hardware/regs/addressmap.h"

#define FAKE_IMAGE_SIZE 0x1000u // 固定拷 4KB（镜像 373B，槽位够用）
#define PSRAM_BASE      0x11000000u

typedef void (*image_entry_t)(uint32_t hart, void *dtb);

static bool find_fake_partition(uint32_t *data_addr, uint32_t *data_size) {
    static __attribute__((aligned(4))) uint32_t workarea[1024];

    if (rom_load_partition_table((uint8_t *)workarea, sizeof(workarea), false)) {
        printf("partition table load failed\n");
        return false;
    }

    int rc = rom_get_partition_table_info(workarea, 0x8,
        PT_INFO_PARTITION_LOCATION_AND_FLAGS | PT_INFO_SINGLE_PARTITION);
    if (rc != 3) {
        printf("no boot partition found (rc=%d)\n", rc);
        return false;
    }

    uint32_t first = (workarea[1] & PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_BITS) >>
                     PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_LSB;
    uint32_t last = (workarea[1] & PICOBIN_PARTITION_LOCATION_LAST_SECTOR_BITS) >>
                    PICOBIN_PARTITION_LOCATION_LAST_SECTOR_LSB;
    *data_addr = XIP_BASE + first * 0x1000u;
    *data_size = (last + 1) * 0x1000u - first * 0x1000u;
    printf("partition sectors [%u, %u] -> flash 0x%08x, size 0x%x\n",
           (unsigned)first, (unsigned)last, (unsigned)*data_addr, (unsigned)*data_size);
    return true;
}

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);
    stdio_init_all();

    printf("\n=== s1 bootloader (partition table) ===\n");
    printf("PSRAM available: %d, size: %u\n",
           psram_is_available(), (unsigned)psram_get_size());

    uint32_t src_addr, part_size;
    if (!find_fake_partition(&src_addr, &part_size)) {
        printf("failed to locate fake image partition - halting\n");
        while (true) tight_loop_contents();
    }

    const uint8_t *src = (const uint8_t *)src_addr;
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
