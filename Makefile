BUILD_DIR := build
BOARD ?= rp2350a_minimal
TOOLCHAIN ?= /home/developer/toolchain
PICO_SDK_PATH ?= /home/developer/raspberrypi/pico-sdk
QEMU_SCRIPT := s2/run-qemu.sh

.PHONY: all clean qemu test flash flash-bootloader flash-fake flash-psram-test

all: $(BUILD_DIR)/build.ninja
	ninja -C $(BUILD_DIR)

$(BUILD_DIR)/build.ninja: CMakeLists.txt Makefile s1/CMakeLists.txt tests/CMakeLists.txt | $(BUILD_DIR)
	cd $(BUILD_DIR) && \
	PICO_TOOLCHAIN_PATH=$(TOOLCHAIN) \
	cmake -DPICO_SDK_PATH=$(PICO_SDK_PATH) \
	      -DPICO_PLATFORM=rp2350-riscv \
	      -DPICO_BOARD=$(BOARD) \
	      -DPICO_BOARD_HEADER_DIRS=$(CURDIR)/boards \
	      .. -G Ninja

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ---- 烧录：每个例子一条命令（板子按住 BOOTSEL 插 USB）----
flash-bootloader: all
	picotool load -fu $(BUILD_DIR)/s1/bootloader.uf2

flash-fake: all
	# 假镜像写入分区 0（FAKE @ 64K）；烧完带分区表固件后需重启再进 BOOTSEL
	picotool load -fv -p 0 $(BUILD_DIR)/s1/fake-image.bin

flash-psram-test: all
	picotool load -fu $(BUILD_DIR)/tests/psram-test.uf2

# 兼容旧习惯：flash = 烧 bootloader
flash: flash-bootloader

# ---- 测试 ----
test: flash-psram-test
	@echo "打开串口观察 psram-test 输出（预期 PASS）"

qemu:
	$(QEMU_SCRIPT)

clean:
	rm -rf $(BUILD_DIR)
