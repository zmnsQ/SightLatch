import Foundation

// Only the public UIKit seam is mocked. The host methods, models and file-lock implementation are production sources.
@MainActor class UIScene: NSObject {
    enum ActivationState { case unattached, foregroundActive, foregroundInactive, background }
    var activationState: ActivationState
    init(_ state: ActivationState) { activationState = state }
}
@MainActor final class UIWindowScene: UIScene {}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState: State = .active
    var connectedScenes: Set<UIScene> = [UIWindowScene(.foregroundActive)]
    var available = true
    var queries = 0
    var requests = 0
    var completion: ((Bool) -> Void)?
    var afterCanOpen: (() -> Void)?
    func canOpenURL(_ url: URL) -> Bool { precondition(url.absoluteString == "weixin://"); queries += 1; afterCanOpen?(); return available }
    func open(_ url: URL, options: [String: String], completionHandler: @escaping (Bool) -> Void) {
        precondition(url.absoluteString == "weixin://" && options.isEmpty)
        precondition(applicationState != .background && connectedScenes.contains {
            $0 is UIWindowScene && [.foregroundActive, .foregroundInactive].contains($0.activationState)
        })
        requests += 1; completion = completionHandler
    }
    func reset() { applicationState = .active; connectedScenes = [UIWindowScene(.foregroundActive)]; available = true; queries = 0; requests = 0; completion = nil; afterCanOpen = nil }
}
@main struct MessageLaunchHostTests {
    @MainActor static func main() async throws {
        let app = UIApplication.shared, store = SharedStore()
        var config = PilotConfiguration(); config.uploadConsent = true
        try store.write(config, to: "configuration.json")
        func setup() throws -> (PilotViewModel, SessionCommand) {
            app.reset()
            var command = SessionCommand(task: "打开微信，给文件传输助手发送消息：你好", running: true)
            command.fixtureActiveExecution(stopGeneration: store.stopGeneration)
            command.messageScope = MessageScope(intent: MessageIntent.parse(command.task)!, sessionID: command.id,
                generation: command.generation, expiresAt: Date().addingTimeInterval(300), stopGeneration: store.stopGeneration)
            try store.startCommand(command, expectedStopGeneration: store.stopGeneration)
            let model = PilotViewModel()
            let id = model.taskFlow.begin(goal: command.task, configurationID: Data())!
            model.taskFlow.receive("保留原计划", requestID: id)
            precondition(model.taskFlow.authorize(requestID: id, goal: command.task, configurationID: Data()))
            precondition(model.taskFlow.consumePermission(goal: command.task, configurationID: Data()))
            model.taskFlow.bindSession(command.id)
            model.captureObservation = CaptureObservation(sessionID: command.id, state: "capturing",
                receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime, generation: command.generation)
            return (model, command)
        }
        var (model, command) = try setup()
        let original = model.captureObservation!
        for invalid in 0..<5 {
            model.captureObservation = original
            switch invalid {
            case 0: model.captureObservation = nil
            case 1: model.captureObservation!.sessionID = "old-session"
            case 2: model.captureObservation!.generation = command.generation + 1
            case 3: model.captureObservation!.receivedUptime = ProcessInfo.processInfo.systemUptime - 6
            default: model.captureObservation!.receivedAt = command.createdAt.addingTimeInterval(-1)
            }
            model.launchMessageAppIfNeeded()
            precondition(app.queries == 0 && app.requests == 0)
            precondition(store.command!.messageScope!.launch.phase == .pending)
        }
        model.captureObservation = original; app.applicationState = .background
        model.launchMessageAppIfNeeded(); precondition(app.requests == 0)
        app.applicationState = .active
        model.launchMessageAppIfNeeded(); model.launchMessageAppIfNeeded()
        precondition(app.queries == 1 && app.requests == 1)
        precondition(store.command!.messageScope!.launch.phase == .opening)
        precondition(!store.command!.messageScope!.launch.permitsFrame(capturedAt: Date(), capturedUptime: ProcessInfo.processInfo.systemUptime))
        // STOP can land after the system request: the late success must never acknowledge it.
        try store.invalidatePendingStarts()
        app.completion?(true)
        for _ in 0..<10 { await Task.yield() }
        precondition(store.command!.messageScope!.launch.phase == .opening)
        precondition(store.command!.messageScope!.launch.acknowledgedAt == nil)
        (model, command) = try setup()
        let preLaunchDate = Date(), preLaunchUptime = ProcessInfo.processInfo.systemUptime
        model.launchMessageAppIfNeeded()
        // A real successful open backgrounds its caller; completion still needs to acknowledge once.
        app.applicationState = .background; app.completion?(true)
        precondition(store.command!.messageScope!.launch.phase == .opened,
                     "Completion must persist ACK before another MainActor task can be suspended")
        let apiLaunch = store.command!.messageScope!.launch
        precondition(apiLaunch.phase == .opened && apiLaunch.acknowledgedAt != nil)
        precondition(!apiLaunch.isVisuallyEstablished && !apiLaunch.permitsFrame(capturedAt: Date(), capturedUptime: ProcessInfo.processInfo.systemUptime),
                     "System URL acceptance alone cannot authorize ordinary message input")
        let visualDate = Date(), visualUptime = ProcessInfo.processInfo.systemUptime
        let visualContext = MessageDispatchContext(sessionID: command.id, generation: command.generation,
            frameID: "visual-proof", scopeID: command.messageScope!.id)
        let confirmed = try store.confirmMessageAppVisible(context: visualContext, expectedStopGeneration: store.stopGeneration,
            capturedAt: visualDate, capturedUptime: visualUptime)
        precondition(confirmed)
        let launch = store.command!.messageScope!.launch
        precondition(launch.isVisuallyEstablished && launch.proofSource == "visual_target_app")
        precondition(!launch.permitsFrame(capturedAt: visualDate, capturedUptime: visualUptime))
        precondition(!launch.permitsFrame(capturedAt: preLaunchDate, capturedUptime: preLaunchUptime))
        precondition(!launch.permitsFrame(capturedAt: Date(), capturedUptime: nil))
        precondition(!launch.permitsFrame(capturedAt: Date(), capturedUptime: preLaunchUptime))
        precondition(launch.permitsFrame(capturedAt: Date(), capturedUptime: ProcessInfo.processInfo.systemUptime))
        let duplicate = try store.confirmMessageAppVisible(context: visualContext, expectedStopGeneration: store.stopGeneration,
            capturedAt: visualDate, capturedUptime: visualUptime)
        precondition(!duplicate && store.command!.messageScope!.launch.visuallyEstablishedAt == visualDate)
        app.completion?(false)
        precondition(store.command!.messageScope!.launch.isVisuallyEstablished && model.taskFlow.phase == .ready,
                     "A late rejected API callback cannot demote visual proof or the task UI")
        app.applicationState = .active; model.launchMessageAppIfNeeded()
        precondition(app.requests == 1, "No automatic reopen after success")
        (model, command) = try setup()
        app.afterCanOpen = { app.applicationState = .inactive }
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 1 && store.command!.messageScope!.launch.phase == .opening,
                     "A foreground scene made inactive by a system panel may perform its one authorized URL handoff")
        precondition(model.taskFlow.phase == .ready && model.taskFlow.plan == "保留原计划")
        app.afterCanOpen = nil; app.applicationState = .active
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 1, "Returning active cannot replay the already-dispatched inactive handoff")
        (model, command) = try setup()
        app.applicationState = .inactive; app.connectedScenes = [UIWindowScene(.foregroundInactive)]
        model.launchMessageAppIfNeeded(); model.launchMessageAppIfNeeded()
        precondition(app.requests == 1 && store.command!.messageScope!.launch.phase == .opening)
        for unavailable in [Set<UIScene>(), [UIWindowScene(.background)], [UIWindowScene(.unattached)], [UIScene(.foregroundActive)]] {
            (model, command) = try setup()
            app.applicationState = .inactive; app.connectedScenes = unavailable
            model.launchMessageAppIfNeeded()
            precondition(app.requests == 0 && store.command!.messageScope!.launch.phase == .pending,
                         "Only an attached foreground window scene may initiate the URL handoff")
        }
        (model, command) = try setup()
        app.afterCanOpen = { app.applicationState = .background }
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 0 && store.command!.messageScope!.launch.phase == .pending,
                     "An undispatched claim must be released when its app backgrounds")
        app.afterCanOpen = nil; app.applicationState = .active
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 1 && store.command!.messageScope!.launch.dispatchedUptime != nil)
        do {
            try store.releaseMessageLaunchClaim(context: .init(sessionID: command.id, generation: command.generation,
                frameID:"release",scopeID:command.messageScope!.id), expectedStopGeneration:store.stopGeneration)
            preconditionFailure("A dispatched system request cannot be replayed")
        } catch {}
        (model, command) = try setup()
        app.available = false
        model.launchMessageAppIfNeeded(); model.launchMessageAppIfNeeded()
        precondition(app.queries == 1 && app.requests == 0)
        precondition(store.command!.messageScope!.launch.phase == .failed)
        precondition(model.taskFlow.phase == .prerequisites && model.taskFlow.plan == "保留原计划" && model.taskFlow.goal == command.task)
        precondition(!model.taskFlow.consumePermission(goal: command.task, configurationID: Data()))
        (model, command) = try setup()
        model.launchMessageAppIfNeeded(); app.completion?(false)
        for _ in 0..<10 { await Task.yield() }
        precondition(store.command!.messageScope!.launch.phase == .failed && model.taskFlow.phase == .prerequisites)
        model.launchMessageAppIfNeeded(); precondition(app.requests == 1)
        (model, command) = try setup()
        model.launchMessageAppIfNeeded()
        try store.updateCommand(sessionID: command.id) { $0.generation += 1 }
        app.completion?(true)
        for _ in 0..<10 { await Task.yield() }
        precondition(store.command!.messageScope!.launch.phase == .opening)
        (model, command) = try setup()
        model.launchMessageAppIfNeeded()
        config.uploadConsent = false; try store.write(config, to: "configuration.json")
        app.completion?(true)
        for _ in 0..<10 { await Task.yield() }
        precondition(store.command!.messageScope!.launch.phase == .opening)
        config.uploadConsent = true; try store.write(config, to: "configuration.json")
        (model, command) = try setup()
        try store.invalidatePendingStarts()
        model.launchMessageAppIfNeeded()
        precondition(app.requests == 0 && store.command!.messageScope!.launch.phase == .pending)
        (model, command) = try setup()
        let pendingContext = MessageDispatchContext(sessionID: command.id, generation: command.generation,
            frameID:"already-visible",scopeID:command.messageScope!.id)
        let visiblePending = try store.confirmMessageAppVisible(context:pendingContext, expectedStopGeneration:store.stopGeneration,
            capturedAt:Date(),capturedUptime:ProcessInfo.processInfo.systemUptime)
        precondition(visiblePending && store.command!.messageScope!.launch.isVisuallyEstablished)
        model.launchMessageAppIfNeeded(); precondition(app.requests == 0,"Already visible target app does not need a URL roundtrip")
        (model, command) = try setup()
        model.launchMessageAppIfNeeded()
        let openingContext = MessageDispatchContext(sessionID:command.id,generation:command.generation,
            frameID:"opened-visually",scopeID:command.messageScope!.id)
        for stale in [true,false] {
            do {
                let result = try store.confirmMessageAppVisible(context:openingContext,expectedStopGeneration:store.stopGeneration,
                    capturedAt:stale ? Date().addingTimeInterval(-30) : Date(),
                    capturedUptime:stale ? ProcessInfo.processInfo.systemUptime : nil)
                preconditionFailure("Stale or missing monotonic frame proof passed: \(result)")
            } catch {}
        }
        let visualOpening = try store.confirmMessageAppVisible(context:openingContext,expectedStopGeneration:store.stopGeneration,
            capturedAt:Date(),capturedUptime:ProcessInfo.processInfo.systemUptime)
        precondition(visualOpening)
        app.completion?(false)
        precondition(store.command!.messageScope!.launch.isVisuallyEstablished && model.taskFlow.phase == .ready)
        print("PASS: production active/inactive foreground-window launch uses one fixed URL, rejects background/disconnected/nonwindow/stale/STOP/generation changes, requires fresh first-frame and target-app visual proof, releases only undispatched claims, direct callback persistence, late callback cannot demote visual proof; no UIKit or real app launch")
    }
}
