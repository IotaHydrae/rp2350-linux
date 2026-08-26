BUILD_DIR := build
BOARD ?= rp2350a_minimal
TOOLCHAIN ?= /home/developer/toolchain
PICO_SDK_PATH ?= /home/developer/raspberrypi/pico-sdk
QEMU_SCRIPT := s2/run-qemu.sh

.PHONY: all clean qemu test flash flash-bootloader flash-fake flash-psram-test flash-amo-test flash-xip-stress \
        flash-s3-00-bootloader flash-s3-00-kernel flash-s3-00-dtb \
        flash-s3-01-bootloader flash-s3-01-kernel flash-s3-01-dtb

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
	# --ignore-partitions：烧绝对地址固件时绕过分区路由（否则 rp2350-riscv 家族会被导进分区 0）
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s1/bootloader.uf2

flash-fake: all
	# 假镜像写入分区 0（FAKE @ 64K）；烧完带分区表固件后需重启再进 BOOTSEL
	picotool load -fv -p 0 $(BUILD_DIR)/s1/fake-image.bin

flash-psram-test: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/tests/psram-test.uf2

flash-amo-test: all
	# AMO 对照实验（SRAM vs PSRAM）
	picotool load -fu --ignore-partitions $(BUILD_DIR)/tests/amo-test.uf2

flash-xip-stress: all
	# XIP 数据读/写可靠性压力测试（PSRAM 上执行）
	picotool load -fu --ignore-partitions $(BUILD_DIR)/tests/xip-stress.uf2

# ---- S3 工程 1 (00_amowall 撞墙定位)：bootloader + 内核 + DTB 各一条命令 ----
flash-s3-00-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s3/00_amowall/s3-00-bootloader.uf2

flash-s3-00-kernel: all
	# 内核写入分区 0（KERNEL @ 64K，3MB）；烧完 bootloader 后需重启再进 BOOTSEL
	# -t bin 必须放在 -p 之后（picotool 解析器见到 -t 后不再接受 -p）
	# 用工程内副本：重新构建内核后执行 cp s2/kernel-Image s3/00_amowall/kernel-Image
	picotool load -fv -p 0 -t bin s3/00_amowall/kernel-Image

flash-s3-00-dtb: $(BUILD_DIR)/s3/00_amowall/rp2350a-minimal.dtb
	# DTB 写入分区 1（DTB @ 3MB+64K）
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s3/00_amowall/rp2350a-minimal.dtb

$(BUILD_DIR)/s3/00_amowall/rp2350a-minimal.dtb: s3/00_amowall/dts/rp2350a-minimal.dts s3/00_amowall/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s3/00_amowall
	cpp -nostdinc -I s3/00_amowall/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s3/00_amowall/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s3/00_amowall/rp2350a-minimal.dts.pre

# ---- S3 工程 2 (01_earlycon 出字验收) ----
flash-s3-01-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s3/01_earlycon/s3-01-bootloader.uf2

flash-s3-01-kernel: all
	# 带 AMO 模拟器的新内核 → 分区 0
	picotool load -fv -p 0 -t bin s3/01_earlycon/kernel-Image

flash-s3-01-dtb: $(BUILD_DIR)/s3/01_earlycon/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s3/01_earlycon/rp2350a-minimal.dtb

$(BUILD_DIR)/s3/01_earlycon/rp2350a-minimal.dtb: s3/01_earlycon/dts/rp2350a-minimal.dts s3/01_earlycon/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s3/01_earlycon
	cpp -nostdinc -I s3/01_earlycon/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s3/01_earlycon/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s3/01_earlycon/rp2350a-minimal.dts.pre

# 兼容旧习惯：flash = 烧 bootloader
flash: flash-bootloader

# ---- 测试 ----
test: flash-psram-test
	@echo "打开串口观察 psram-test 输出（预期 PASS）"

qemu:
	$(QEMU_SCRIPT)

clean:
	rm -rf $(BUILD_DIR)
