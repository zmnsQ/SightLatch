# Getting started / 开始使用

For the shortest Chinese walkthrough, use [ESP32-C3 first run](FIRST_RUN.zh-CN.md). The main path here is **ESP32-C3 with at least 4MB Flash and no external GPIO buttons**. Legacy S3 manual builds remain optional and are not the configuration validated by the C3 build checks.

## Prerequisites

- A Mac with Xcode 26 or newer and an iPhone. Deployment minimum is iOS 18; the full Liquid Glass UI needs iOS 26.
- An Apple signing account supporting the required App Groups / shared Keychain capabilities. A free Personal Team may not qualify.
- A C3 board, USB data cable, desktop Chrome/Edge, and knowledge of whether the board uses native USB Serial/JTAG or a USB-UART bridge.
- A trusted isolated LAN; the board needs 2.4GHz Wi-Fi. Use a non-sensitive test screen.
- An image-capable API account or the experimental ChatGPT plan sign-in path. There is no silent fallback between billing paths.

## 1. Install the iOS app

Open `ios/SightLatch.xcodeproj`, select the **SightLatch** scheme and the same Development Team on **SightLatch**, **SightLatchBroadcast** and **SightLatchWidget**. Keep automatic signing enabled, select your iPhone and Run. No copied local config or project generator is needed. Preserve existing local signing overrides when updating an existing installation.

After updating an older checkout, close the old project window and open `ios/SightLatch.xcodeproj` with the **SightLatch** scheme. Do not copy or reset `Local.xcconfig`; existing bundle IDs and shared groups are preserved.

Apple SDK compilation, signing and device execution remain unverified. Capture the first build error; do not delete shared entitlements to bypass it.

## 2. Open the installer and flash C3

GitHub Pages is not enabled yet and there is no verified live installer URL. Pushing code does not deploy it. The owner can select **Settings → Pages → Build and deployment → Source: GitHub Actions**, then run **Actions → Publish USB installer (manual)** and use the successful job's deployment URL.

Alternatively, from the repository run `cd web-installer`, `npm ci`, then `npm run dev`; open the localhost address printed by the terminal in Chrome/Edge. Node.js/npm are required for this local route. The repository includes prebuilt C3 images; no Arduino build or private `config.h` is needed. Do not use `file://`.

Follow the [C3 guide](ESP32_C3_SETUP.zh-CN.md): select the correct USB variant, verify chip and Flash size, explicitly confirm full erasure, and install. Erasure removes old firmware, credentials and BLE bonds. Reset/reconnect, provision Wi-Fi and a random device token over USB, and read the device IP.

## 3. Pair and calibrate

Open the app's device settings from the device-status row. Enter the device HTTP IP and the same token, check status, then tap **开始蓝牙配对**. Pair **SightLatch** through the iPhone's AssistiveTouch Bluetooth-device settings during the 30-second window. Pairing does not authorize control.

For manual calibration, tap **允许控制5分钟（用于手动校准）**, then open **More → 指针校准**. Test one movement on a safe screen and verify **停止控制**. If stop delivery is uncertain, unplug USB power and end the system broadcast. This C3 setup has no external STOP button.

USB supplies power; commands travel over Wi-Fi HTTP, and the board sends BLE HID input. HTTP is plaintext and BLE Just Works does not prevent man-in-the-middle attacks. Do not expose the endpoint to the internet.

## 4. Configure a model and run a small task

Use **More → 连接与模型** to configure a supported API or [experimental ChatGPT plan sign-in](CHATGPT_PLAN_LOGIN.zh-CN.md). Explicitly consent to sending screenshots and task text to the selected service. Keep low-risk click/type and optional continued-processing settings off for the first test.

Enter a short goal in chat and tap **开始接管**. This explicit action requests control if needed; existing authorization is not renewed. Start **SightLatch Broadcast** through the system broadcast button, then return to the safe target app. Expand **执行过程** in chat to inspect real operation summaries.

Stop through the app and also end the system broadcast before opening sensitive pages. Authorization expires within five minutes and is revoked on disconnection or restart. Background execution and pointer visibility still need hardware validation; Live Activities do not keep the process alive.

## Legacy S3 and updating

Only if deliberately using an S3 physical-button build, follow [the firmware guide](../firmware/README.md) for local `config.h`, pin verification and manual compilation. Do not flash the C3 image to it. This is separate from the zero-GPIO C3 path.

Before updating, inspect `git status`, preserve local changes, then use `git pull --ff-only`. Keep existing signing/shared-container identifiers stable and never commit credentials.
