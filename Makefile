BUILD_DIR := build
BOARD ?= rp2350a_minimal
TOOLCHAIN ?= /home/developer/toolchain
PICO_SDK_PATH ?= /home/developer/raspberrypi/pico-sdk
QEMU_SCRIPT := s2/run-qemu.sh

.PHONY: all clean qemu test flash flash-bootloader flash-fake flash-psram-test flash-amo-test flash-xip-stress \
        kernel-s3-00 kernel-s3-01 kernel-s3-02 kernel-s3-03 \
        kernel-s3-04 kernel-s3-05 init-s3-05 \
        kernel-s4-00 rootfs-s4-00 init-s4-00 \
        kernel-s4-01 init-s4-01 hello-s4-01 rootfs-s4-01 \
        flash-s3-00-bootloader flash-s3-00-kernel flash-s3-00-dtb \
        flash-s3-01-bootloader flash-s3-01-kernel flash-s3-01-dtb \
        flash-s3-02-bootloader flash-s3-02-kernel flash-s3-02-dtb \
        flash-s3-03-bootloader flash-s3-03-kernel flash-s3-03-dtb \
        flash-s3-04-bootloader flash-s3-04-kernel flash-s3-04-dtb \
        flash-s3-05-bootloader flash-s3-05-kernel flash-s3-05-dtb \
        flash-s4-00-bootloader flash-s4-00-kernel flash-s4-00-dtb flash-s4-00-rootfs \
        flash-s4-01-bootloader flash-s4-01-kernel flash-s4-01-dtb flash-s4-01-rootfs

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

# ---- S3 工程 4 (03_irq：Xh3irq 外设中断验收) ----
flash-s3-03-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s3/03_irq/s3-03-bootloader.uf2

flash-s3-03-kernel: all
	# 带 xh3irq 驱动的新内核 → 分区 0
	picotool load -fv -p 0 -t bin s3/03_irq/kernel-Image

flash-s3-03-dtb: $(BUILD_DIR)/s3/03_irq/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s3/03_irq/rp2350a-minimal.dtb

$(BUILD_DIR)/s3/03_irq/rp2350a-minimal.dtb: s3/03_irq/dts/rp2350a-minimal.dts s3/03_irq/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s3/03_irq
	cpp -nostdinc -I s3/03_irq/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s3/03_irq/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s3/03_irq/rp2350a-minimal.dts.pre

# ---- S3 工程 5 (04_console：真 console 收尾) ----
flash-s3-04-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s3/04_console/s3-04-bootloader.uf2

flash-s3-04-kernel: all
	# 内核与 03 同源（DEBUG_INFO）；VT 定案后由 kernel-s3-04 重建
	picotool load -fv -p 0 -t bin s3/04_console/kernel-Image

flash-s3-04-dtb: $(BUILD_DIR)/s3/04_console/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s3/04_console/rp2350a-minimal.dtb

$(BUILD_DIR)/s3/04_console/rp2350a-minimal.dtb: s3/04_console/dts/rp2350a-minimal.dts s3/04_console/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s3/04_console
	cpp -nostdinc -I s3/04_console/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s3/04_console/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s3/04_console/rp2350a-minimal.dts.pre

# ---- S3 工程 6 (05_shell：进 shell) ----
flash-s3-05-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s3/05_shell/s3-05-bootloader.uf2

flash-s3-05-kernel: all
	# initramfs 编在 Image 里，必须由 kernel-s3-05 重建后再烧
	picotool load -fv -p 0 -t bin s3/05_shell/kernel-Image

flash-s3-05-dtb: $(BUILD_DIR)/s3/05_shell/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s3/05_shell/rp2350a-minimal.dtb

$(BUILD_DIR)/s3/05_shell/rp2350a-minimal.dtb: s3/05_shell/dts/rp2350a-minimal.dts s3/05_shell/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s3/05_shell
	cpp -nostdinc -I s3/05_shell/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s3/05_shell/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s3/05_shell/rp2350a-minimal.dts.pre

# ---- S4 工程 1 (00_boot-initramfs：bootloader 拷 initramfs) ----
flash-s4-00-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s4/00_boot-initramfs/s4-00-bootloader.uf2

flash-s4-00-kernel: all
	picotool load -fv -p 0 -t bin s4/00_boot-initramfs/kernel-Image

flash-s4-00-dtb: $(BUILD_DIR)/s4/00_boot-initramfs/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s4/00_boot-initramfs/rp2350a-minimal.dtb

flash-s4-00-rootfs: rootfs-s4-00
	# rootfs 独立烧录：改 rootfs 只需重跑这一条（内核/DTB/bootloader 不用动）
	picotool load -fv -p 2 -t bin s4/00_boot-initramfs/rootfs.cpio

$(BUILD_DIR)/s4/00_boot-initramfs/rp2350a-minimal.dtb: s4/00_boot-initramfs/dts/rp2350a-minimal.dts s4/00_boot-initramfs/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s4/00_boot-initramfs
	cpp -nostdinc -I s4/00_boot-initramfs/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s4/00_boot-initramfs/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s4/00_boot-initramfs/rp2350a-minimal.dts.pre

# ---- S4-00 rootfs：gen_init_cpio 清单 → rootfs.cpio（分区 2）----
GEN_INIT_CPIO = $(KERNEL_SRC)/build-rv32-05/usr/gen_init_cpio

$(GEN_INIT_CPIO):
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-05 usr/gen_init_cpio

rootfs-s4-00: init-s4-00 $(GEN_INIT_CPIO) s4/00_boot-initramfs/initramfs.list
	$(GEN_INIT_CPIO) s4/00_boot-initramfs/initramfs.list > s4/00_boot-initramfs/rootfs.cpio
	sha256sum s4/00_boot-initramfs/rootfs.cpio

# ---- S4-00 /init（rootfs 内容，bFLT 手搓，S4 自洽）----
INITRAMFS_S4_SRC := s4/00_boot-initramfs/initramfs-src
INITRAMFS_S4_DIR := s4/00_boot-initramfs/initramfs

init-s4-00: $(INITRAMFS_S4_SRC)/init.c $(INITRAMFS_S4_SRC)/init.ld scripts/pack-bflt.sh
	mkdir -p $(BUILD_DIR) $(INITRAMFS_S4_DIR)
	riscv64-linux-gnu-gcc -march=rv32imac -mabi=ilp32 -fPIC -mno-relax \
	    -msmall-data-limit=0 -nostdlib -no-pie -O2 -fno-builtin -Wall -Wextra \
	    -T $(INITRAMFS_S4_SRC)/init.ld -o $(BUILD_DIR)/init-s4-00.elf $(INITRAMFS_S4_SRC)/init.c
	scripts/pack-bflt.sh $(BUILD_DIR)/init-s4-00.elf $(INITRAMFS_S4_DIR)/init

# ---- S4 工程 2 (01_exec-hello：shell 调用外部程序) ----
flash-s4-01-bootloader: all
	picotool load -fu --ignore-partitions $(BUILD_DIR)/s4/01_exec-hello/s4-01-bootloader.uf2

flash-s4-01-kernel: all
	# 内核与 S4-00 相同（S4-01 无内核改动），kernel-Image 为 S4-00 拷贝
	picotool load -fv -p 0 -t bin s4/01_exec-hello/kernel-Image

flash-s4-01-dtb: $(BUILD_DIR)/s4/01_exec-hello/rp2350a-minimal.dtb
	picotool load -fv -p 1 -t bin $(BUILD_DIR)/s4/01_exec-hello/rp2350a-minimal.dtb

flash-s4-01-rootfs: rootfs-s4-01
	picotool load -fv -p 2 -t bin s4/01_exec-hello/rootfs.cpio

$(BUILD_DIR)/s4/01_exec-hello/rp2350a-minimal.dtb: s4/01_exec-hello/dts/rp2350a-minimal.dts s4/01_exec-hello/dts/rp2350a.dtsi | $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/s4/01_exec-hello
	cpp -nostdinc -I s4/01_exec-hello/dts -undef -x assembler-with-cpp \
	    -o $(BUILD_DIR)/s4/01_exec-hello/rp2350a-minimal.dts.pre $<
	dtc -I dts -O dtb -o $@ $(BUILD_DIR)/s4/01_exec-hello/rp2350a-minimal.dts.pre

# ---- S4-01 rootfs：/init（shell）+ /bin/hello ----
INITRAMFS_S41_SRC := s4/01_exec-hello/initramfs-src
INITRAMFS_S41_DIR := s4/01_exec-hello/initramfs
HELLO_SRC := s4/01_exec-hello/hello-src

init-s4-01: $(INITRAMFS_S41_SRC)/init.c $(INITRAMFS_S41_SRC)/init.ld scripts/pack-bflt.sh
	mkdir -p $(BUILD_DIR) $(INITRAMFS_S41_DIR)
	riscv64-linux-gnu-gcc -march=rv32imac -mabi=ilp32 -fPIC -mno-relax \
	    -msmall-data-limit=0 -nostdlib -no-pie -O2 -fno-builtin -Wall -Wextra \
	    -T $(INITRAMFS_S41_SRC)/init.ld -o $(BUILD_DIR)/init-s4-01.elf $(INITRAMFS_S41_SRC)/init.c
	scripts/pack-bflt.sh $(BUILD_DIR)/init-s4-01.elf $(INITRAMFS_S41_DIR)/init

hello-s4-01: $(HELLO_SRC)/hello.c scripts/pack-bflt.sh
	mkdir -p $(BUILD_DIR)
	riscv64-linux-gnu-gcc -march=rv32imac -mabi=ilp32 -fPIC -mno-relax \
	    -msmall-data-limit=0 -nostdlib -no-pie -O2 -fno-builtin -Wall -Wextra \
	    -T $(INITRAMFS_S41_SRC)/init.ld -o $(BUILD_DIR)/hello-s4-01.elf $(HELLO_SRC)/hello.c
	scripts/pack-bflt.sh $(BUILD_DIR)/hello-s4-01.elf s4/01_exec-hello/hello

rootfs-s4-01: init-s4-01 hello-s4-01 $(GEN_INIT_CPIO) s4/01_exec-hello/initramfs.list
	$(GEN_INIT_CPIO) s4/01_exec-hello/initramfs.list > s4/01_exec-hello/rootfs.cpio
	sha256sum s4/01_exec-hello/rootfs.cpio

# ---- S3-05 /init（NOMMU 只能用 FLAT 格式，手搓 bFLT）----
INITRAMFS_SRC := s3/05_shell/initramfs-src
INITRAMFS_DIR := s3/05_shell/initramfs

init-s3-05: $(INITRAMFS_SRC)/init.c $(INITRAMFS_SRC)/init.ld scripts/pack-bflt.sh
	mkdir -p $(BUILD_DIR) $(INITRAMFS_DIR)
	riscv64-linux-gnu-gcc -march=rv32imac -mabi=ilp32 -fPIC -mno-relax \
	    -msmall-data-limit=0 -nostdlib -no-pie -O2 -fno-builtin -Wall -Wextra \
	    -T $(INITRAMFS_SRC)/init.ld -o $(BUILD_DIR)/init-s3-05.elf $(INITRAMFS_SRC)/init.c
	scripts/pack-bflt.sh $(BUILD_DIR)/init-s3-05.elf $(INITRAMFS_DIR)/init

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

# ---- S3-03（Xh3irq 外设中断）：build-rv32-03 ----
$(KERNEL_SRC)/build-rv32-03/.config: $(CURDIR)/s3/03_irq/rp2350_minimal_defconfig
	mkdir -p $(KERNEL_SRC)/build-rv32-03
	cp $(CURDIR)/s3/03_irq/rp2350_minimal_defconfig $(KERNEL_SRC)/build-rv32-03/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-03 olddefconfig

# 编译内核 Image 并存档到 S3-03 工程（烧录用 make flash-s3-03-kernel）
kernel-s3-03: $(KERNEL_SRC)/build-rv32-03/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-03 -j$$(nproc) Image
	cp $(KERNEL_SRC)/build-rv32-03/arch/riscv/boot/Image s3/03_irq/kernel-Image
	sha256sum s3/03_irq/kernel-Image

# ---- S3-04（真 console 收尾）：build-rv32-04 ----
$(KERNEL_SRC)/build-rv32-04/.config: $(CURDIR)/s3/04_console/rp2350_minimal_defconfig
	mkdir -p $(KERNEL_SRC)/build-rv32-04
	cp $(CURDIR)/s3/04_console/rp2350_minimal_defconfig $(KERNEL_SRC)/build-rv32-04/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-04 olddefconfig

# 编译内核 Image 并存档到 S3-04 工程（烧录用 make flash-s3-04-kernel）
kernel-s3-04: $(KERNEL_SRC)/build-rv32-04/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-04 -j$$(nproc) Image
	cp $(KERNEL_SRC)/build-rv32-04/arch/riscv/boot/Image s3/04_console/kernel-Image
	sha256sum s3/04_console/kernel-Image

# ---- S3-05（进 shell：initramfs 编进内核）：build-rv32-05 ----
$(KERNEL_SRC)/build-rv32-05/.config: $(CURDIR)/s3/05_shell/rp2350_minimal_defconfig
	mkdir -p $(KERNEL_SRC)/build-rv32-05
	cp $(CURDIR)/s3/05_shell/rp2350_minimal_defconfig $(KERNEL_SRC)/build-rv32-05/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-05 olddefconfig

# 编译内核 Image 并存档到 S3-05 工程（initramfs 编在 Image 里，先跑 init-s3-05）
kernel-s3-05: $(KERNEL_SRC)/build-rv32-05/.config init-s3-05
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-05 -j$$(nproc) Image
	cp $(KERNEL_SRC)/build-rv32-05/arch/riscv/boot/Image s3/05_shell/kernel-Image
	@test $$(stat -c %s s3/05_shell/kernel-Image) -le 3145728 || { \
		echo "ERROR: kernel Image 超过分区 0 的 3MB 上限（见 partition_table.json），需要先扩分区"; \
		exit 1; }
	sha256sum s3/05_shell/kernel-Image

# ---- S4-00（bootloader 拷 initramfs，rootfs 独立）：build-rv32-s4-00 ----
$(KERNEL_SRC)/build-rv32-s4-00/.config: $(CURDIR)/s4/00_boot-initramfs/rp2350_minimal_defconfig
	mkdir -p $(KERNEL_SRC)/build-rv32-s4-00
	cp $(CURDIR)/s4/00_boot-initramfs/rp2350_minimal_defconfig $(KERNEL_SRC)/build-rv32-s4-00/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-s4-00 olddefconfig

# 无内置 initramfs 的内核（rootfs 由 bootloader 经 DTB 提供）
kernel-s4-00: $(KERNEL_SRC)/build-rv32-s4-00/.config
	cd $(KERNEL_SRC) && make ARCH=riscv CROSS_COMPILE=$(KERNEL_CROSS) O=build-rv32-s4-00 -j$$(nproc) Image
	cp $(KERNEL_SRC)/build-rv32-s4-00/arch/riscv/boot/Image s4/00_boot-initramfs/kernel-Image
	@test $$(stat -c %s s4/00_boot-initramfs/kernel-Image) -le 3145728 || { \
		echo "ERROR: kernel Image 超过分区 0 的 3MB 上限（见 partition_table.json），需要先扩分区"; \
		exit 1; }
	sha256sum s4/00_boot-initramfs/kernel-Image

# S4-01 无内核改动：kernel-Image 复制自 S4-00
kernel-s4-01: s4/00_boot-initramfs/kernel-Image
	cp s4/00_boot-initramfs/kernel-Image s4/01_exec-hello/kernel-Image
	sha256sum s4/01_exec-hello/kernel-Image

# 兼容旧习惯：flash = 烧 bootloader
flash: flash-bootloader

# ---- 测试 ----
test: flash-psram-test
	@echo "打开串口观察 psram-test 输出（预期 PASS）"

qemu:
	$(QEMU_SCRIPT)

clean:
	rm -rf $(BUILD_DIR)
