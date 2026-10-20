#pragma once
#include <stdint.h>
#include "esp_err.h"
// Standard RFC5054 / ESP Security2 verifier derivation, not a new wire protocol.
// Salt is always exactly 32 bytes, including leading zero bytes.
esp_err_t pairing_verifier(const char *password, const uint8_t salt[32], uint8_t verifier[384]);
