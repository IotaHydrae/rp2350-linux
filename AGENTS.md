# Repository Guidelines

## Project Structure & Module Organization

- `s1/` — S1 stage: `partition-table/` (bootloader + fake-image + `partition_table.json`), `fixed-offset/` (archived earlier version).
- `s2/` — S2 stage: kernel config fragment (`rv32-nommu.config`), QEMU launcher (`run-qemu.sh`), prebuilt kernel (`kernel-Image`).
- `s3/00_amowall/` — S3-00 stage (minimal-DTB real-board boot that hit and located the PSRAM AMO wall): bootloader + `dts/` (SoC/board split) + `partition_table.json` + `README.md` + `kernel-Image`.
- `s3/01_earlycon/` — S3-01 stage (AMO/amocas emulation crossed the wall; earlycon output + `init_IRQ` panic achieved): same layout as `00_amowall`.
- `s3/02_timer/` — S3-02 stage (cpu-intc + timer-rp2350; jiffies run on real board): same layout.
- `s3/03_irq/` — S3-03 stage (Xh3irq external-interrupt controller; `arm,sbsa-uart` console): same layout.
- `s3/04_console/` — S3-04 stage (console handover: explicit `console=ttyAMA0` + CONFIG_VT restore test): same layout.
- `s3/05_shell/` — S3-05 stage (initramfs baked into Image + hand-rolled bFLT `/init` shell): same layout, plus `initramfs.list` (gen_init_cpio manifest), `initramfs-src/` (init.c + init.ld), `initramfs/` (packed bFLT, built by `make init-s3-05`).
- `s4/00_boot-initramfs/` — S4-00 stage (rootfs as a separate flash partition: bootloader copies initramfs to a fixed RAM address, DTB declares `linux,initrd-start/end`, kernel has no baked-in initramfs). Same layout, plus `rootfs.cpio` (built by `make rootfs-s4-00`, flashed by `make flash-s4-00-rootfs`).
- `s4/01_exec-hello/` — S4-01 stage (shell runs an external program: vfork + execve `/bin/hello`, first NOMMU process creation). Same layout, plus `hello-src/` (hello.c) and `hello` (packed bFLT, built by `make hello-s4-01`).
- Rule for S3+ stages: each stage folder keeps its own README, kernel image copy, and complete defconfig so it can be reproduced standalone. New stages must add a sibling folder plus root `CMakeLists.txt` `add_subdirectory` and Makefile `kernel-s3-0x` / `flash-s3-0x-*` targets.
- `tests/` — test programs (e.g., `psram-test`).
- `boards/` — custom Pico SDK board headers (`rp2350a_minimal.h`, `waveshare_rp2350b_plus_w.h`).
- `udev/` — udev rules so picotool/serial need no root (`99-rp2350.rules`, install with `sudo cp` + `udevadm reload`).
- `exercises/` — review exercises per completed stage (answers collapsed).
- `notes/` — learning records, reference guides, experiment logs (repo copy is the source of truth).
- Root: `CMakeLists.txt`, `Makefile`, `PLAN.md` (product & run guide), datasheet copies.

## Build, Test, and Development Commands

- `make` — configure and build all Pico SDK targets (bootloader, fake-image, psram-test) for board `rp2350a_minimal`, RISC-V.
- `make flash-bootloader` (alias `make flash`) — flash the bootloader UF2 (device in BOOTSEL mode).
- `make flash-fake` — flash the fake image into partition 0: `picotool load -fv -p 0 build/s1/fake-image.bin`.
- `make flash-psram-test` / `make test` — flash and run the PSRAM self-test.
- `make qemu` — boot the riscv32 NOMMU kernel in QEMU via `s2/run-qemu.sh`.
- Kernel build: `cd /home/developer/linux-7.2 && make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 ...` (full steps in `notes/环境搭建.md`).

Note: after flashing firmware with an embedded partition table, reboot the device and re-enter BOOTSEL before `picotool -p`.

## Coding Style & Naming Conventions

- C code: 4-space indent, `snake_case` functions and variables, descriptive names; follow pico-sdk conventions.
- Board headers use the SDK's `PICO_*` macro conventions (`PICO_RP2350A`, `PICO_PSRAM_CS_PIN`, ...).
- Kernel config fragments live in `s2/` (QEMU) and contain plain `CONFIG_*` lines; real-board stages (S3+) use a **complete defconfig** per stage, kept **project-local only** (e.g. `s3/00_amowall/rp2350_amowall_defconfig`, `s3/01_earlycon/rp2350_minimal_defconfig`) — the Makefile seeds the build dir's `.config` from it and runs `olddefconfig` (`make kernel-s3-00` / `make kernel-s3-01`). No merge_config fragments, no new kernel-tree configs.
- Notes, exercises, and comments are written in Chinese (project language).

## Testing Guidelines

- Hardware tests: flash `psram-test` (`make flash-psram-test`), observe USB/UART logs.
- Kernel tests: `./s2/run-qemu.sh`; earlycon output is the primary check — a rootfs panic is an expected checkpoint until S4.
- Record observed logs under `notes/实验日志/` after each run.

## Commit & PR Guidelines

- Commit by feature/functionality (user convention), with conventional prefixes seen in history: `feat:`, `fix:`, `docs:`, `refactor:`.
- Hardware-related changes should reference observed logs/phenomena.
- PRs: describe what changed and why; include logs or screenshots where the change is only verifiable on hardware.

## Agent-Specific Instructions

- This repo follows the build-to-learn workflow: read `notes/学习地图.md` first (AI continuation map), then `PLAN.md`; keep both updated when plans change.
- Keep the workspace organized: stage work under `sN/`, tests under `tests/`, build artifacts gitignored (`build/`, `build-rv32/`).
- User convention: when requirements or project structure change, update this `AGENTS.md`.
