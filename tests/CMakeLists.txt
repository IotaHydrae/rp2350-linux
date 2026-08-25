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

# XIP 数据读/写可靠性压力测试（PSRAM 上执行 + 读写混合）
add_executable(xip-stress xip-stress/main.c xip-stress/stress_asm.S)
target_link_libraries(xip-stress pico_stdlib hardware_psram hardware_xip_cache)

pico_enable_stdio_usb(xip-stress 1)
pico_enable_stdio_uart(xip-stress 1)

pico_add_extra_outputs(xip-stress)
