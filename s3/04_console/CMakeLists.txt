# S3 工程 5 (04_console)：真 console 收尾——ttyAMA0 确定接管日志

add_executable(s3-04-bootloader bootloader/main.c)
target_link_libraries(s3-04-bootloader pico_stdlib hardware_psram hardware_xip_cache)

pico_enable_stdio_usb(s3-04-bootloader 1)
pico_enable_stdio_uart(s3-04-bootloader 1)

pico_embed_pt_in_binary(s3-04-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s3-04-bootloader "absolute")
pico_package_uf2_output(s3-04-bootloader 0x10000000)

pico_add_extra_outputs(s3-04-bootloader)
