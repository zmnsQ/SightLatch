#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CLI=${ARDUINO_CLI:-arduino-cli}
[[ ! -f firmware/IPhoneHIDBridge/config.h ]] || { echo 'Remove private config.h before public builds' >&2; exit 1; }
# Preserve the existing C3 source and artifacts. Only expand the target guard in
# the isolated classic ESP32 build input; no runtime or protocol code changes.
rm -rf firmware/build/classic-source
mkdir -p firmware/build/classic-source/IPhoneHIDBridge
cp firmware/IPhoneHIDBridge/* firmware/build/classic-source/IPhoneHIDBridge/
python3 - <<'PY'
from pathlib import Path
p=Path('firmware/build/classic-source/IPhoneHIDBridge/Bridge.cpp')
s=p.read_text(); old='!defined(CONFIG_IDF_TARGET_ESP32S3) && !defined(CONFIG_IDF_TARGET_ESP32C3)'
assert s.count(old)==1
p.write_text(s.replace(old, '!defined(CONFIG_IDF_TARGET_ESP32) && '+old))
PY
"$CLI" compile --jobs 2 --fqbn 'esp32:esp32:esp32:FlashMode=dio,FlashFreq=40,FlashSize=4M,PartitionScheme=huge_app' --output-dir firmware/build/esp32-uart firmware/build/classic-source/IPhoneHIDBridge
for mode in usb uart; do
  cdc=cdc; [[ $mode == uart ]] && cdc=default
  "$CLI" compile --jobs 2 --fqbn "esp32:esp32:esp32s3:USBMode=hwcdc,CDCOnBoot=$cdc,FlashMode=dio,FlashSize=4M,PartitionScheme=huge_app,PSRAM=disabled" \
    --output-dir "firmware/build/s3-$mode" firmware/IPhoneHIDBridge
done
python3 scripts/package_extended_firmware.py
