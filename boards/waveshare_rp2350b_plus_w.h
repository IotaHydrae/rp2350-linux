/*
 * Custom Pico SDK board header for Waveshare RP2350B-Plus-W.
 *
 * RP2350B package (QFN80, 48 GPIO), 16MB flash, 8MB PSRAM (APS6404)
 * on QMI CS1 = GPIO47. WiFi module present but unused for now.
 */
#ifndef _BOARDS_WAVESHARE_RP2350B_PLUS_W_H
#define _BOARDS_WAVESHARE_RP2350B_PLUS_W_H

// For board detection
#define WAVESHARE_RP2350B_PLUS_W

pico_board_cmake_set(PICO_PLATFORM, rp2350)

// --- PACKAGE ---
// 0 = RP2350B (48 GPIO), 1 = RP2350A (30 GPIO)
#define PICO_RP2350A 0

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

// --- PSRAM: QMI CS1 = GPIO47, 8MB ---
#ifndef PICO_PSRAM_CS_PIN
#define PICO_PSRAM_CS_PIN 47
#endif
pico_board_cmake_set_default(PICO_PSRAM_SIZE_BYTES, (8 * 1024 * 1024))
#ifndef PICO_PSRAM_SIZE_BYTES
#define PICO_PSRAM_SIZE_BYTES (8 * 1024 * 1024)
#endif

// Verify PSRAM is really there by reading its ID at init
#ifndef PICO_AUTO_DETECT_PSRAM_SIZE
#define PICO_AUTO_DETECT_PSRAM_SIZE 1
#endif

#endif
