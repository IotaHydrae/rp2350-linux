# S3 工程 3 (02_timer)：定时器链——cpu-intc + timer-rp2350 驱动，
# 过 init_IRQ panic、jiffies 动起来（Xh3irq 外设中断下一关）

add_executable(s3-02-bootloader bootloader/main.c)
target_link_libraries(s3-02-bootloader pico_stdlib hardware_psram hardware_xip_cache)

pico_enable_stdio_usb(s3-02-bootloader 1)
pico_enable_stdio_uart(s3-02-bootloader 1)

pico_embed_pt_in_binary(s3-02-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s3-02-bootloader "absolute")
pico_package_uf2_output(s3-02-bootloader 0x10000000)

pico_add_extra_outputs(s3-02-bootloader)
