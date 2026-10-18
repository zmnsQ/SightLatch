#!/usr/bin/env python3
"""Queue contract + Swift 6 compilation/runtime test of the production STOP helper.
Not an Apple SDK/ReplayKit build; the unsigned iOS CI remains required.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'ios/Broadcast/SampleHandler.swift').read_text()
assert 'final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable' in source
assert 'Task { await HardwareClient(configuration: self.config)' not in source
assert 'Task { await HardwareClient(configuration: config)' not in source
assert '_ = try? store.updateCommand(sessionID: sessionID)' in source
frame_handoff = source.split('guard observe else { return }', 1)[1].split('let oriented =', 1)[0]
assert 'queue.sync {' in frame_handoff
assert 'queue.async {' not in frame_handoff
for mutation in ['self.pause("\\(reason)。', 'self.stopAndFinish("AI 认为任务完成',
                 'self.publish("观察", "本轮未执行', 'self.pause(error.localizedDescription)\n                        }']:
    position = source.index(mutation)
    assert 'self.generation == capturedGeneration' in source[position-150:position], mutation
# Every queue-only helper must enforce its isolation at runtime.
helpers = source.split('    private func ')[1:]
for helper in helpers:
    first_statement = helper.split('{', 1)[1].lstrip().splitlines()[0]
    assert first_statement == 'dispatchPrecondition(condition: .onQueue(queue))', helper.splitlines()[0]
helper = '    private func stopHardware() {' + source.split('    private func stopHardware() {', 1)[1].split('    private func stopAndFinish(', 1)[0]
fixture = '''import Foundation
struct PilotConfiguration: Sendable { var endpoint = "" }
actor Recorder {
    static let shared = Recorder()
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
struct HardwareClient: Sendable {
    let configuration: PilotConfiguration
    func stop() async { await Recorder.shared.append(configuration.endpoint) }
}
final class CaptureFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.capture")
    private var config = PilotConfiguration()
    func exercise() {
        queue.sync {
            for index in 0..<100 {
                config.endpoint = "original-\\(index)"
                stopHardware()
                config.endpoint = "replacement"
            }
        }
    }
''' + helper + '''
}
@main struct Test {
    static func main() async throws {
        let capture = CaptureFixture()
        capture.exercise()
        let deadline = Date().addingTimeInterval(5)
        while await Recorder.shared.values.count < 100 && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let results = await Recorder.shared.values
        precondition(results.count == 100)
        precondition(Set(results) == Set((0..<100).map { "original-\\($0)" }))
        print("PASS: production STOP helper preserves 100 queue-owned configuration snapshots; Swift 6 complete concurrency checking")
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path / 'Test.swift').write_text(fixture)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6',
                    '-strict-concurrency=complete', '-warnings-as-errors', '-parse-as-library',
                    '-module-cache-path', str(path / 'cache'),
                    str(path / 'Test.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, timeout=10)
