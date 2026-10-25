#pragma once
#include <esp_mac.h>
#include <mbedtls/sha256.h>
#include <NimBLEDevice.h>
#include <cstring>

// Stable per-chip static-random BLE identity. No developer address, NVS write,
// credential, eFuse change or random-at-every-boot identity is used.
inline bool configurePublicIdentity() {
  static const char domain[] = "SightLatch-C3-public-BLE-v1";
  uint8_t chip[6], seed[sizeof(domain) - 1 + sizeof(chip)], digest[32], address[6];
  if (esp_efuse_mac_get_default(chip) != ESP_OK) return false;
  memcpy(seed, domain, sizeof(domain) - 1);
  memcpy(seed + sizeof(domain) - 1, chip, sizeof(chip));
  if (mbedtls_sha256(seed, sizeof(seed), digest, 0) != 0) return false;
  memcpy(address, digest, sizeof(address));
  address[5] |= 0xC0; // NimBLE stores the most significant address byte last.
  address[0] = (address[0] & 0xFC) | 0x01; // neither all-zero nor all-one random bits.
  return NimBLEDevice::setOwnAddr(address) && NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);
}
