cmake_minimum_required(VERSION 3.13)

SET(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# initialize the SDK based on PICO_SDK_PATH
include(pico_sdk_import.cmake)

project(rp2350-linux)

pico_sdk_init()

# 每个目录自己管理构建目标：
add_subdirectory(s1)      # S1 主线：bootloader + fake-image
add_subdirectory(tests)   # 测试程序
