#include "../firmware/IPhoneHIDBridge/ProtocolPrimitives.h"
#include <cassert>
#include <iostream>
int main() {
  uint8_t key, mods;
  for (int c = 0; c < 256; ++c) {
    const bool accepted = hidpilot::asciiKey(static_cast<char>(c), key, mods);
    assert(accepted == (c >= 32 && c <= 126));
    if (accepted) { assert(key >= 4 && key <= 56); assert(mods == 0 || mods == 2); }
  }
  assert(hidpilot::asciiKey('a', key, mods) && key == 4 && mods == 0);
  assert(hidpilot::asciiKey('A', key, mods) && key == 4 && mods == 2);
  assert(hidpilot::asciiKey('0', key, mods) && key == 39 && mods == 0);
  assert(hidpilot::asciiKey('!', key, mods) && key == 30 && mods == 2);
  assert(hidpilot::asciiKey('~', key, mods) && key == 53 && mods == 2);
  assert(hidpilot::asciiKey(' ', key, mods) && key == 44 && mods == 0);
  assert(hidpilot::timeBefore(100, 101));
  assert(!hidpilot::timeBefore(100, 100));
  assert(!hidpilot::timeBefore(101, 100));
  assert(hidpilot::timeBefore(0xfffffff0u, 20));
  assert(!hidpilot::timeBefore(20, 0xfffffff0u));
  std::cout << "PASS: all 256 input bytes, ASCII mappings, deadline and millis wraparound\n";
}
