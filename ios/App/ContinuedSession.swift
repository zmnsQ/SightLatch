import Foundation
import BackgroundTasks
import ActivityKit
import UIKit

// Submission can complete on any queue, even after this session has stopped.
// It only publishes a result; the fixed claim and STOP fence authorize adoption.
private final class ContinuedSubmissionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?

    func complete(_ result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        if outcome == nil { outcome = result }
    }

    var result: Result<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }
}

// Optional iOS26 path. This task actually performs AI inference, safety validation and LAN dispatch.
// It is not a blank polling task, audio hack, or promise of unlimited background execution.
@MainActor
final class ContinuedSession {
    static let shared = ContinuedSession()
    private var work: Task<Void, Never>?
    private var schedulerID: String?
    private var activeSessionID: String?

    func startAfterFirstFrame(command: SessionCommand, configuration: PilotConfiguration,
                              firstFrame: CaptureObservation, expectedStopGeneration: String?) async throws {
        let store = SharedStore.shared
        var claimedRequestAt: Date?
        do {
            guard #available(iOS 26.0, *) else { throw PilotError.message("可选后台协调模式需要iOS26及对应SDK") }
            guard work == nil, schedulerID == nil else { throw PilotError.message("已有后台会话尚未退出") }
            guard hasForegroundWindowScene() else { throw PilotError.message("后台执行需要从前台开始，请回到SightLatch继续当前任务。") }
            let claimed = try store.claimContinuedStart(sessionID: command.id, generation: command.generation,
                expectedStopGeneration: expectedStopGeneration, firstFrame: firstFrame)
            claimedRequestAt = claimed.continuedExecution?.requestedAt
            let identifier = (Bundle.main.bundleIdentifier ?? "com.example.HIDPilot") + ".agent." + UUID().uuidString
            let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in
                    guard let self else { continued.setTaskCompleted(success: false); return }
                    self.run(task: continued, command: claimed, configuration: configuration,
                        expectedStopGeneration: expectedStopGeneration)
                }
            }
            guard accepted else { throw PilotError.message("系统未注册后台会话，未开始自动操作。") }
            schedulerID = identifier; activeSessionID = command.id
            let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                title: "SightLatch有限操作会话", subtitle: "已收到屏幕画面，开始处理当前任务")
            request.strategy = .fail
            try Task.checkCancellation()
            guard hasForegroundWindowScene(), store.stopGeneration == expectedStopGeneration,
                  let current = store.command, current.id == command.id, current.running,
                  current.generation == command.generation, current.continuedExecution?.phase == .starting,
                  store.configuration.uploadConsent else { throw PilotError.message("后台执行提交前的前台场景、会话或停止状态已变化。") }
            guard let requestedAt = claimedRequestAt else { throw CancellationError() }
            let startupDeadline = requestedAt.addingTimeInterval(ContinuedExecution.startupTimeout)
            do {
                if #available(iOS 27.0, *) {
                    let submission = ContinuedSubmissionResult()
                    // The SDK requires this asynchronous submission API to be
                    // called off the main thread. Never wait indefinitely for
                    // its completion or let a late result authorize old work.
                    let submissionWork = Task.detached(priority: .userInitiated) {
                        let store = SharedStore.shared
                        guard !Task.isCancelled, store.stopGeneration == expectedStopGeneration,
                              let current = store.command, current.id == command.id, current.running,
                              current.generation == command.generation,
                              current.continuedExecution?.phase == .starting,
                              current.continuedExecution?.requestedAt == requestedAt,
                              current.continuedExecution?.stopGeneration == expectedStopGeneration,
                              store.configuration.uploadConsent else {
                            submission.complete(.failure(CancellationError())); return
                        }
                        do {
                            try await BGTaskScheduler.shared.submitTaskRequest(request)
                            submission.complete(.success(()))
                        } catch { submission.complete(.failure(error)) }
                    }
                    defer { submissionWork.cancel() }
                    while submission.result == nil {
                        try Task.checkCancellation()
                        guard store.stopGeneration == expectedStopGeneration,
                              let current = store.command, current.id == command.id, current.running,
                              current.generation == command.generation,
                              current.continuedExecution?.stopGeneration == expectedStopGeneration,
                              current.continuedExecution?.requestedAt == requestedAt,
                              store.configuration.uploadConsent else { throw CancellationError() }
                        guard Date() < startupDeadline else {
                            throw PilotError.message("系统未在启动时限内完成后台请求提交；已撤销本次启动，不会自动重试。")
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try submission.result?.get()
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as PilotError { throw error }
            catch {
                let failure = error as NSError
                let reason: String
                if failure.domain == BGTaskScheduler.errorDomain {
                    switch BGTaskScheduler.Error.Code(rawValue: failure.code) {
                    case .unavailable: reason = "系统未开放后台执行"
                    case .tooManyPendingTaskRequests: reason = "待处理后台请求过多"
                    case .notPermitted: reason = "请求标识或资源未获许可"
                    case .immediateRunIneligible: reason = "当前系统条件不允许立即运行"
                    default: reason = "后台调度提交失败"
                    }
                } else { reason = "后台调度提交失败" }
                throw PilotError.message("\(reason)（\(failure.domain)，代码\(failure.code)）；未开始自动操作。")
            }
            try Task.checkCancellation()
            guard store.stopGeneration == expectedStopGeneration,
                  let acceptedCommand = store.command, acceptedCommand.id == command.id, acceptedCommand.running,
                  acceptedCommand.generation == command.generation,
                  acceptedCommand.continuedExecution?.stopGeneration == expectedStopGeneration,
                  acceptedCommand.continuedExecution?.requestedAt == requestedAt,
                  store.configuration.uploadConsent else { throw CancellationError() }
            guard Date() < startupDeadline else {
                throw PilotError.message("系统未在启动时限内完成后台请求提交；已撤销本次启动，不会自动重试。")
            }
            let deadline = min(Date().addingTimeInterval(5), startupDeadline)
            while Date() < deadline {
                try Task.checkCancellation()
                guard store.stopGeneration == expectedStopGeneration,
                      let current = store.command, current.running, current.id == command.id,
                      store.configuration.uploadConsent,
                      current.continuedExecution?.stopGeneration == expectedStopGeneration,
                      current.continuedExecution?.requestedAt == claimed.continuedExecution?.requestedAt else { throw CancellationError() }
                if current.continuedExecution?.phase == .active,
                   let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id,
                   lease.expiresAt > Date() { return }
                guard current.generation == command.generation else { throw CancellationError() }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw PilotError.message("收到首帧后后台执行未及时启动；已撤销本次启动，不会自动重试。")
        } catch {
            let didFail = (try? store.failContinuedStart(sessionID: command.id, generation: command.generation,
                expectedStopGeneration: expectedStopGeneration, expectedRequestedAt: claimedRequestAt,
                reason: error.localizedDescription)) == true
            let current = store.command
            let ownsClaim = claimedRequestAt != nil && current?.id == command.id && current?.generation == command.generation
                && current?.continuedExecution?.requestedAt == claimedRequestAt && store.stopGeneration == expectedStopGeneration
            let mayCleanUp = didFail || ownsClaim
            let cleanupWork = mayCleanUp && activeSessionID == command.id ? work : nil
            if mayCleanUp && activeSessionID == command.id { cancel() }
            if let cleanupWork {
                // Its normal cleanup owns the bounded hardware STOP. Drain it
                // before the foreground host can permit a replacement session.
                await cleanupWork.value
            } else if mayCleanUp, let current = store.command, current.id == command.id,
                      current.generation == command.generation, store.stopGeneration == expectedStopGeneration {
                let cleanup = Task.detached(priority: .utility) {
                    await HardwareClient(configuration: configuration).stopRuntimeAndReport(sessionID: command.id, captureOwnerID: command.execution?.captureOwnerID)
                }
                await cleanup.value
            }
            throw error
        }
    }

    private func hasForegroundWindowScene() -> Bool {
        let app = UIApplication.shared
        guard app.applicationState != .background else { return false }
        return app.connectedScenes.contains { scene in
            scene is UIWindowScene && (scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
        }
    }

    func cancel() {
        work?.cancel()
        if let schedulerID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: schedulerID) }
        revoke(sessionID: activeSessionID)
        if work == nil {
            schedulerID = nil; activeSessionID = nil
        }
    }

    private func revoke(sessionID: String?) {
        let store = SharedStore.shared
        if var command = store.command, command.id == sessionID {
            try? store.updateCommand(sessionID: command.id) { $0.running = false }
        }
        if let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == sessionID { store.remove("lease.json") }
        if let frame = store.read("frame.json", as: SharedFrame.self), frame.sessionID == sessionID { store.remove("frame.json") }
    }

    @available(iOS 26.0, *)
    private func run(task: BGContinuedProcessingTask, command: SessionCommand, configuration: PilotConfiguration,
                     expectedStopGeneration: String?) {
        guard schedulerID == task.identifier, activeSessionID == command.id else {
            task.setTaskCompleted(success: false); return
        }
        guard work == nil else { task.setTaskCompleted(success: false); return }
        guard SharedStore.shared.command?.id == command.id, SharedStore.shared.command?.running == true else {
            revoke(sessionID: command.id)
            schedulerID = nil; activeSessionID = nil
            task.setTaskCompleted(success: false); return
        }
        let executionStartedAt: Date
        do {
            let activated = try SharedStore.shared.activateContinuedStart(sessionID: command.id, generation: command.generation,
                expectedStopGeneration: expectedStopGeneration)
            guard let startedAt = activated.executionStartedAt else { throw PilotError.message("首帧执行时钟缺失，后台任务不会开始。") }
            executionStartedAt = startedAt
        } catch {
            let failed = (try? SharedStore.shared.failContinuedStart(sessionID: command.id, generation: command.generation,
                expectedStopGeneration: expectedStopGeneration, expectedRequestedAt: command.continuedExecution?.requestedAt,
                reason: error.localizedDescription)) == true
            if failed { revoke(sessionID: command.id) }
            schedulerID = nil; activeSessionID = nil
            task.setTaskCompleted(success: false); return
        }
        task.progress.totalUnitCount = Int64(min(50, max(1, configuration.maxSteps)))
        let requestID = task.identifier
        task.expirationHandler = { [weak self] in
            // Persist cancellation immediately; do not wait for an HTTP response to stop authorization.
            let store = SharedStore.shared
            if let current = store.command, current.id == command.id, current.running {
                let previous = store.status
                if previous.sessionID != command.id || !["暂停", "停止", "完成"].contains(previous.phase) {
                    try? store.write(PilotStatus(phase: "停止", detail: "系统结束后台执行时间，设备控制已撤销。",
                        steps: previous.sessionID == command.id ? previous.steps : 0, sessionID: command.id), to: "status.json")
                }
            }
            try? store.updateCommand(sessionID: command.id) { $0.running = false }
            if let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id { store.remove("lease.json") }
            Task { @MainActor in
                guard let self, self.activeSessionID == command.id, self.schedulerID == requestID else { return }
                self.work?.cancel()
            }
        }
        let leaseWriter = Task { @MainActor in
            while !Task.isCancelled {
                guard let current = SharedStore.shared.command, current.id == command.id, current.running,
                      current.continuedExecution?.phase == .active,
                      SharedStore.shared.stopGeneration == expectedStopGeneration else { return }
                try? SharedStore.shared.write(ExecutionLease(sessionID: command.id, expiresAt: current.boundedDeadline(after: 6)), to: "lease.json")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        work = Task { @MainActor [weak self] in
            guard let self else { leaseWriter.cancel(); task.setTaskCompleted(success: false); return }
            let store = SharedStore.shared
            let hardware = HardwareClient(configuration: configuration)
            var completed = false
            var steps = 0
            var agent = AgentSession(id: command.id, startedAt: executionStartedAt, maxRounds: configuration.maxSteps, durationSeconds: command.isUnlimited ? nil : command.execution?.boundedDuration ?? 300)
            var lastProgressAt = Date()
            let end = command.authorizationExpiresAt
            var activeCommand = command
            var cancellationReason: String?
            var publicFailureMessage: String?
            func requireSession(_ snapshot: SessionCommand) throws {
                if let reason = Self.sessionAuthorizationFailure(command: snapshot, expectedStopGeneration: expectedStopGeneration) {
                    cancellationReason = reason
                    throw CancellationError()
                }
            }
            do {
                await self.publish("待广播", "系统已实际启动可选后台任务；请主动开始广播", steps: 0, sessionID: command.id, systemTask: task)
                while end.map({ Date() < $0 }) ?? command.isUnlimited, agent.limitReason() == nil {
                    try Task.checkCancellation()
                    guard var current = store.command, current.id == command.id, current.running,
                          store.configuration.uploadConsent else {
                        cancellationReason = Self.sessionAuthorizationFailure(command: activeCommand, expectedStopGeneration: expectedStopGeneration)
                        throw CancellationError()
                    }
                    activeCommand = current
                    if let updated = try store.applyPendingGoal(sessionID: command.id, expectedGeneration: current.generation) {
                        current = updated
                        activeCommand = updated
                        agent.replaceGoal()
                        await self.publish("观察", "任务指令已更新，等待新画面重新判断", steps: steps, sessionID: command.id, systemTask: task)
                        continue
                    }
                    let command = current
                    if let scope = current.messageScope {
                        guard scope.matches(sessionID: current.id, generation: current.generation, task: current.task),
                              store.stopGeneration == scope.stopGeneration else {
                            cancellationReason = "消息范围或停止边界已变化，旧会话不能继续。"
                            throw CancellationError()
                        }
                        if scope.launch.phase == .failed { throw PilotError.message(scope.launch.failure ?? "系统未接受微信打开请求，本轮已停止。") }
                    }
                    guard let frame = store.read("frame.json", as: SharedFrame.self), frame.sessionID == command.id,
                          agent.accepts(frameID: frame.id, capturedAt: frame.capturedAt), Date().timeIntervalSince(frame.capturedAt) < 3 else {
                        // Preparation precedes the user's system broadcast confirmation.
                        // The missing-frame watchdog starts only after a real first frame.
                        if agent.rounds > 0, Date().timeIntervalSince(lastProgressAt) > 45 {
                            throw PilotError.message("45秒未收到新广播画面，请结束后重新准备会话")
                        }
                        try await Task.sleep(nanoseconds: 250_000_000); continue
                    }
                    try agent.observe(frameID: frame.id, capturedAt: frame.capturedAt, fingerprint: frame.fingerprint)
                    lastProgressAt = Date()
                    let deadline = frame.capturedAt.addingTimeInterval(min(20, max(3, configuration.maxFrameAge)))
                    await self.publish("规划", "根据新画面和工具执行结果选择下一步", steps: steps, sessionID: command.id, systemTask: task)
                    try Task.checkCancellation()
                    let proposal: ActionProposal
                    var absoluteContext: AbsolutePointerContext?
                    do {
                        try requireSession(command)
                        if let reason = Self.frameObservationFailure(frame: frame, deadline: deadline) {
                            throw FrameObservationFailure(reason: "上传前：" + reason)
                        }
                        let pointerDevice = try await hardware.status()
                        try requireSession(command)
                        guard pointerDevice.session_id == command.execution?.hardwareSessionID else { throw PilotError.message("首帧授权的硬件会话已失效；不会自动重新ARM。") }
                        if let geometry = frame.geometry {
                            absoluteContext = try pointerDevice.absolutePointerContext(configuration: configuration, geometry: geometry, frameID: frame.id)
                        } else if pointerDevice.absolute_pointer_supported == true {
                            throw CaptureGeometry.MappingFailure.invalidDimensions
                        }
                        let frameContext = absoluteContext?.modelContext ?? frame.geometry?.modelContext(calibration: configuration) ?? "Capture geometry unavailable; do not infer screenshot pixel scale."
                        proposal = try await AIClient(configuration: configuration).propose(jpeg: frame.jpeg, task: command.task, frameID: frame.id, context: agent.modelContext + "\n" + frameContext, messageScope: current.messageScope, absoluteContext: absoluteContext)
                        try Task.checkCancellation()
                        try requireSession(command)
                        if let reason = Self.frameObservationFailure(frame: frame, deadline: deadline,
                            requiresPointerGeometry: [.move, .click].contains(proposal.type)) {
                            throw FrameObservationFailure(reason: "模型返回后：" + reason)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try requireSession(command)
                        if agent.recoverBeforeDispatch("Model request failed or stale proposal discarded; no HID sent.") {
                            let reason = (error as? FrameObservationFailure)?.reason ?? "AI请求未完成"
                            await self.publish("观察", "\(reason)；未执行动作，等待新画面重新规划（最多重试两次）", steps: steps, sessionID: command.id, systemTask: task)
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        }
                        throw error
                    }
                    guard let latest = store.command, latest.id == command.id, latest.running,
                          latest.generation == command.generation else {
                        cancellationReason = Self.sessionAuthorizationFailure(command: command, expectedStopGeneration: expectedStopGeneration)
                        throw CancellationError()
                    }
                    if current.messageScope?.launch.phase != latest.messageScope?.launch.phase ||
                       current.messageScope?.launch.visuallyEstablishedFrameID != latest.messageScope?.launch.visuallyEstablishedFrameID {
                        agent.record(action: "observe", outcome: "App launch advanced during inference; discard this proposal and observe a newer frame.", countsAsUIAttempt: false)
                        await self.publish("观察", "微信启动状态已更新，正在读取新画面", steps: steps, sessionID: command.id, systemTask: task)
                        continue
                    }
                    let requiresPointerGeometry = [.move, .click].contains(proposal.type)
                    if requiresPointerGeometry {
                        guard let geometry = frame.geometry else { throw CaptureGeometry.MappingFailure.invalidDimensions }
                        do {
                            if let absoluteContext {
                                _ = try geometry.validateCalibrationGeometry(context: absoluteContext.calibrationContext, orientation: configuration.orientation).get()
                            } else { _ = try geometry.pointerMapping(calibration: configuration).get() }
                        }
                        catch {
                            store.log("指针坐标校验失败 \(geometry.diagnosticDimensions)：\(error.localizedDescription)", sessionID: command.id)
                            throw error
                        }
                    }
                    if let reason = SafetyGate.rejection(proposal, task: command.task, config: configuration,
                        command: latest, frameID: frame.id, capturedAt: frame.capturedAt, capturedUptime: frame.capturedUptime, absoluteContext: absoluteContext) {
                        store.log("AI提案诊断 \(proposal.rejectionDiagnostic(frameAge: Date().timeIntervalSince(frame.capturedAt))) \(frame.geometry?.diagnosticDimensions ?? "geometry=unknown")", sessionID: command.id)
                        if SafetyGate.canReobserveLowConfidenceNavigationMove(proposal, config: configuration,
                            command: latest, frameID: frame.id, capturedAt: frame.capturedAt, capturedUptime: frame.capturedUptime, absoluteContext: absoluteContext) {
                            try requireSession(command)
                            if agent.recoverBeforeDispatch("The navigation move was not executed. Inspect a NEW frame and independently choose the next step; do not assume the discarded move happened.") {
                                await self.publish("观察", "本轮未移动，正在读取新画面重新判断（最多两次）", steps: steps, sessionID: command.id, systemTask: task)
                                continue
                            }
                        }
                        if latest.messageScope?.launch.isVisuallyEstablished == false,
                           reason == "微信尚未打开或仍是启动前画面；不会规划控制",
                           agent.recoverBeforeDispatch("Launch gate rejected an ordinary action. No HID sent. Read the current launch state: only app_launch_confirmation for the exact WeChat Open dialog, app_launch_verify for visible WeChat, or an empty low-risk wait during transition is allowed.") {
                            await self.publish("观察", "尚未进入微信，已丢弃这一步并根据新画面修正", steps: steps, sessionID: command.id, systemTask: task)
                            continue
                        }
                        if proposal.type == .ask_user || proposal.confidence < 0.85 { publicFailureMessage = String(proposal.userFacingReason.prefix(80)) }
                        throw PilotError.message("本轮未执行动作。\(reason)")
                    }
                    let messageContext = latest.messageScope.map { MessageDispatchContext(sessionID: latest.id,
                        generation: latest.generation, frameID: frame.id, scopeID: $0.id) }
                    if proposal.purpose == "app_launch_verify" {
                        guard let messageContext else { throw PilotError.message("缺少微信启动范围") }
                        try store.confirmMessageAppVisible(context: messageContext,
                            expectedStopGeneration: latest.messageScope?.stopGeneration,
                            capturedAt: frame.capturedAt, capturedUptime: frame.capturedUptime)
                        agent.record(action: "app_launch_verify", outcome: "WeChat is visually established. Observe a newer frame before ordinary navigation; no HID sent.", countsAsUIAttempt: false)
                        steps += 1
                        task.progress.completedUnitCount = Int64(steps)
                        await self.publish("观察", "已从画面确认微信，继续读取新画面", steps: steps, sessionID: command.id, systemTask: task)
                        continue
                    }
                    if proposal.type == .done {
                        if let messageContext { try store.verifyMessage(context: messageContext, capturedAt: frame.capturedAt) }
                        completed = true; break
                    }
                    if proposal.type != .wait {
                        let device = try await hardware.status()
                        try requireSession(command)
                        if let reason = Self.frameObservationFailure(frame: frame, deadline: deadline, requiresPointerGeometry: requiresPointerGeometry) {
                            if agent.recoverBeforeDispatch("Hardware status took time; frame is no longer current. No HID sent.") {
                                await self.publish("观察", "派发前：\(reason)；未执行动作，等待新画面重新规划（最多重试两次）", steps: steps, sessionID: command.id, systemTask: task)
                                continue
                            }
                            throw FrameObservationFailure(reason: "派发前：" + reason + "；已用完两次重新观察，未提交动作。")
                        }
                        await self.publish("执行", proposal.description, steps: steps, sessionID: command.id, systemTask: task)
                        var preDispatchFrameFailure: String?
                        var reservedMessageAttempt = false
                        do { try await hardware.send(proposal, expectedSession: device.session_id, frameDeadline: deadline, absoluteContext: absoluteContext, stillAuthorized: {
                            if let absoluteContext, !absoluteContext.matches(configuration: store.configuration) { return false }
                            if let reason = Self.sessionAuthorizationFailure(command: command, expectedStopGeneration: expectedStopGeneration) {
                                cancellationReason = reason
                                return false
                            }
                            guard let latest = store.command, latest.id == command.id, latest.running,
                                  latest.generation == command.generation, store.configuration.uploadConsent,
                                  let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id, lease.expiresAt > Date() else { return false }
                            if let scope = latest.messageScope {
                                guard store.stopGeneration == scope.stopGeneration,
                                      scope.id == messageContext?.scopeID,
                                      scope.matches(sessionID: latest.id, generation: latest.generation, task: latest.task) else { return false }
                                if ["message_paste", "message_send"].contains(proposal.purpose) {
                                    guard scope.launch.permitsFrame(capturedAt: frame.capturedAt, capturedUptime: frame.capturedUptime),
                                          proposal.purpose != "message_paste" || scope.clipboardIsReady else { return false }
                                } else if SafetyGate.rejection(proposal, task: latest.task, config: configuration, command: latest,
                                    frameID: frame.id, capturedAt: frame.capturedAt, capturedUptime: frame.capturedUptime, absoluteContext: absoluteContext) != nil {
                                    preDispatchFrameFailure = "微信启动或画面校验状态已变化，旧提案已丢弃"
                                    return false
                                }
                            }
                            if let reason = Self.frameObservationFailure(frame: frame, deadline: deadline, requiresPointerGeometry: requiresPointerGeometry) {
                                preDispatchFrameFailure = reason
                                return false
                            }
                            return true
                        }, sessionAuthorized: {
                            if let reason = Self.sessionAuthorizationFailure(command: command, expectedStopGeneration: expectedStopGeneration) {
                                cancellationReason = reason
                                return false
                            }
                            return true
                        }, reserveMessageAction: {
                            if ["message_paste", "message_send"].contains(proposal.purpose) {
                                guard let messageContext else { throw PilotError.message("缺少消息范围") }
                                try store.reserveMessageAction(purpose: proposal.purpose, context: messageContext)
                                reservedMessageAttempt = true
                            }
                        }) } catch is HardwareClient.PreDispatchFailure {
                            try Task.checkCancellation()
                            try requireSession(command)
                            if agent.recoverBeforeDispatch("Hardware client's final pre-POST deadline expired; no reservation or HID sent.") {
                                await self.publish("观察", "硬件检查后截图已过期；未提交动作，等待新画面重新规划（最多重试两次）", steps: steps, sessionID: command.id, systemTask: task)
                                continue
                            }
                            throw FrameObservationFailure(reason: "硬件检查后截图已过期，已用完两次重新观察；未提交动作。")
                        } catch is CancellationError {
                            try Task.checkCancellation()
                            try requireSession(command)
                            if let reason = preDispatchFrameFailure {
                                // This flag is set only when a pre-POST Boolean
                                // guard rejected the request. No HID was submitted.
                                if !reservedMessageAttempt,
                                   agent.recoverBeforeDispatch("Pre-dispatch frame changed; no HID sent. Observe a new frame.") {
                                    await self.publish("观察", "派发前：\(reason)；未执行动作，等待新画面重新规划（最多重试两次）", steps: steps, sessionID: command.id, systemTask: task)
                                    continue
                                }
                                let limit = reservedMessageAttempt ? "消息尝试已消耗，不会自动重发。" : "已用完两次重新观察，未提交动作。"
                                throw FrameObservationFailure(reason: "派发前：\(reason)；" + limit)
                            }
                            throw CancellationError()
                        }
                        store.log("步骤\(steps + 1)：\(proposal.description)；后台协调模式硬件确认完成", sessionID: command.id)
                    }
                    let action = (try? JSONEncoder().encode(proposal)).flatMap { String(data: $0, encoding: .utf8) } ?? proposal.description
                    agent.record(action: action, outcome: proposal.type == .wait ? "No HID sent. Observe a newer screen." : "hardware_completed; verify UI effect in next observation")
                    steps += 1
                    task.progress.completedUnitCount = Int64(steps)
                    await self.publish("观察", "等待新的广播画面验证实际效果", steps: steps, sessionID: command.id, systemTask: task)
                    try await Task.sleep(nanoseconds: UInt64(max(2, min(30, configuration.frameInterval)) * 1_000_000_000))
                }
                await self.publish(completed ? "完成" : "停止", completed ? (command.messageScope == nil ? "AI认为完成，仍需你人工确认结果" : "新画面已显示本次消息；仅发送一次，未取得服务器送达回执") : "已到达步数或所选运行时长上限", steps: steps, sessionID: command.id, systemTask: task)
                self.revoke(sessionID: command.id)
            } catch is CancellationError {
                let terminal = store.status
                // Preserve the original stop reason, including one from the broadcast extension.
                // Cancellation alone does not identify an OS expiration.
                if terminal.sessionID != command.id || !["暂停", "停止", "完成"].contains(terminal.phase) {
                    let reason = cancellationReason ?? Self.sessionAuthorizationFailure(command: activeCommand, expectedStopGeneration: expectedStopGeneration)
                        ?? "后台执行任务已被取消（来源未记录），设备控制已撤销。"
                    await self.publish("停止", reason, steps: steps, sessionID: command.id, systemTask: task)
                }
                self.revoke(sessionID: command.id)
            } catch {
                store.log("后台会话停止：\(error.localizedDescription)", sessionID: command.id)
                await self.publish("暂停", error.localizedDescription, steps: steps, sessionID: command.id, systemTask: task, userMessage: publicFailureMessage)
                self.revoke(sessionID: command.id)
            }
            leaseWriter.cancel()
            self.revoke(sessionID: command.id)
            // An already-cancelled parent task must not immediately cancel the best-effort STOP request.
            // This independent request still has the hardware client's bounded network timeout.
            let cleanup = Task.detached(priority: .utility) {
                await hardware.stopRuntimeAndReport(sessionID: command.id, captureOwnerID: command.execution?.captureOwnerID)
            }
            await cleanup.value
            task.expirationHandler = nil
            task.setTaskCompleted(success: completed)
            if self.activeSessionID == command.id, self.schedulerID == task.identifier {
                self.schedulerID = nil; self.activeSessionID = nil; self.work = nil
            }
        }
    }

    private struct FrameObservationFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    nonisolated private static func sessionAuthorizationFailure(command: SessionCommand, expectedStopGeneration: String?) -> String? {
        let store = SharedStore.shared
        guard let current = store.command else { return "当前会话指令已不可用，后台执行已停止。" }
        guard current.id == command.id else { return "当前会话已更换，旧后台执行已停止。" }
        guard store.stopGeneration == expectedStopGeneration else { return "已收到停止请求，旧后台执行已撤销。" }
        guard current.running else { return "会话执行授权已撤销（running=false），后台执行已停止。" }
        guard current.generation == command.generation else { return "任务代次已变化，旧后台执行不能继续。" }
        guard store.configuration.uploadConsent else { return "屏幕上传许可已撤回，后台执行已停止。" }
        guard let execution = current.continuedExecution, execution.phase == .active,
              execution.stopGeneration == expectedStopGeneration else { return "后台执行尚未取得当前会话的执行权。" }
        guard current.authorizationIsCurrent(requireActive: true) else { return "会话已达执行期限，或首帧控制授权已失效。" }
        guard let lease = store.read("lease.json", as: ExecutionLease.self) else { return "后台协调租约已丢失，执行已停止。" }
        guard lease.sessionID == command.id, lease.expiresAt > Date() else { return "后台协调租约已失效，执行已停止。" }
        guard current.messageScope?.id == command.messageScope?.id else { return "消息范围已变化，旧后台执行不能继续。" }
        if let scope = current.messageScope {
            guard store.stopGeneration == scope.stopGeneration,
                  scope.matches(sessionID: current.id, generation: current.generation, task: current.task) else { return "消息范围或停止边界已失效。" }
            if scope.launch.phase == .failed { return scope.launch.failure ?? "系统未接受微信打开请求，本轮已停止。" }
        }
        return nil
    }
    nonisolated private static func frameObservationFailure(frame: SharedFrame, deadline: Date, requiresPointerGeometry: Bool = false) -> String? {
        guard Date() < deadline else { return "截图已过期" }
        guard let latest = SharedStore.shared.read("frame.json", as: SharedFrame.self), latest.sessionID == frame.sessionID else { return "暂未取得当前会话的新广播画面" }
        if requiresPointerGeometry {
            guard let geometry = frame.geometry, let latestGeometry = latest.geometry,
                  geometry.hasSameCoordinateSpace(as: latestGeometry) else {
                return "屏幕方向或截图尺寸在规划期间改变，旧指针动作已丢弃"
            }
        }
        guard Date().timeIntervalSince(latest.capturedAt) < 2.5 else { return "最新广播画面已过期" }
        guard !frame.fingerprint.isEmpty, frame.fingerprint.count == latest.fingerprint.count else { return "画面变化检测数据暂不可用" }
        guard Self.stable(frame, latest) else { return "广播画面已变化" }
        return nil
    }
    nonisolated private static func stable(_ decision: SharedFrame, _ latest: SharedFrame) -> Bool {
        guard !decision.fingerprint.isEmpty, decision.fingerprint.count == latest.fingerprint.count,
              Date().timeIntervalSince(latest.capturedAt) < 2.5 else { return false }
        let difference = zip(decision.fingerprint, latest.fingerprint).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(difference) / Double(decision.fingerprint.count * 255) < 0.015
    }
    @available(iOS 26.0, *)
    private func publish(_ phase: String, _ detail: String, steps: Int, sessionID: String, systemTask: BGContinuedProcessingTask, userMessage: String? = nil) async {
        guard SharedStore.shared.command?.id == sessionID else { return }
        if SharedStore.shared.status.sessionID == sessionID, SharedStore.shared.status.phase == "请核实硬件停止" { return }
        SharedStore.shared.log("\(phase)：\(detail)", sessionID: sessionID)
        try? SharedStore.shared.write(PilotStatus(phase: phase, detail: detail, steps: steps, sessionID: sessionID, userMessage: userMessage), to: "status.json")
        systemTask.updateTitle("SightLatch · \(phase)", subtitle: "\(steps)步 · \(SharedStore.shared.command?.isUnlimited == true ? "不限时运行" : "按所选时长运行")")
        PilotActivityManager.shared.publish(SharedStore.shared.status, running: SharedStore.shared.command?.running == true)
    }
}
