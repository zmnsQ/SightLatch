import Foundation

struct HostCalibrationFlow { var isBusy = false }
enum CalibrationCancellationScene { case active, inactive, background, unknown }
enum HostCalibrationCancellationSource { case globalStop }
struct HostAutomaticCalibration {
    enum Phase { case idle, error }
    var isBusy = false
    var id = UUID()
    var phase = Phase.idle
    var detail = ""
}
@MainActor struct HardwareClient {
    static var stops = 0
    static var stopFails = false
    init(configuration: PilotConfiguration) {}
    func stopAndVerify(expectedSessionID: String? = nil, captureOwnerID: String? = nil) async throws {
        Self.stops += 1
        if Self.stopFails { throw PilotError.message("hardware STOP not confirmed") }
    }
}
@MainActor final class SessionVoiceController {
    static let shared = SessionVoiceController()
    func stop() {}
}
@MainActor final class PilotActivityManager {
    static let shared = PilotActivityManager()
    func finish(sessionID: String, phase: String, steps: Int) async {}
}

// Only the system scheduler is replaced; Main's coordinator and Store's CAS are production code.
@MainActor final class ContinuedSession {
    static let shared = ContinuedSession()
    var calls = 0
    var allowActivation = false
    var rejectBeforeClaim = false
    var holdCancellationCleanup = false
    var cleanupStarted = false
    var releaseCleanup = false
    func reset() {
        calls = 0; allowActivation = false; rejectBeforeClaim = false
        holdCancellationCleanup = false; cleanupStarted = false; releaseCleanup = false
    }
    func cancel() {}
    func startAfterFirstFrame(command: SessionCommand, configuration: PilotConfiguration,
                              firstFrame: CaptureObservation, expectedStopGeneration: String?) async throws {
        calls += 1
        if rejectBeforeClaim { throw PilotError.message("scheduler rejected startup") }
        do {
            _ = try SharedStore.shared.claimContinuedStart(sessionID: command.id, generation: command.generation,
                expectedStopGeneration: expectedStopGeneration, firstFrame: firstFrame)
            while !allowActivation { try Task.checkCancellation(); await Task.yield() }
            _ = try SharedStore.shared.activateContinuedStart(sessionID: command.id, generation: command.generation,
                expectedStopGeneration: expectedStopGeneration)
        } catch {
            if holdCancellationCleanup {
                cleanupStarted = true
                while !releaseCleanup { await Task.yield() }
            }
            throw error
        }
    }
}

@main struct ContinuedFirstFrameHostTests {
    @MainActor static func main() async throws {
        let app = UIApplication.shared, store = SharedStore.shared, scheduler = ContinuedSession.shared
        var config = PilotConfiguration(); config.uploadConsent = true; config.continuedProcessingEnabled = true
        try store.write(config, to: "configuration.json")
        func setup() throws -> (PilotViewModel, SessionCommand) {
            app.reset(); store.remove("lease.json")
            var command = SessionCommand(task: "打开微信，给文件传输助手发送消息：你好", running: true)
            command.continuedExecution = .init(phase: .awaitingFirstFrame, stopGeneration: store.stopGeneration)
            command.fixtureActiveExecution(stopGeneration: store.stopGeneration)
            command.messageScope = MessageScope(intent: MessageIntent.parse(command.task)!, sessionID: command.id,
                generation: command.generation, expiresAt: command.createdAt.addingTimeInterval(300), stopGeneration: store.stopGeneration)
            try store.startCommand(command, expectedStopGeneration: store.stopGeneration)
            let model = PilotViewModel()
            _ = model.taskFlow.explicitGoalStart(goal: command.task, configurationID: Data())
            precondition(model.taskFlow.consumePermission(goal: command.task, configurationID: Data()))
            model.taskFlow.bindSession(command.id)
            model.prepared = true
            model.captureObservation = CaptureObservation(sessionID: command.id, state: "capturing",
                receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime, generation: command.generation)
            try store.write(model.captureObservation!, to: "capture-status.json")
            return (model, command)
        }
        func waitUntil(_ predicate: () -> Bool) async {
            let deadline = Date().addingTimeInterval(2)
            while !predicate() && Date() < deadline { await Task.yield() }
            precondition(predicate(), "host test timed out")
        }
        scheduler.reset()
        var (model, command) = try setup()
        let firstFrame = model.captureObservation!
        for invalid in 0..<7 {
            model.captureObservation = firstFrame
            switch invalid {
            case 0: model.captureObservation = nil
            case 1: model.captureObservation!.sessionID = "old-session"
            case 2: model.captureObservation!.generation = command.generation + 1
            case 3: model.captureObservation!.receivedUptime = ProcessInfo.processInfo.systemUptime - 6
            case 4: model.captureObservation!.receivedAt = command.createdAt.addingTimeInterval(-1)
            case 5: model.captureObservation!.receivedAt = Date().addingTimeInterval(10)
            default: app.applicationState = .background
            }
            model.startContinuedSessionAfterFirstFrameIfNeeded()
            precondition(model.continuedStartupTask == nil && scheduler.calls == 0)
        }
        model.captureObservation = firstFrame
        app.applicationState = .inactive; app.connectedScenes = [UIWindowScene(.foregroundInactive)]
        for _ in 0..<20 { model.startContinuedSessionAfterFirstFrameIfNeeded() }
        await waitUntil { scheduler.calls == 1 }
        precondition(store.command!.continuedExecution!.phase == .starting)
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 0 && store.read("lease.json", as: ExecutionLease.self) == nil)
        scheduler.allowActivation = true
        await waitUntil { model.continuedStartupTask == nil }
        precondition(store.command!.continuedExecution!.phase == .active && app.requests == 1)
        precondition(store.command!.createdAt == command.createdAt, "First-frame startup cannot renew the five-minute budget")
        for _ in 0..<20 { model.startContinuedSessionAfterFirstFrameIfNeeded(); model.launchMessageAppIfNeeded() }
        precondition(scheduler.calls == 1 && app.requests == 1)

        // A failure before claim is terminal for this attempt, rather than retried by refresh.
        scheduler.reset(); scheduler.rejectBeforeClaim = true
        (model, command) = try setup()
        model.startContinuedSessionAfterFirstFrameIfNeeded()
        await waitUntil { model.continuedStartupTask == nil }
        precondition(!store.command!.running && !model.prepared && model.taskFlow.goal == command.task)
        precondition(store.status.detail == "scheduler rejected startup")
        for _ in 0..<20 { model.startContinuedSessionAfterFirstFrameIfNeeded() }
        precondition(scheduler.calls == 1 && app.requests == 0)

        // STOP during the system handoff cannot be acknowledged by a late activation.
        scheduler.reset(); (model, command) = try setup()
        model.startContinuedSessionAfterFirstFrameIfNeeded()
        await waitUntil { scheduler.calls == 1 }
        try store.invalidatePendingStarts()
        _ = try store.updateCommand(sessionID: command.id) { $0.running = false }
        model.notice = "explicit stop"
        scheduler.allowActivation = true
        await waitUntil { model.continuedStartupTask == nil }
        precondition(!store.command!.running && app.requests == 0 && model.notice == "explicit stop")

        // A late result for an older session cannot revoke a newly prepared goal.
        scheduler.reset(); let (oldModel, _) = try setup()
        oldModel.startContinuedSessionAfterFirstFrameIfNeeded()
        await waitUntil { scheduler.calls == 1 }
        let (_, replacement) = try setup()
        scheduler.allowActivation = true
        await waitUntil { oldModel.continuedStartupTask == nil }
        precondition(store.command!.id == replacement.id && store.command!.running && app.requests == 0)

        // Active state alone is insufficient: a current real lease is needed through dispatch.
        (model, command) = try setup()
        _ = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration, firstFrame: model.captureObservation!)
        _ = try store.activateContinuedStart(sessionID: command.id, generation: command.generation,
            expectedStopGeneration: store.stopGeneration)
        for lease in [ExecutionLease(sessionID: "old-session", expiresAt: Date().addingTimeInterval(6)),
                      ExecutionLease(sessionID: command.id, expiresAt: Date().addingTimeInterval(-1))] {
            try store.write(lease, to: "lease.json")
            model.launchMessageAppIfNeeded(); precondition(app.requests == 0)
        }
        try store.write(ExecutionLease(sessionID: command.id, expiresAt: Date().addingTimeInterval(6)), to: "lease.json")
        app.afterCanOpen = { store.remove("lease.json") }
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 0 && store.command!.messageScope!.launch.phase == .pending)
        app.afterCanOpen = nil
        try store.write(ExecutionLease(sessionID: command.id, expiresAt: Date().addingTimeInterval(6)), to: "lease.json")
        model.launchMessageAppIfNeeded(); precondition(app.requests == 1)

        // The real Main stop method keeps the startup cleanup fenced until it drains.
        scheduler.reset(); scheduler.holdCancellationCleanup = true
        (model, command) = try setup()
        model.startContinuedSessionAfterFirstFrameIfNeeded()
        await waitUntil { scheduler.calls == 1 }
        HardwareClient.stops = 0
        let stopping = Task { await model.stop() }
        await waitUntil { scheduler.cleanupStarted }
        precondition(!store.command!.running && model.stopping && model.isSessionActive)
        precondition(model.continuedStartupTask != nil && HardwareClient.stops == 0,
                     "Old startup cleanup must drain before the final verified STOP permits another ARM")
        scheduler.releaseCleanup = true
        await stopping.value
        precondition(!model.stopping && model.continuedStartupTask == nil && !model.prepared)
        precondition(HardwareClient.stops == 1 && store.status.phase == "停止")

        // Ending a paused attempt must not mint a new task, budget, ARM or message attempt.
        scheduler.reset(); (model, command) = try setup()
        _ = try store.updateCommand(sessionID: command.id) {
            $0.messageScope?.pasteAttempted = true
            $0.messageScope?.sendAttempted = true
        }
        let pausedCommand = store.command!
        let originalFence = store.stopGeneration
        model.status = PilotStatus(phase: "暂停", detail: "指针未定位；本轮未执行新动作", steps: 3, sessionID: command.id)
        try store.write(model.status, to: "status.json")
        HardwareClient.stops = 0
        await model.endPausedSession()
        let endedCommand = store.command!
        precondition(!endedCommand.running && !model.prepared && HardwareClient.stops == 1)
        precondition(store.stopGeneration != originalFence, "Ending must invalidate the old start fence")
        precondition(endedCommand.id == pausedCommand.id && endedCommand.generation == pausedCommand.generation)
        precondition(endedCommand.createdAt == pausedCommand.createdAt && endedCommand.messageScope?.expiresAt == pausedCommand.messageScope?.expiresAt)
        precondition(endedCommand.messageScope?.id == pausedCommand.messageScope?.id && endedCommand.messageScope?.sendAttempted == true && endedCommand.messageScope?.pasteAttempted == true)
        precondition(store.status.detail.contains("指针未定位") && store.status.detail.contains("避免重复发送"))
        precondition(scheduler.calls == 0 && app.requests == 0)
        await model.endPausedSession()
        precondition(HardwareClient.stops == 1, "A stale end button cannot issue another stop")

        (model, command) = try setup()
        model.status = PilotStatus(phase: "暂停", detail: "旧会话原因", steps: 0, sessionID: "old-session")
        HardwareClient.stops = 0
        await model.endPausedSession()
        precondition(store.command!.running && HardwareClient.stops == 0)

        (model, command) = try setup()
        model.status = PilotStatus(phase: "暂停", detail: "需要核对画面", steps: 2, sessionID: command.id)
        try store.write(model.status, to: "status.json")
        HardwareClient.stopFails = true
        await model.endPausedSession()
        HardwareClient.stopFails = false
        precondition(!store.command!.running && store.status.phase == "请核实硬件停止")
        precondition(store.status.detail.contains("未确认硬件停止") && store.status.detail.contains("需要核对画面"))
        print("PASS: fresh first-frame-only startup, foreground inactive handoff, one local task/CAS, real active lease before URI, no budget renewal/retry, early failure preserves goal, STOP/new-session fences; no scheduler/network/HID")
    }
}
