# S4 工程 4 (03_root-ext2)：根切 ext2——legacy initrd

add_executable(s4-03-bootloader bootloader/main.c)
target_link_libraries(s4-03-bootloader pico_stdlib hardware_psram hardware_xip_cache)

pico_enable_stdio_usb(s4-03-bootloader 1)
pico_enable_stdio_uart(s4-03-bootloader 1)

pico_embed_pt_in_binary(s4-03-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s4-03-bootloader "absolute")
pico_package_uf2_output(s4-03-bootloader 0x10000000)

pico_add_extra_outputs(s4-03-bootloader)
