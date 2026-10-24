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
for mutation in ['self.pause("本轮未执行动作。\\(reason)', 'self.stopAndFinish(messageContext == nil ? "AI 认为任务完成',
                 'self.publish("观察", "本轮未执行', 'self.pause(stopReason)']:
    position = source.index(mutation)
    assert 'self.generation == capturedGeneration' in source[position-250:position], mutation
# Every queue-only helper must enforce its isolation at runtime.
helpers = source.split('    private func ')[1:]
for helper in helpers:
    first_statement = helper.split('{', 1)[1].lstrip().splitlines()[0]
    assert first_statement == 'dispatchPrecondition(condition: .onQueue(queue))', helper.splitlines()[0]
helper = '    private func stopHardware() {' + source.split('    private func stopHardware() {', 1)[1].split('    private func ownsCaptureCommand(', 1)[0]
fixture = '''import Foundation
struct PilotConfiguration: Sendable { var endpoint = "" }
actor Recorder {
    static let shared = Recorder()
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
struct HardwareClient: Sendable {
    let configuration: PilotConfiguration
    func stopAndVerify(expectedSessionID: String?, captureOwnerID: String?) async throws { await Recorder.shared.append(configuration.endpoint) }
}
struct SharedStore: Sendable {
    static let shared = SharedStore()
    func log(_ message: String, sessionID: String) {}
}
final class CaptureFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.capture")
    private var config = PilotConfiguration()
    private let sessionID = "session", captureOwnerID = "owner"
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

# Exercise the production capture-owner policy without ReplayKit or real input.
models = (root / 'ios/Shared/Models.swift').read_text()
execution = models.split('struct ContinuedExecution: Codable {', 1)[1].split('\nstruct SessionCommand:', 1)[0]
execution = 'struct ContinuedExecution: Codable {' + execution
lease = models.split('struct ExecutionLease: Codable {', 1)[1].split('\n}', 1)[0]
lease = 'struct ExecutionLease: Codable {' + lease + '\n}'
policy = source.split('enum ContinuedCapturePolicy {', 1)[1].split('// ReplayKit invokes', 1)[0]
policy = 'enum ContinuedCapturePolicy {' + policy
capture_only = source.split('if configuration.continuedProcessingEnabled == true {', 1)[1].split('guard self.agent?.accepts', 1)[0]
assert 'try self.store.write(frame, to: "frame.json")' in capture_only
assert 'return' in capture_only and 'AIClient' not in capture_only and 'HardwareClient' not in capture_only
policy_test = '''import Foundation
''' + execution + '\n' + lease + '\n' + policy + '''
@main struct CapturePolicyTest {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000)
        func allowed(_ phase: ContinuedExecution.Phase?, requestedAt: Date? = nil,
                     lease: ExecutionLease? = nil, fence: String? = "original", actual: String? = "original",
                     enabled: Bool = true) -> Bool {
            let execution = phase.map { ContinuedExecution(phase: $0, stopGeneration: fence, requestedAt: requestedAt) }
            return ContinuedCapturePolicy.rejection(enabled: enabled, execution: execution, sessionID: "session",
                stopGeneration: actual, lease: lease, now: now) == nil
        }
        precondition(allowed(nil, enabled: false))
        precondition(!allowed(nil))
        precondition(allowed(.awaitingFirstFrame))
        precondition(!allowed(.awaitingFirstFrame, enabled: false))
        precondition(!allowed(.awaitingFirstFrame, actual: "stopped"))
        precondition(allowed(.awaitingFirstFrame, fence: nil, actual: nil))
        precondition(!allowed(.awaitingFirstFrame, fence: nil, actual: "stopped"))
        precondition(!allowed(.starting))
        precondition(allowed(.starting, requestedAt: now.addingTimeInterval(-9.99)))
        precondition(!allowed(.starting, requestedAt: now.addingTimeInterval(-10)))
        precondition(!allowed(.starting, requestedAt: now.addingTimeInterval(1)))
        precondition(!allowed(.active))
        precondition(allowed(.active, lease: .init(sessionID: "session", expiresAt: now.addingTimeInterval(6))))
        precondition(!allowed(.active, lease: .init(sessionID: "other", expiresAt: now.addingTimeInterval(5))))
        precondition(!allowed(.active, lease: .init(sessionID: "session", expiresAt: now)))
        precondition(!allowed(.active, lease: .init(sessionID: "session", expiresAt: now.addingTimeInterval(-1))))
        precondition(!allowed(.active, lease: .init(sessionID: "session", expiresAt: now.addingTimeInterval(6.01))))
        precondition(!allowed(.active, lease: .init(sessionID: "session", expiresAt: now.addingTimeInterval(5)), actual: "stopped"))
        print("PASS: 18 production owner-policy cases; pending capture needs no lease, active needs a real bounded lease, STOP and fallback remain closed")
        func recover(requested: Bool = true, received: Bool = true, dispatched: Bool = false,
                     reserved: Bool = false, frame: Bool = true, cancelled: Bool = false,
                     authorized: Bool = true) -> Bool {
            BroadcastRecoveryPolicy.permits(modelRequested: requested, proposalReceived: received,
                mayHaveDispatched: dispatched, reservedMessageAttempt: reserved,
                frameFailureBeforeDispatch: frame, taskCancelled: cancelled, sessionAuthorized: authorized)
        }
        precondition(recover()) // Model returned, but its frame was rejected before POST.
        precondition(recover(requested: false)) // Frame expired during the initial status read.
        precondition(recover(received: false, frame: false)) // Model failed, no action exists.
        precondition(!recover(dispatched: true)) // Ambiguous POST must never be repeated.
        precondition(!recover(reserved: true)) // Message one-shot remains consumed, even before POST.
        precondition(!recover(cancelled: true))
        precondition(!recover(authorized: false))
        precondition(!recover(frame: false)) // Arbitrary validation error after a proposal is not a frame retry.
        precondition(!recover(requested: false, received: false, frame: false))
        precondition(!recover(received: false, dispatched: true, frame: false))
        precondition(!recover(received: false, reserved: true, frame: false))
        precondition(!recover(requested: false, authorized: false))
        var agent = AgentSession(id: "recovery", startedAt: now, maxRounds: 10)
        precondition(agent.recoverBeforeDispatch("no POST", at: now))
        precondition(agent.recoverBeforeDispatch("no POST", at: now))
        precondition(!agent.recoverBeforeDispatch("no POST", at: now))
        precondition(!agent.accepts(frameID: "old", capturedAt: now))
        precondition(agent.accepts(frameID: "new", capturedAt: now.addingTimeInterval(0.1)))
        print("PASS: 12 recovery eligibility cases, two-reobserve budget and fresh-frame requirement; no POST/message attempt is retried")
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path / 'CapturePolicyTest.swift').write_text(policy_test)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6', '-parse-as-library',
                    str(root / 'ios/Shared/AgentSession.swift'), str(path / 'CapturePolicyTest.swift'), '-o', str(path / 'policy')], check=True)
    subprocess.run([str(path / 'policy')], check=True, timeout=10)
