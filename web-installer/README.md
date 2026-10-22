# SightLatch USB installer

Desktop Chrome/Edge; Web Serial over HTTPS or localhost. All dependencies are bundled, with no runtime CDN, analytics or credential upload. The installer identifies the physical chip and requires it to match the selected ESP32 / ESP32-C3 / ESP32-S3 family and reads the SPI Flash ID to require at least 4MB before writing. Unknown Flash size fails closed. This does not establish board-level compatibility, detect every secured device, or replace hardware testing.

```
npm ci
npm test
npm run build
npm run dev
```

`dist/` is the complete static site, including actual compiled firmware and SHA-256 manifest. Do not open `index.html` with file://. Serve over HTTPS, or use localhost for local testing. The CI workflow uploads this directory as an artifact; it does not enable Pages, change repository settings or deploy automatically. A separate manual `Publish USB installer` workflow is provided. The repository owner must first select Settings → Pages → Build and deployment → Source: GitHub Actions, then run that workflow. The verified deployment URL comes from the job output; do not assume the site is live merely because the code was pushed. After owner approval a static host can serve the directory at any subpath (relative assets).

Build the images with `../scripts/build_firmware.sh` from the repository using Arduino CLI 1.3.1, official Arduino-ESP32 3.3.5 and ArduinoJson 7.0.4. Public builds refuse a private config.h. All credentials are set later over local USB, and stored unencrypted in the device NVS. Never commit credentials, serial transcripts or browser form values.

C3 has two builds for different board USB wiring: `usb` enables native C3 USB Serial/JTAG CDC on boot; `uart` uses UART0 for boards with a USB-UART bridge. Neither requires external GPIO connections. Choose the board's actual wiring; flashing detection alone does not determine this. A wrong selection can still flash but won't receive provisioning commands on the selected interface. Reflash the correct variant.

The merged C3 image starts at 0x0, partition table at 0x8000 and app at 0x10000, verified by the packaging script against the Arduino-generated image. This is not the classic ESP32 0x1000 bootloader layout. Full erasure is explicit and removes prior firmware, NVS credentials and BLE bonds. SHA-256 validates downloads and esptool-js verifies written image MD5. No USB device was accessed during development.

Official references checked 2026-10-18:
- https://github.com/espressif/esptool-js
- https://docs.espressif.com/projects/esptool/en/latest/esp32c3/esptool/flashing-firmware.html
- https://docs.espressif.com/projects/esptool/en/latest/esp32c3/advanced-topics/boot-mode-selection.html
- https://github.com/espressif/arduino-esp32/tree/3.3.5

## Additional built targets

The selector also supports classic ESP32 (UART only) and ESP32-S3 (hardware USB Serial/JTAG or UART). Physical chip must match the selected family; changing family disconnects and clears erase consent. S3 requires DIO 80MHz-compatible Flash; OPI-only Flash boards are not supported. All layouts remain 4MB. See [the build-only compatibility matrix](../docs/BOARD_COMPATIBILITY.zh-CN.md). S2 has no BLE and is rejected. Build evidence is not hardware validation.

## 0.2.3 C3 HID 报告注册修复

修复首次开始校准/ARM 时鼠标报告触发的固件 panic：固定 Arduino 3.3.5 NimBLE 对同 UUID 的两个 HID Report 对象注册不完整的问题。保留键盘/鼠标报告格式、配对及控制限制。构建与原始异常的定位说明见 [固件说明](../firmware/README.md)。主机回归与编译验证不代替刷写后的真机校准验收。旧版本镜像保留原链接供比较；当前 manifest 仅提供 0.2.3。

## 0.2.2 连接诊断版

新增连接尝试、接纳、拒绝原因、安全请求结果与编译源码指纹。见 [0.2.2 诊断说明](../docs/FIRMWARE_0.2.2_DIAGNOSTICS.zh-CN.md)。本版保留原有配对与控制门禁，用于定位真实连接流程，不能宣称 HID 配对问题已解决。

## 0.2.1 诊断版

见 [断链诊断与校准安全边界](../docs/FIRMWARE_0.2.1_DIAGNOSTICS.zh-CN.md)。本版未经过真实 iPhone / ESP32 BLE 回归，不能宣称现场掉线已解决。首次安装和更新都写完整 4MiB 镜像，会清除 Wi-Fi、控制令牌与蓝牙绑定，之后必须重新配置。
