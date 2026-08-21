# Repository Guidelines

## Project Structure & Module Organization

- `s1/` — S1 stage: `partition-table/` (bootloader + fake-image + `partition_table.json`), `fixed-offset/` (archived earlier version).
- `s2/` — S2 stage: kernel config fragment (`rv32-nommu.config`), QEMU launcher (`run-qemu.sh`), prebuilt kernel (`kernel-Image`).
- `tests/` — test programs (e.g., `psram-test`).
- `boards/` — custom Pico SDK board headers (`rp2350a_minimal.h`, `waveshare_rp2350b_plus_w.h`).
- `exercises/` — review exercises per completed stage (answers collapsed).
- `notes/` — learning records, reference guides, experiment logs (repo copy is the source of truth).
- Root: `CMakeLists.txt`, `Makefile`, `PLAN.md` (product & run guide), datasheet copies.

## Build, Test, and Development Commands

- `make` — configure and build all Pico SDK targets (bootloader, fake-image, psram-test) for board `rp2350a_minimal`, RISC-V.
- `make flash` — flash the bootloader UF2 (device in BOOTSEL mode).
- `make flash-fake` — flash the fake image into partition 0: `picotool load -fv -p 0 build/fake-image.bin`.
- `./s2/run-qemu.sh` — boot the riscv32 NOMMU kernel in QEMU (uses `s2/kernel-Image`).
- Kernel build: `cd /home/developer/linux-7.2 && make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=build-rv32 ...` (full steps in `notes/环境搭建.md`).

Note: after flashing firmware with an embedded partition table, reboot the device and re-enter BOOTSEL before `picotool -p`.

## Coding Style & Naming Conventions

- C code: 4-space indent, `snake_case` functions and variables, descriptive names; follow pico-sdk conventions.
- Board headers use the SDK's `PICO_*` macro conventions (`PICO_RP2350A`, `PICO_PSRAM_CS_PIN`, ...).
- Kernel config fragments live in `s2/` and contain plain `CONFIG_*` lines.
- Notes, exercises, and comments are written in Chinese (project language).

## Testing Guidelines

- Hardware tests: flash `psram-test` (`make flash TARGET=psram-test`), observe USB/UART logs.
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
