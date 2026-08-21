cmake_minimum_required(VERSION 3.13)

SET(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# initialize the SDK based on PICO_SDK_PATH
include(pico_sdk_import.cmake)

project(rp2350-linux)

pico_sdk_init()

add_executable(psram-test tests/psram-test/main.c)
target_link_libraries(psram-test pico_stdlib hardware_psram)

pico_enable_stdio_usb(psram-test 1)
pico_enable_stdio_uart(psram-test 1)

pico_add_extra_outputs(psram-test)

# --- fake-image: 裸机假镜像，链接到 PSRAM 0x11000000，无 SDK ---
add_executable(fake-image s1/partition-table/fake-image/start.S s1/partition-table/fake-image/main.c)
target_compile_options(fake-image PRIVATE
    -march=rv32imac_zicsr_zifencei -mabi=ilp32
    -ffreestanding -fno-builtin -O2)
target_link_options(fake-image PRIVATE
    -nostdlib -nostartfiles
    -Wl,--build-id=none -Wl,--no-warn-rwx-segments
    -T ${CMAKE_CURRENT_LIST_DIR}/s1/partition-table/fake-image/fake-image.ld)
add_custom_command(TARGET fake-image POST_BUILD
    COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:fake-image> ${CMAKE_CURRENT_BINARY_DIR}/fake-image.bin
    COMMENT "Generating fake-image.bin")

# --- s1 bootloader: pico-sdk 应用 ---
add_executable(bootloader s1/partition-table/bootloader/main.c)
target_link_libraries(bootloader pico_stdlib hardware_psram)

pico_enable_stdio_usb(bootloader 1)
pico_enable_stdio_uart(bootloader 1)

pico_embed_pt_in_binary(bootloader ${CMAKE_CURRENT_LIST_DIR}/s1/partition-table/partition_table.json)
pico_set_uf2_family(bootloader "absolute")
pico_package_uf2_output(bootloader 0x10000000)

pico_add_extra_outputs(bootloader)
