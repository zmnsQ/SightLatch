#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$BUILD/Production.swift" <<'PY'
from pathlib import Path
import sys
models = Path('ios/Shared/Models.swift').read_text()
config = models[models.index('struct PointerCalibrationContext:'):models.index('struct PilotStatus:')]
config += models[models.index('struct ActionProposal:'):models.index('struct LogEntry:')]
config += models[models.index('enum PilotError:'):models.index('struct SharedFrame:')]
frames = models[models.index('struct SharedFrame:'):models.index('/// Contains no screenshot')]
sample = Path('ios/Broadcast/SampleHandler.swift').read_text()
sample_guards = sample[sample.index('    private func frameIsStable('):sample.index('    private func pause(')]
continued = Path('ios/App/ContinuedSession.swift').read_text()
continued_guards = continued[continued.index('    nonisolated private static func frameObservationFailure('):continued.index('    @available(iOS 26.0, *)\n    private func publish(')]
# Integration uses these real guards only for pointer moves/clicks, including
# HardwareClient's final pre-POST closure. No other authorization is replaced.
assert 'let pointerGeometry = [.move, .click].contains(proposal.type) ? geometry : nil' in sample
assert sample.count('deadline: deadline, geometry: pointerGeometry') == 2
assert 'try pointerGeometry.pointerMapping(calibration: configuration).get()' in sample
assert 'let requiresPointerGeometry = [.move, .click].contains(proposal.type)' in continued
assert continued.count('deadline: deadline, requiresPointerGeometry: requiresPointerGeometry') == 2
assert 'try geometry.pointerMapping(calibration: configuration).get()' in continued
fixture = '''
final class SampleGeometryFixture {
    private let queue = DispatchQueue(label: "geometry.fixture")
    private let store = SharedStore.shared
    private let sessionID = "fixture"
    private var latestFingerprint = [UInt8](repeating: 255, count: 4096)
    private var latestObservedAt = Date()
    private var latestGeometry: CaptureGeometry?
    func check(decision: CaptureGeometry, latest: CaptureGeometry?, requiresGeometry: Bool = true) -> String? {
        queue.sync {
            latestObservedAt = Date(); latestGeometry = latest
            return frameObservationFailure(comparedTo: latestFingerprint, deadline: Date().addingTimeInterval(10),
                geometry: requiresGeometry ? decision : nil)
        }
    }
    func checkSignal(prior: [UInt8], latest: [UInt8], age: TimeInterval, remaining: TimeInterval = 10) -> String? {
        queue.sync {
            latestFingerprint = latest; latestObservedAt = Date().addingTimeInterval(-age); latestGeometry = nil
            return frameObservationFailure(comparedTo: prior, deadline: Date().addingTimeInterval(remaining))
        }
    }
''' + sample_guards + '''
}
final class SharedStore {
    static let shared = SharedStore()
    var latest: SharedFrame?
    var diagnostics: [String] = []
    func read<T>(_ name: String, as type: T.Type) -> T? { latest as? T }
    func log(_ message: String, sessionID: String?) { diagnostics.append(message) }
}
final class ContinuedGeometryFixture {
    static func check(frame: SharedFrame, requiresGeometry: Bool = true) -> String? {
        frameObservationFailure(frame: frame, deadline: Date().addingTimeInterval(10), requiresPointerGeometry: requiresGeometry)
    }
''' + continued_guards + '\n}\n'
Path(sys.argv[1]).write_text('import Foundation\n' + config + frames + fixture)
PY
"${SWIFTC:-swiftc}" -module-cache-path "$BUILD/cache" "$BUILD/Production.swift" ios/Shared/AgentSession.swift tests/capture_geometry_test.swift -o "$BUILD/test"
"$BUILD/test"
