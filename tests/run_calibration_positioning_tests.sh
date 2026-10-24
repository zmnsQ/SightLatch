#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 tests/calibration_test_support.py "$BUILD"
python3 - "$BUILD" <<'PY'
from pathlib import Path
import sys
build = Path(sys.argv[1])
s = Path('tests/pointer_calibration_test.swift').read_text().split('@main struct CalibrationTests', 1)[0]
s = s.replace('    static var failStop = false', '    static var failStop = false\n    static var onStop: (() throws -> Void)?\n    static var pointer = CalibrationPoint(x: 150, y: 120)\n    static var commands: [(Int, Int)] = []')
s = s.replace('        Self.calls.append("stop")', '        Self.calls.append("stop")\n        try Self.onStop?()')
s = s.replace('        if Self.device.pointer_position_known != nil', '        Self.commands.append((proposal.dx ?? 0, proposal.dy ?? 0))\n        Self.pointer.x += Double(proposal.dx ?? 0) * (420.0 * 40 / 10000)\n        Self.pointer.y += Double(proposal.dy ?? 0) * (912.0 * 40 / 10000)\n        if Self.device.pointer_position_known != nil')
s = s.replace('    var taskFlow = TaskPlanningState()', '    var taskFlow = TaskPlanningState()\n    var calibrationCanvasContext: PointerCalibrationContext?\n    var calibrationCanvasWidth = 0.0, calibrationCanvasHeight = 0.0\n    var calibrationObservation: CalibrationObservation?')
(build / 'Mocks.swift').write_text(s)
production = Path('ios/App/PilotAutomaticCalibration.swift').read_text().replace('import UIKit\n', '')
(build / 'PilotAutomaticCalibration.swift').write_text(production)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/DeviceStatus.swift" "$BUILD/SharedStore.swift" "$BUILD/Mocks.swift" ios/Shared/TaskPlanning.swift ios/Shared/PointerCalibration.swift ios/Shared/AutomaticCalibration.swift ios/App/PilotPointerCalibration.swift "$BUILD/PilotAutomaticCalibration.swift" tests/calibration_positioning_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"
