#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CLI=${ARDUINO_CLI:-arduino-cli}
# Public artifacts must never incorporate a developer's private config.h.
if [[ -f firmware/IPhoneHIDBridge/config.h ]]; then
  echo 'Refusing public build: remove private config.h from this checkout first.' >&2; exit 1
fi
for mode in usb uart; do
  cdc=cdc; [[ $mode == uart ]] && cdc=default
  "$CLI" compile --jobs 2 --fqbn "esp32:esp32:esp32c3:CDCOnBoot=$cdc,FlashMode=dio,FlashFreq=40,FlashSize=4M,PartitionScheme=huge_app" \
    --output-dir "firmware/build/$mode" firmware/IPhoneHIDBridge
 done
python3 scripts/package_firmware.py
