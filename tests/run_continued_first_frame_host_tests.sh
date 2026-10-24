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
source = Path('ios/App/PilotViewModel.swift').read_text()
methods = source.split('    private func startContinuedSessionAfterFirstFrameIfNeeded()', 1)[1].split('    @discardableResult\n    func save()', 1)[0]
methods = ('    private func startContinuedSessionAfterFirstFrameIfNeeded()' + methods).replace('    private func ', '    func ')
stop = '    func stop() async {' + source.split('    func stop() async {', 1)[1].split('    func recoverDamagedSettings()', 1)[0]
end_paused = '    func endPausedSession() async {' + source.split('    func endPausedSession() async {', 1)[1].split('    func manual(', 1)[0]
active = next(line for line in source.splitlines() if 'var isSessionActive: Bool' in line)
fields = '''import Foundation
@MainActor final class PilotViewModel {
var stopping = false, preparing = false, prepared = false
var preparingRequestInFlight = false, controllingDevice = false, sending = false
var continuedStartupTask: Task<Void, Never>?
var continuedStartupID = UUID()
var captureObservation: CaptureObservation?
var taskFlow = TaskPlanningState()
var planningTask: Task<String, Error>?
var automaticCalibration = HostAutomaticCalibration()
var calibrationFlow = HostCalibrationFlow()
var deviceControlID = UUID(), deviceObservationID = UUID(), preparationID = UUID()
var lastDeviceStatus: DeviceStatus?
var deviceStatusCheckedAt: Date?
var deviceSummary = ""
var notice = ""
var status = PilotStatus.idle
func endPointerCalibration() async {}
func recordCalibrationCancellation(source: HostCalibrationCancellationSource, scene: CalibrationCancellationScene) {}
func syncTaskStatus() {}
func syncPlanningState() { taskFlow.observe(sessionID: status.sessionID, phase: status.phase, running: SharedStore.shared.command?.running == true) }
'''
build.joinpath('Host.swift').write_text(fields + active + '\n' + methods + stop + end_paused + '}\n')
ui = Path('tests/message_launch_host_test.swift').read_text().split('@main struct MessageLaunchHostTests', 1)[0]
build.joinpath('UIKit.swift').write_text(ui)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Models.swift" "$BUILD/DeviceStatus.swift" "$BUILD/SharedStore.swift" \
  ios/Shared/TaskPlanning.swift "$BUILD/Host.swift" "$BUILD/UIKit.swift" tests/continued_first_frame_host_test.swift -o "$BUILD/test"
SIGHTLATCH_TEST_STORE="$BUILD/store" "$BUILD/test"
