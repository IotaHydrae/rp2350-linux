BUILD_DIR := build
TARGET := psram-test
BOARD := waveshare_rp2350b_plus_w
TOOLCHAIN ?= /home/developer/toolchain
PICO_SDK_PATH ?= /home/developer/raspberrypi/pico-sdk

.PHONY: all flash clean

all: $(BUILD_DIR)/build.ninja
	ninja -C $(BUILD_DIR)

$(BUILD_DIR)/build.ninja: CMakeLists.txt | $(BUILD_DIR)
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

clean:
	rm -rf $(BUILD_DIR)
