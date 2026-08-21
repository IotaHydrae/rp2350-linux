/*
 * Custom Pico SDK board header for the self-made "RP2350A-Minimal" board.
 *
 * RP2350A package (30 GPIO), 16MB flash, 8MB PSRAM (APS6404)
 * on QMI CS1 = GPIO0. UART0 GP16/17 as the debug console.
 */
#ifndef _BOARDS_RP2350A_MINIMAL_H
#define _BOARDS_RP2350A_MINIMAL_H

// For board detection
#define RP2350A_MINIMAL

pico_board_cmake_set(PICO_PLATFORM, rp2350)

// --- PACKAGE ---
// 1 = RP2350A (30 GPIO), 0 = RP2350B (48 GPIO)
#define PICO_RP2350A 1

// --- FLASH ---
#define PICO_BOOT_STAGE2_CHOOSE_W25Q080 1
#ifndef PICO_FLASH_SPI_CLKDIV
#define PICO_FLASH_SPI_CLKDIV 2
#endif
pico_board_cmake_set_default(PICO_FLASH_SIZE_BYTES, (16 * 1024 * 1024))
#ifndef PICO_FLASH_SIZE_BYTES
#define PICO_FLASH_SIZE_BYTES (16 * 1024 * 1024)
#endif

// --- UART (console: UART0 on GP16/17, 115200) ---
#ifndef PICO_DEFAULT_UART
#define PICO_DEFAULT_UART 0
#endif
#ifndef PICO_DEFAULT_UART_TX_PIN
#define PICO_DEFAULT_UART_TX_PIN 16
#endif
#ifndef PICO_DEFAULT_UART_RX_PIN
#define PICO_DEFAULT_UART_RX_PIN 17
#endif

// --- PSRAM: QMI CS1 = GPIO0, 8MB ---
#ifndef PICO_PSRAM_CS_PIN
#define PICO_PSRAM_CS_PIN 0
#endif
pico_board_cmake_set_default(PICO_PSRAM_SIZE_BYTES, (8 * 1024 * 1024))
#ifndef PICO_PSRAM_SIZE_BYTES
#define PICO_PSRAM_SIZE_BYTES (8 * 1024 * 1024)
#endif

// Verify PSRAM presence by reading its ID at init
#ifndef PICO_AUTO_DETECT_PSRAM_SIZE
#define PICO_AUTO_DETECT_PSRAM_SIZE 1
#endif

#endif
