# SightLatch USB installer

Desktop Chrome/Edge; Web Serial over HTTPS or localhost. All dependencies are bundled, with no runtime CDN, analytics or credential upload. The installer identifies the physical chip as ESP32-C3 and reads the SPI Flash ID to require at least 4MB before writing. Unknown Flash size fails closed. This does not establish board-level compatibility, detect every secured device, or replace hardware testing.

```
npm ci
npm test
npm run build
npm run dev
```

`dist/` is the complete static site, including actual compiled firmware and SHA-256 manifest. Do not open `index.html` with file://. Serve over HTTPS, or use localhost for local testing. The CI workflow uploads this directory as an artifact; it does not enable Pages, change repository settings or deploy automatically. A separate manual `Publish USB installer` workflow is provided. The repository owner must first select Settings → Pages → Build and deployment → Source: GitHub Actions, then run that workflow. The verified deployment URL comes from the job output; do not assume the site is live merely because the code was pushed. After owner approval a static host can serve the directory at any subpath (relative assets).

Build the images with `../scripts/build_firmware.sh` from the repository using Arduino CLI 1.3.1, official Arduino-ESP32 3.3.5 and ArduinoJson 7.0.4. Public builds refuse a private config.h. All credentials are set later over local USB, and stored unencrypted in the device NVS. Never commit credentials, serial transcripts or browser form values.

Two builds support different board USB wiring: `usb` enables native C3 USB Serial/JTAG CDC on boot; `uart` uses UART0 for boards with a USB-UART bridge. Neither requires external GPIO connections. Choose the board's actual wiring; flashing detection alone does not determine this. A wrong selection can still flash but won't receive provisioning commands on the selected interface. Reflash the correct variant.

The merged C3 image starts at 0x0, partition table at 0x8000 and app at 0x10000, verified by the packaging script against the Arduino-generated image. This is not the classic ESP32 0x1000 bootloader layout. Full erasure is explicit and removes prior firmware, NVS credentials and BLE bonds. SHA-256 validates downloads and esptool-js verifies written image MD5. No USB device was accessed during development.

Official references checked 2026-10-18:
- https://github.com/espressif/esptool-js
- https://docs.espressif.com/projects/esptool/en/latest/esp32c3/esptool/flashing-firmware.html
- https://docs.espressif.com/projects/esptool/en/latest/esp32c3/advanced-topics/boot-mode-selection.html
- https://github.com/espressif/arduino-esp32/tree/3.3.5
