/*
 * S3 工程 1 (00_earlycon) bootloader（分区表版）：
 *   分区 0 = KERNEL（3MB，s2/kernel-Image）-> PSRAM 0x11000000
 *   分区 1 = DTB（64K，dts 编译产物）   -> PSRAM 0x11700000（顶部）
 *   跳转 RISC-V 协议：a0 = hartid, a1 = DTB 物理地址
 * 相对 S1 的改动：真内核替换假镜像、DTB 分区 + 拷贝 + a1 传递。
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
    /* 读回校验：同时把 PSRAM 地址的 XIP 缓存行以正确内容填充 */
    printf("copy done. first bytes: %02x %02x %02x %02x\n",
           *(volatile uint8_t *)(dst + 0), *(volatile uint8_t *)(dst + 1),
           *(volatile uint8_t *)(dst + 2), *(volatile uint8_t *)(dst + 3));
}

int main(void) {
    vreg_set_voltage(VREG_VOLTAGE_DEFAULT);
    set_sys_clock_khz(150 * 1000, true);
    stdio_init_all();

    printf("\n=== s3-00 earlycon bootloader ===\n");
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

    printf("disable irqs, jump to 0x%08x (a0=0 hartid, a1=0x%08x dtb)\n",
           (unsigned)KERNEL_LOAD_ADDR, (unsigned)DTB_LOAD_ADDR);
    __asm__ volatile("csrci mstatus, 0x8"); // 清 MIE，避免中断干扰内核启动
    ((image_entry_t)KERNEL_LOAD_ADDR)(0, (void *)DTB_LOAD_ADDR);

    printf("should never reach here\n");
    while (true) tight_loop_contents();
}
