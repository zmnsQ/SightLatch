#pragma once
// Copy to config.h locally. Never commit real Wi-Fi credentials or the token.
#define WIFI_SSID "YOUR_2_4_GHZ_WIFI"
#define WIFI_PASSWORD "YOUR_WIFI_PASSWORD"
// Replace with at least 32 unpredictable ASCII characters; same value in iOS.
#define CONTROL_TOKEN "REPLACE_WITH_RANDOM_TOKEN_AT_LEAST_32_CHARS"
#define BLE_DEVICE_NAME "LocalHID"
// Wire external normally-open buttons from these free GPIOs to GND.
// CHECK YOUR BOARD PINOUT. Do not silently reuse BOOT/strapping/flash pins.
#define STOP_GPIO 4
#define ARM_GPIO 5
#define PAIR_WINDOW_MS 30000UL
#define ARM_LEASE_MS 300000UL

