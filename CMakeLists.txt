cmake_minimum_required(VERSION 3.13)

SET(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# initialize the SDK based on PICO_SDK_PATH
include(pico_sdk_import.cmake)

project(rp2350-linux)

pico_sdk_init()

# 每个目录自己管理构建目标：
add_subdirectory(s1)      # S1 主线：bootloader + fake-image
add_subdirectory(tests)   # 测试程序
add_subdirectory(s3/00_amowall)  # S3-00：最小 DTB 真板引导，撞出 AMO 墙
add_subdirectory(s3/01_earlycon)   # S3-01：AMO/amocas 模拟器跨墙，earlycon 出字 + init_IRQ panic
add_subdirectory(s3/02_timer)      # S3-02：定时器链——cpu-intc + timer-rp2350，jiffies 动起来
add_subdirectory(s3/03_irq)        # S3-03：Xh3irq 外设中断——UART0 RX 中断验收
