/*
 * S3 工程 2 (01_earlycon) bootloader（分区表版）：
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
#include "hardware/xip_cache.h"
#include "hardware/regs/addressmap.h"
#include "hardware/structs/xip.h"

#define KERNEL_LOAD_ADDR 0x11000000u
#define DTB_LOAD_ADDR    0x11700000u
#define PSRAM_UNCACHED(addr) (XIP_NOCACHE_NOALLOC_BASE + ((addr) - XIP_BASE))

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
    printf("copy %s %u bytes: flash 0x%08x -> PSRAM 0x%08x (uncached write)\n",
           name, (unsigned)size, (unsigned)flash_addr, (unsigned)dst);
    /* 写 PSRAM 走 uncached 别名（0x14... 窗口），绕开 XIP 写回缓存：
     * 3MB 大拷贝会让 16KB 缓存持续驱逐脏行，实测会损坏部分 PSRAM 区域
     * （flash 正确、PSRAM 错，坏值像残留数据）。 */
    memcpy((void *)PSRAM_UNCACHED(dst), (const void *)flash_addr, size);
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

    printf("\n=== s3-00 earlycon bootloader ===\n");
    printf("PSRAM available: %d, size: %u\n",
           psram_is_available(), (unsigned)psram_get_size());

    /* 显式开启 PSRAM 写使能（WRITABLE_M1）：XIP 内存默认只读，
     * 未置位时缓存写会"看似成功、驱逐时丢失"。打印当前值便于确认。 */
    hw_set_bits(&xip_ctrl_hw->ctrl, XIP_CTRL_WRITABLE_M1_BITS);
    printf("XIP_CTRL=0x%08lx (WRITABLE_M1=%lu)\n",
           (unsigned long)xip_ctrl_hw->ctrl,
           (unsigned long)((xip_ctrl_hw->ctrl & XIP_CTRL_WRITABLE_M1_BITS) ? 1 : 0));

    /* 禁用 XIP 缓存：本板 PSRAM 写回缓存不可靠（大拷贝丢写、内核写错位），
     * 全部走 uncached 保证正确性（慢但稳）。 */
    hw_clear_bits(&xip_ctrl_hw->ctrl, XIP_CTRL_EN_SECURE_BITS | XIP_CTRL_EN_NONSECURE_BITS);
    printf("XIP_CTRL=0x%08lx (cache disabled)\n", (unsigned long)xip_ctrl_hw->ctrl);

    uint32_t kernel_flash, kernel_size, dtb_flash, dtb_size;
    if (!find_partition(0, &kernel_flash, &kernel_size) ||
        !find_partition(1, &dtb_flash, &dtb_size)) {
        printf("failed to locate partitions - halting\n");
        while (true) tight_loop_contents();
    }

    copy_image("kernel", kernel_flash, kernel_size, KERNEL_LOAD_ADDR);
    copy_image("dtb", dtb_flash, dtb_size, DTB_LOAD_ADDR);

    /* 跳转前：使整个 XIP 缓存无效（读回/取指都拿到 PSRAM 真实内容），再整段校验 */
    xip_cache_invalidate_all();
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
    __asm__ volatile("csrci mstatus, 0x8"); // 清 MIE，避免中断干扰内核启动
    __asm__ volatile("csrw 0x340, zero");   // 清 mscratch：内核异常入口靠 mscratch=0 判定内核态
    ((image_entry_t)KERNEL_LOAD_ADDR)(0, (void *)DTB_LOAD_ADDR);

    printf("should never reach here\n");
    while (true) tight_loop_contents();
}
