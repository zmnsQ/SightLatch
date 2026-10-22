#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CLI=${ARDUINO_CLI:-arduino-cli}
source scripts/firmware_build_flags.sh
BLE_LIBRARY=$(python3 scripts/prepare_ble_library.py "$CLI")
[[ ! -f firmware/IPhoneHIDBridge/config.h ]] || { echo 'Remove private config.h before public builds' >&2; exit 1; }
# Preserve the existing C3 source and artifacts. Only expand the target guard in
# the isolated classic ESP32 build input; no runtime or protocol code changes.
python3 scripts/firmware_provenance.py firmware/build/classic-source/IPhoneHIDBridge --classic
"$CLI" compile --jobs 2 --fqbn 'esp32:esp32:esp32:FlashMode=dio,FlashFreq=40,FlashSize=4M,PartitionScheme=huge_app' "${FIRMWARE_BUILD_PROPERTIES[@]}" --library "$BLE_LIBRARY" --build-path "$FIRMWARE_SOURCE_ROOT/firmware/build/compile/esp32-uart" --output-dir firmware/build/esp32-uart firmware/build/classic-source/IPhoneHIDBridge
python3 scripts/firmware_provenance.py firmware/build/s3-source/IPhoneHIDBridge
for mode in usb uart; do
  cdc=cdc; [[ $mode == uart ]] && cdc=default
  "$CLI" compile --jobs 2 --fqbn "esp32:esp32:esp32s3:USBMode=hwcdc,CDCOnBoot=$cdc,FlashMode=dio,FlashSize=4M,PartitionScheme=huge_app,PSRAM=disabled" \
    "${FIRMWARE_BUILD_PROPERTIES[@]}" --library "$BLE_LIBRARY" --build-path "$FIRMWARE_SOURCE_ROOT/firmware/build/compile/s3-$mode" \
    --output-dir "firmware/build/s3-$mode" firmware/build/s3-source/IPhoneHIDBridge
done
python3 scripts/package_extended_firmware.py
python3 scripts/package_application_updates.py
