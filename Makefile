BUILD_DIR := build
TARGET ?= bootloader
BOARD ?= rp2350a_minimal
TOOLCHAIN ?= /home/developer/toolchain
PICO_SDK_PATH ?= /home/developer/raspberrypi/pico-sdk

.PHONY: all flash clean

all: $(BUILD_DIR)/build.ninja
	ninja -C $(BUILD_DIR)

$(BUILD_DIR)/build.ninja: CMakeLists.txt Makefile | $(BUILD_DIR)
	cd $(BUILD_DIR) && \
	PICO_TOOLCHAIN_PATH=$(TOOLCHAIN) \
	cmake -DPICO_SDK_PATH=$(PICO_SDK_PATH) \
	      -DPICO_PLATFORM=rp2350-riscv \
	      -DPICO_BOARD=$(BOARD) \
	      -DPICO_BOARD_HEADER_DIRS=$(CURDIR)/boards \
	      .. -G Ninja

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

flash: all
	picotool load -fu $(BUILD_DIR)/$(TARGET).uf2

flash-fake: all
	# 分区表版：按分区 id 0（FAKE @ 64K）写入，不再手动算地址
	# 注意：烧完含分区表的 bootloader 后，设备需重启再进 BOOTSEL，picotool 才能读到分区表
	picotool load -fv -p 0 $(BUILD_DIR)/fake-image.bin

clean:
	rm -rf $(BUILD_DIR)
