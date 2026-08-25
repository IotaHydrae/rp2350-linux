# S3 工程 1 (00_earlycon)：真内核加载 + 最小 DTB + earlycon 出字
# 注意：目标名带工程前缀，避免与 s1 的 bootloader 目标冲突

add_executable(s3-00-bootloader bootloader/main.c)
target_link_libraries(s3-00-bootloader pico_stdlib hardware_psram)

pico_enable_stdio_usb(s3-00-bootloader 1)
pico_enable_stdio_uart(s3-00-bootloader 1)

pico_embed_pt_in_binary(s3-00-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s3-00-bootloader "absolute")
pico_package_uf2_output(s3-00-bootloader 0x10000000)

pico_add_extra_outputs(s3-00-bootloader)
