# S4 工程 2 (01_exec-hello)：shell 调用外部程序 /bin/hello

add_executable(s4-01-bootloader bootloader/main.c)
target_link_libraries(s4-01-bootloader pico_stdlib hardware_psram hardware_xip_cache)

pico_enable_stdio_usb(s4-01-bootloader 1)
pico_enable_stdio_uart(s4-01-bootloader 1)

pico_embed_pt_in_binary(s4-01-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s4-01-bootloader "absolute")
pico_package_uf2_output(s4-01-bootloader 0x10000000)

pico_add_extra_outputs(s4-01-bootloader)
