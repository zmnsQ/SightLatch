#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Production.swift" <<'PY'
from pathlib import Path
import sys
source = Path('ios/Broadcast/SampleHandler.swift').read_text()
callbacks = source[source.index('    override func broadcastPaused()'):source.index('    override func broadcastFinished()')]
callbacks = callbacks.replace('override func', 'func')
pause = source[source.index('    private func pause('):source.index('    private func publish(')]
pause = pause.replace('private func', 'func')
fixture = '''import Foundation
struct PauseStatus { var phase: String; var detail: String; var sessionID = "session" }
struct PauseConfig { var continuedProcessingEnabled: Bool? = false }
final class PauseStore {
    var status = PauseStatus(phase: "观察", detail: "等待画面")
    func log(_ message: String, sessionID: String?) {}
}
final class PauseWork {
    private(set) var cancellations = 0
    func cancel() { cancellations += 1 }
}
struct PauseObservation { mutating func reset() {} }
final class PauseFixture {
    let queue = DispatchQueue(label: "pause.fixture")
    var work: PauseWork? = PauseWork()
    var stopped = false
    var paused = false
    var config = PauseConfig()
    let store = PauseStore()
    let sessionID = "session"
    var postActionObservation = PauseObservation()
    var captureState = "capturing"
    var hardwareStops = 0
    var finishReason: String?
    var finishPhase: String?
    func publishCaptureState(_ state: String) { captureState = state }
    func stopHardware() { hardwareStops += 1 }
    func publish(_ phase: String, _ detail: String) { store.status = PauseStatus(phase: phase, detail: detail) }
    func stopAndFinish(_ reason: String, phase: String = "停止") {
        finishReason = reason; finishPhase = phase; stopped = true; work?.cancel()
        publish(phase, reason); stopHardware()
    }
    func drain() { queue.sync {} }
''' + callbacks + pause + '\n}\n'
Path(sys.argv[1]).write_text(fixture)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Production.swift" tests/broadcast_pause_test.swift -o "$BUILD/test"
"$BUILD/test"
