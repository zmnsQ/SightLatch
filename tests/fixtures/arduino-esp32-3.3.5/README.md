`BLEService.cpp` is an unmodified test fixture from Espressif's Arduino-ESP32 3.3.5
[official source](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLEService.cpp).
Its original copyright comments are retained. It is used only to compile the actual
registration function before and after the reviewed compatibility patch, including
on CI hosts without an installed Arduino toolchain. The production build always
copies the installed official library and checks the same upstream SHA-256.
