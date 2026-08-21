# 测试程序

add_executable(psram-test psram-test/main.c)
target_link_libraries(psram-test pico_stdlib hardware_psram)

pico_enable_stdio_usb(psram-test 1)
pico_enable_stdio_uart(psram-test 1)

pico_add_extra_outputs(psram-test)
