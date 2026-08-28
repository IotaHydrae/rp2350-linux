/*
 * S3 工程 2 (01_earlycon) bootloader（分区表版 · 最小化变体）：
 *   分区 0 = KERNEL（3MB，本工程 kernel-Image）-> PSRAM 0x11000000
 *   分区 1 = DTB（64K，dts 编译产物）   -> PSRAM 0x11700000（顶部）
 *   跳转 RISC-V 协议：a0 = hartid, a1 = DTB 物理地址
 *
 * 最小化说明：以下"曾经认为必要"的处理已全部移除（2026-08-26 真板验证均为冗余）：
 *   - uncached 拷贝 → 普通 memcpy（写回缓存路径；xip-stress 缓存 ON 全过）
 *   - 显式置 WRITABLE_M1 → SDK psram_init() 已置（psram.c:284）
 *   - 禁用 XIP 缓存 → 移除（恢复缓存 ON）
 *   - xip_cache_invalidate_all → 普通 memcpy 走缓存别名，天然一致
 *   - 清 mscratch / 清 MIE → 内核 head.S 自己清（CSR_SCRATCH zero / CSR_IE zero）
 */
#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "boot/picobin.h"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/psram.h"

#define KERNEL_LOAD_ADDR 0x11000000u
#define DTB_LOAD_ADDR    0x11700000u

typedef void (*image_entry_t)(uint32_t hart, void *dtb);

static bool find_partition(uint32_t id, uint32_t *flash_addr, uint32_t *size_bytes) {
    static __attribute__((aligned(4))) uint32_t workarea[1024];

    if (rom_load_partition_table((uint8_t *)workarea, sizeof(workarea), false)) {
        printf("partition table load failed\n");
        return false;
    }

    int rc = rom_get_partition_table_info(workarea, 0x8,
        PT_INFO_PARTITION_LOCATION_AND_FLAGS | PT_INFO_SINGLE_PARTITION | (id << 24));
    if (rc != 3) {
        printf("partition %u not found (rc=%d)\n", (unsigned)id, rc);
        return false;
    }

    uint32_t first = (workarea[1] & PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_BITS) >>
                     PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_LSB;
    uint32_t last = (workarea[1] & PICOBIN_PARTITION_LOCATION_LAST_SECTOR_BITS) >>
                    PICOBIN_PARTITION_LOCATION_LAST_SECTOR_LSB;
    *flash_addr = XIP_BASE + first * 0x1000u;
    *size_bytes = (last + 1) * 0x1000u - first * 0x1000u;
    printf("partition %u sectors [%u, %u] -> flash 0x%08x, size 0x%x\n",
           (unsigned)id, (unsigned)first, (unsigned)last,
           (unsigned)*flash_addr, (unsigned)*size_bytes);
    return true;
}

static void copy_image(const char *name, uint32_t flash_addr, uint32_t size, uint32_t dst) {
    printf("copy %s %u bytes: flash 0x%08x -> PSRAM 0x%08x\n",
           name, (unsigned)size, (unsigned)flash_addr, (unsigned)dst);
    memcpy((void *)dst, (const void *)flash_addr, size);
    printf("copy done.\n");
}

static uint32_t verify_copy(const char *name, uint32_t flash_addr, uint32_t size, uint32_t dst) {
    uint32_t mismatches = 0;
    const uint32_t *src = (const uint32_t *)flash_addr;
    const uint32_t *dstp = (const uint32_t *)dst;
    for (uint32_t i = 0; i < size / 4; i++) {
        if (src[i] != dstp[i]) {
            if (mismatches < 3)
                printf("  %s MISMATCH @ 0x%08x: flash=0x%08x psram=0x%08x\n",
                       name, (unsigned)(dst + i * 4),
                       (unsigned)src[i], (unsigned)dstp[i]);
            mismatches++;
        }
    }
    return mismatches;
}

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);
    stdio_init_all();

    printf("\n=== s3-03 irq bootloader ===\n");
    printf("PSRAM available: %d, size: %u\n",
           psram_is_available(), (unsigned)psram_get_size());

    uint32_t kernel_flash, kernel_size, dtb_flash, dtb_size;
    if (!find_partition(0, &kernel_flash, &kernel_size) ||
        !find_partition(1, &dtb_flash, &dtb_size)) {
        printf("failed to locate partitions - halting\n");
        while (true) tight_loop_contents();
    }

    copy_image("kernel", kernel_flash, kernel_size, KERNEL_LOAD_ADDR);
    copy_image("dtb", dtb_flash, dtb_size, DTB_LOAD_ADDR);

    uint32_t km = verify_copy("kernel", kernel_flash, kernel_size, KERNEL_LOAD_ADDR);
    uint32_t dm = verify_copy("dtb", dtb_flash, dtb_size, DTB_LOAD_ADDR);
    printf("verify: kernel mismatches=%u, dtb mismatches=%u\n", (unsigned)km, (unsigned)dm);
    if (km || dm) {
        printf("copy verification FAILED - halting\n");
        while (true) tight_loop_contents();
    }
    printf("first bytes: %02x %02x %02x %02x\n",
           *(volatile uint8_t *)(KERNEL_LOAD_ADDR + 0), *(volatile uint8_t *)(KERNEL_LOAD_ADDR + 1),
           *(volatile uint8_t *)(KERNEL_LOAD_ADDR + 2), *(volatile uint8_t *)(KERNEL_LOAD_ADDR + 3));

    printf("disable irqs, jump to 0x%08x (a0=0 hartid, a1=0x%08x dtb)\n",
           (unsigned)KERNEL_LOAD_ADDR, (unsigned)DTB_LOAD_ADDR);
    ((image_entry_t)KERNEL_LOAD_ADDR)(0, (void *)DTB_LOAD_ADDR);

    printf("should never reach here\n");
    while (true) tight_loop_contents();
}
