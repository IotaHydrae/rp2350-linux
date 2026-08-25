# S3 工程 2 (01_amo-emu)：内核 AMO 模拟器——让内核跑过 PSRAM 第一条原子操作
# bootloader / dts / 分区表与 00 相同（DTB 仍故意缺 intc/timebase）

add_executable(s3-01-bootloader bootloader/main.c)
target_link_libraries(s3-01-bootloader pico_stdlib hardware_psram)

pico_enable_stdio_usb(s3-01-bootloader 1)
pico_enable_stdio_uart(s3-01-bootloader 1)

pico_embed_pt_in_binary(s3-01-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s3-01-bootloader "absolute")
pico_package_uf2_output(s3-01-bootloader 0x10000000)

pico_add_extra_outputs(s3-01-bootloader)
