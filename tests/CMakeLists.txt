# 测试程序

add_executable(psram-test psram-test/main.c)
target_link_libraries(psram-test pico_stdlib hardware_psram)

pico_enable_stdio_usb(psram-test 1)
pico_enable_stdio_uart(psram-test 1)

pico_add_extra_outputs(psram-test)

# AMO 对照实验：SRAM 成功 vs PSRAM Store/AMO Fault（RP2350 硬件墙）
add_executable(amo-test amo-test/main.c)
target_link_libraries(amo-test pico_stdlib hardware_psram)

pico_enable_stdio_usb(amo-test 1)
pico_enable_stdio_uart(amo-test 1)

pico_add_extra_outputs(amo-test)
