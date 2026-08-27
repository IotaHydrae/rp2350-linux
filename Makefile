BUILD_DIR := build
BOARD ?= rp2350a_minimal
TOOLCHAIN ?= /home/developer/toolchain
PICO_SDK_PATH ?= /home/developer/raspberrypi/pico-sdk
QEMU_SCRIPT := s2/run-qemu.sh

.PHONY: all clean qemu test flash flash-bootloader flash-fake flash-psram-test flash-amo-test flash-xip-stress \
        kernel-s3-00 kernel-s3-01 kernel-s3-02 \
        flash-s3-00-bootloader flash-s3-00-kernel flash-s3-00-dtb \
        flash-s3-01-bootloader flash-s3-01-kernel flash-s3-01-dtb \
        flash-s3-02-bootloader flash-s3-02-kernel flash-s3-02-dtb

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

# ---- S3 工程 3 (02_timer：定时器链验收) ----
flash-s3-02-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s3/02_timer/s3-02-bootloader.uf2

flash-s3-02-kernel: all
	# 带 timer-rp2350 驱动 + cpu-intc 的新内核 → 分区 0
	picotool load -fv -p 0 -t bin s3/02_timer/kernel-Image

flash-s3-02-dtb: $(BUILD_DIR)/s3/02_timer/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s3/02_timer/rp2350a-minimal.dtb

$(BUILD_DIR)/s3/02_timer/rp2350a-minimal.dtb: s3/02_timer/dts/rp2350a-minimal.dts s3/02_timer/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s3/02_timer
	cpp -nostdinc -I s3/02_timer/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s3/02_timer/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s3/02_timer/rp2350a-minimal.dts.pre

# ---- 内核构建（linux-7.2 源码树，out-of-tree 构建目录）----
# 用法：改完内核源码后直接 `make kernel-s3-00` / `make kernel-s3-01`，
#       自动完成 配置 → 编译 → 拷贝到对应工程目录。
# 手动等价命令（了解原理用）：
#   cd /home/developer/linux-7.2
#   make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32[-00] <rp2350_*_defconfig>
#   make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32[-00] -j$(nproc) Image
#   cp build-rv32[-00]/arch/riscv/boot/Image <工程>/s3/0x_*/kernel-Image
KERNEL_SRC   ?= /home/developer/linux-7.2
KERNEL_BUILD := $(KERNEL_SRC)/build-rv32
KERNEL_CROSS ?= riscv64-linux-gnu-

# ---- S3-00（撞墙定位，无 AMO 模拟器）：build-rv32-00 ----
# .config 不存在、或 defconfig 有改动时，重新生成。
# 完整 defconfig（savedefconfig 导出）为真源，只放工程内：拷进构建目录当 .config 种子，
# 再 olddefconfig 补齐默认值。不往内核树加 config，也不用 merge_config（其 alldefconfig
# 会用默认值重建配置，MMU 默认 y 会盖掉 MMU=n）。
$(KERNEL_SRC)/build-rv32-00/.config: $(CURDIR)/s3/00_amowall/rp2350_amowall_defconfig
	mkdir -p $(KERNEL_SRC)/build-rv32-00
	cp $(CURDIR)/s3/00_amowall/rp2350_amowall_defconfig $(KERNEL_SRC)/build-rv32-00/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-00 olddefconfig

# 编译内核 Image 并存档到 S3-00 工程（烧录用 make flash-s3-00-kernel）
kernel-s3-00: $(KERNEL_SRC)/build-rv32-00/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-00 -j$$(nproc) Image
	cp $(KERNEL_SRC)/build-rv32-00/arch/riscv/boot/Image s3/00_amowall/kernel-Image
	sha256sum s3/00_amowall/kernel-Image

# ---- S3-01（earlycon 出字，含 AMO/amocas 模拟器）：build-rv32 ----
# 完整 defconfig（savedefconfig 导出）为真源，只放工程内：拷进构建目录当 .config 种子，
# 再 olddefconfig 补齐默认值（不依赖内核树 configs）。
$(KERNEL_BUILD)/.config: $(CURDIR)/s3/01_earlycon/rp2350_minimal_defconfig
	mkdir -p $(KERNEL_BUILD)
	cp $(CURDIR)/s3/01_earlycon/rp2350_minimal_defconfig $(KERNEL_BUILD)/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32 olddefconfig

# 编译内核 Image 并存档到 S3-01 工程（烧录用 make flash-s3-01-kernel）
kernel-s3-01: $(KERNEL_BUILD)/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32 -j$$(nproc) Image
	cp $(KERNEL_BUILD)/arch/riscv/boot/Image s3/01_earlycon/kernel-Image
	sha256sum s3/01_earlycon/kernel-Image

# ---- S3-02（定时器链：cpu-intc + timer-rp2350）：build-rv32-02 ----
$(KERNEL_SRC)/build-rv32-02/.config: $(CURDIR)/s3/02_timer/rp2350_minimal_defconfig
	mkdir -p $(KERNEL_SRC)/build-rv32-02
	cp $(CURDIR)/s3/02_timer/rp2350_minimal_defconfig $(KERNEL_SRC)/build-rv32-02/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-02 olddefconfig

# 编译内核 Image 并存档到 S3-02 工程（烧录用 make flash-s3-02-kernel）
kernel-s3-02: $(KERNEL_SRC)/build-rv32-02/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-02 -j$$(nproc) Image
	cp $(KERNEL_SRC)/build-rv32-02/arch/riscv/boot/Image s3/02_timer/kernel-Image
	sha256sum s3/02_timer/kernel-Image

# 兼容旧习惯：flash = 烧 bootloader
flash: flash-bootloader

# ---- 测试 ----
test: flash-psram-test
	@echo "打开串口观察 psram-test 输出（预期 PASS）"

qemu:
	$(QEMU_SCRIPT)

clean:
	rm -rf $(BUILD_DIR)
