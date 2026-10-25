#pragma once
#include <ArduinoJson.h>
#include <cstring>
#include <stdint.h>
namespace hidpilot {
static constexpr uint32_t ABSOLUTE_SETTLE_MS=350, ABSOLUTE_HOLD_MS=40;
static constexpr uint32_t ABSOLUTE_CLICK_REQUIRED_MS=800;
inline bool absoluteActionKeysAllowed(JsonObjectConst request) {
  for(JsonPairConst pair:request) {
    const char *key=pair.key().c_str();
    if(strcmp(key,"type")&&strcmp(key,"id")&&strcmp(key,"boot_id")&&
       strcmp(key,"session_id")&&strcmp(key,"sequence")&&strcmp(key,"issued_at_ms")&&strcmp(key,"ttl_ms")&&
       strcmp(key,"control_epoch")&&strcmp(key,"hid_generation")&&strcmp(key,"hid_x")&&strcmp(key,"hid_y"))return false;
  }
  return true;
}
}
