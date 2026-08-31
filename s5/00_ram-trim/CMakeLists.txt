# S5 工程 1 (00_ram-trim)：裁剪优化①——RAM 路线轻量化
# bootloader 起点 = s4-05 + 225MHz 超频（sysclk/clk_peri，1.20V，用户改）

add_executable(s5-00-bootloader bootloader/main.c)
target_link_libraries(s5-00-bootloader pico_stdlib hardware_psram hardware_xip_cache)

pico_enable_stdio_usb(s5-00-bootloader 1)
pico_enable_stdio_uart(s5-00-bootloader 1)

pico_embed_pt_in_binary(s5-00-bootloader ${CMAKE_CURRENT_LIST_DIR}/partition_table.json)
pico_set_uf2_family(s5-00-bootloader "absolute")
pico_package_uf2_output(s5-00-bootloader 0x10000000)

pico_add_extra_outputs(s5-00-bootloader)
