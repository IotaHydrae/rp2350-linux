OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    /* 假镜像链接在 PSRAM XIP 地址，bootloader 拷到这里并跳转 */
    psram (rwx) : ORIGIN = 0x11000000, LENGTH = 0x00800000
}

SECTIONS {
    . = ORIGIN(psram);

    .text : {
        *(.text*)
    } > psram

    . = ALIGN(4);
    .rodata : {
        *(.rodata*)
    } > psram

    . = ALIGN(4);
    .data : {
        *(.data*)
    } > psram

    . = ALIGN(4);
    .bss (NOLOAD) : {
        *(.bss*)
        *(COMMON)
    } > psram

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.riscv.attributes)
    }
}
