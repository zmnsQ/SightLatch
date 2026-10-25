import Foundation

@main struct ContinuedStartTests {
    static func main() throws {
        let store = SharedStore.shared
        var config = PilotConfiguration()
        config.uploadConsent = true; config.continuedProcessingEnabled = true
        try store.write(config, to: "configuration.json")
        func prepare() throws -> (SessionCommand, CaptureObservation) {
            store.remove("lease.json")
            var command = SessionCommand(task: "observe", running: true)
            command.continuedExecution = .init(phase: .awaitingFirstFrame, stopGeneration: store.stopGeneration)
            command.fixtureActiveExecution(stopGeneration: store.stopGeneration)
            try store.startCommand(command, expectedStopGeneration: store.stopGeneration)
            return (command, CaptureObservation(sessionID: command.id, state: "capturing", receivedAt: Date(),
                receivedUptime: ProcessInfo.processInfo.systemUptime, generation: command.generation))
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        var (command, frame) = try prepare()
        precondition(store.command?.continuedExecution?.phase == .awaitingFirstFrame)
        precondition(store.read("lease.json", as: ExecutionLease.self) == nil, "Preparation must not create an execution lease")
        var stale = frame; stale.receivedUptime = ProcessInfo.processInfo.systemUptime - 6
        precondition(rejected { _ = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, firstFrame: stale) })
        precondition(store.command?.continuedExecution?.phase == .awaitingFirstFrame)
        let starting = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, firstFrame: frame)
        precondition(starting.continuedExecution?.phase == .starting && starting.continuedExecution?.requestedAt != nil)
        precondition(store.read("lease.json", as: ExecutionLease.self) == nil)
        precondition(rejected { _ = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, firstFrame: frame) }, "A second owner cannot claim the same first frame")
        let losingStart = try store.failContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, reason: "duplicate caller")
        precondition(!losingStart && store.command?.running == true, "A failed duplicate cannot revoke the winning claim")
        let active = try store.activateContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration)
        let lease = store.read("lease.json", as: ExecutionLease.self)!
        precondition(active.continuedExecution?.phase == .active && lease.sessionID == active.id)
        precondition(lease.expiresAt > Date() && lease.expiresAt.timeIntervalSinceNow <= 6)
        precondition(active.createdAt == command.createdAt, "The user's original five-minute lifetime cannot renew")
        precondition(rejected { _ = try store.activateContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration) })
        (command, frame) = try prepare()
        let originalFence = store.stopGeneration
        _ = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: originalFence, firstFrame: frame)
        try store.invalidatePendingStarts()
        precondition(rejected { _ = try store.activateContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: originalFence) })
        precondition(store.read("lease.json", as: ExecutionLease.self) == nil, "Late callbacks after STOP cannot create a lease")
        (command, frame) = try prepare()
        _ = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, firstFrame: frame)
        try store.updateCommand(sessionID: command.id) { $0.continuedExecution!.requestedAt = Date().addingTimeInterval(-11) }
        precondition(rejected { _ = try store.activateContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration) })
        let wrongGeneration = try store.failContinuedStart(sessionID: command.id, generation: command.generation + 1,
            expectedStopGeneration: store.stopGeneration, reason: "old callback")
        precondition(!wrongGeneration && store.command?.running == true)
        let failed = try store.failContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, expectedRequestedAt: store.command?.continuedExecution?.requestedAt,
            reason: "首帧后系统未接受后台执行")
        precondition(failed && store.command?.running == false && store.status.detail == "首帧后系统未接受后台执行")
        (command, frame) = try prepare()
        config.continuedProcessingEnabled = false; try store.write(config, to: "configuration.json")
        precondition(rejected { _ = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, firstFrame: frame) })
        precondition(store.read("lease.json", as: ExecutionLease.self) == nil)
        print("PASS: first-frame-only claim, no preparation lease, single active executor, real six-second lease, STOP and startup deadline fences, preserved original lifetime, precise startup failure; no scheduler/network/HID")
    }
}
