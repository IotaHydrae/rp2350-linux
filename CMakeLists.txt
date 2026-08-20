cmake_minimum_required(VERSION 3.13)

SET(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# initialize the SDK based on PICO_SDK_PATH
include(pico_sdk_import.cmake)

project(rp2350-linux)

pico_sdk_init()

add_executable(psram-test psram-test/main.c)
target_link_libraries(psram-test pico_stdlib hardware_psram)

pico_enable_stdio_usb(psram-test 0)
pico_enable_stdio_uart(psram-test 1)

pico_add_extra_outputs(psram-test)
