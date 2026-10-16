# Getting started / 开始使用

## Prerequisites

- iPhone with iOS 26 and a compatible Xcode toolchain on a Mac for signing and installation.
- ESP32-S3 board supported by the firmware guide; verify actual pins and USB wiring for your board.
- An isolated trusted Wi-Fi network and a model API that supports images and the required response format.
- A non-sensitive test screen. Do not start with payments, messages, contacts, or production accounts.

## 1. Configure the iOS targets

Open `ios/HIDPilot.xcodeproj`. Copy `ios/Config/Local.example.xcconfig` to `ios/Config/Local.xcconfig` and configure the signing team and identifiers according to [the iOS guide](../ios/README.md). The app, broadcast extension and widget must agree on shared groups. Local signing configuration is ignored by Git.

Build and install through Xcode. Native compilation is not yet verified by this project; capture the first build error rather than assuming the supplied source is an already-tested binary.

## 2. Prepare the bridge

Follow [the firmware guide](../firmware/README.md). Copy the provided configuration template to the ignored `config.h` and enter Wi-Fi and device-control settings locally. Verify pairing, ARM, STOP and input release before any AI-controlled operation.

Do not publish the local control endpoint. HTTP bearer authentication does not encrypt traffic, and BLE Just Works does not provide man-in-the-middle protection.

## 3. Set up the phone

Select the model provider, endpoint and model name. Store the API key in the app's shared Keychain flow. Review the screenshot-upload notice and explicitly authorize the configured destination. Changing a provider or endpoint invalidates prior upload consent.

Run manual pointer calibration. The system uses relative movement, not injected absolute touch coordinates. Confirm that the capture includes a recognizable pointer; stop if it cannot be located reliably.

## 4. Run one observable step

Prepare a task, start the system broadcast and select **SightLatch Broadcast**. Use conservative mode first. Inspect the proposed action and its visible result, then verify STOP both in the interface and on the bridge. An accepted request is not proof that the bridge stopped; the app reports uncertain stop delivery separately.

## 5. Optional continued processing

The iOS 26 continued-processing path is off by default. Review its separate temporary-frame-storage disclosure before enabling it. It has a bounded session and execution leases; iOS may reject or cancel the task. Live Activities alone do not keep the process alive.

## Updating

Check `git status`, preserve your changes, then use `git pull --ff-only` and rebuild. Keep signing identifiers, shared groups and existing Keychain identifiers stable. Do not commit local configuration or credentials. Internal filenames retain HIDPilot for compatibility with existing projects.
