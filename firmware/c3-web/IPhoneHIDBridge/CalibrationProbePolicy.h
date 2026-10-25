#pragma once
#include <ArduinoJson.h>
#include <cstring>
namespace hidpilot {
// The action envelope is validated by actionHandler; this prevents an extra
// control parameter from silently converting a calibration probe into input.
inline bool calibrationProbeKeysAllowed(JsonObjectConst request) {
  for(JsonPairConst pair:request) {
    const char *key=pair.key().c_str();
    if(strcmp(key,"type")&&strcmp(key,"id")&&strcmp(key,"boot_id")&&
       strcmp(key,"session_id")&&strcmp(key,"sequence")&&strcmp(key,"issued_at_ms")&&strcmp(key,"ttl_ms"))return false;
  }
  return true;
}
}
