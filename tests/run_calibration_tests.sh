#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 tests/calibration_test_support.py "$BUILD"
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/DeviceStatus.swift" "$BUILD/SharedStore.swift" ios/Shared/TaskPlanning.swift ios/Shared/PointerCalibration.swift ios/App/PilotPointerCalibration.swift tests/pointer_calibration_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"
