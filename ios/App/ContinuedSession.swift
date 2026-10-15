import Foundation
import BackgroundTasks
import ActivityKit

// Optional iOS26 path. This task actually performs AI inference, safety validation and LAN dispatch.
// It is not a blank polling task, audio hack, or promise of unlimited background execution.
@MainActor
final class ContinuedSession {
    static let shared = ContinuedSession()
    private var work: Task<Void, Never>?
    private var schedulerID: String?
    private var activeSessionID: String?

    func start(command: SessionCommand, configuration: PilotConfiguration) async throws {
        guard #available(iOS 26.0, *) else { throw PilotError.message("可选后台协调模式需要iOS26及对应SDK") }
        guard work == nil, schedulerID == nil else { throw PilotError.message("已有后台会话尚未退出") }
        let identifier = (Bundle.main.bundleIdentifier ?? "com.example.HIDPilot") + ".agent." + UUID().uuidString
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                guard let self else { continued.setTaskCompleted(success: false); return }
                self.run(task: continued, command: command, configuration: configuration)
            }
        }
        guard accepted else { throw PilotError.message("系统未注册后台会话，请使用默认扩展模式或检查签名/配置") }
        schedulerID = identifier
        activeSessionID = command.id
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "HIDPilot有限操作会话", subtitle: "等待你开始系统广播")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            schedulerID = nil; activeSessionID = nil
            throw PilotError.message("系统拒绝后台会话，未开始自动操作：\(error.localizedDescription)")
        }
        do {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try Task.checkCancellation()
                guard SharedStore.shared.command?.running == true, SharedStore.shared.command?.id == command.id else { throw CancellationError() }
                if let lease = SharedStore.shared.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id, lease.expiresAt > Date() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw PilotError.message("后台任务未及时实际启动；已请求取消，不会静默继续。")
        } catch {
            if activeSessionID == command.id { cancel() }
            throw error
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
    private func run(task: BGContinuedProcessingTask, command: SessionCommand, configuration: PilotConfiguration) {
        guard schedulerID == task.identifier, activeSessionID == command.id else {
            task.setTaskCompleted(success: false); return
        }
        guard work == nil else { task.setTaskCompleted(success: false); return }
        guard SharedStore.shared.command?.id == command.id, SharedStore.shared.command?.running == true else {
            revoke(sessionID: command.id)
            schedulerID = nil; activeSessionID = nil
            task.setTaskCompleted(success: false); return
        }
        task.progress.totalUnitCount = Int64(min(50, max(1, configuration.maxSteps)))
        let requestID = task.identifier
        task.expirationHandler = { [weak self] in
            // Persist cancellation immediately; do not wait for an HTTP response to stop authorization.
            let store = SharedStore.shared
            try? store.updateCommand(sessionID: command.id) { $0.running = false }
            if let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id { store.remove("lease.json") }
            Task { @MainActor in
                guard let self, self.activeSessionID == command.id, self.schedulerID == requestID else { return }
                self.work?.cancel()
            }
        }
        let leaseWriter = Task { @MainActor in
            while !Task.isCancelled {
                guard let current = SharedStore.shared.command, current.id == command.id, current.running else { return }
                try? SharedStore.shared.write(ExecutionLease(sessionID: command.id, expiresAt: Date().addingTimeInterval(6)), to: "lease.json")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        work = Task { @MainActor [weak self] in
            guard let self else { leaseWriter.cancel(); task.setTaskCompleted(success: false); return }
            let store = SharedStore.shared
            let hardware = HardwareClient(configuration: configuration)
            var completed = false
            var steps = 0
            var lastFrameID = ""
            var lastProgressAt = Date()
            let end = command.createdAt.addingTimeInterval(300)
            do {
                await self.publish("待广播", "系统已实际启动可选后台任务；请主动开始广播", steps: 0, sessionID: command.id, systemTask: task)
                while Date() < end, steps < Int(task.progress.totalUnitCount) {
                    try Task.checkCancellation()
                    guard let current = store.command, current.id == command.id, current.running,
                          store.configuration.uploadConsent else { throw CancellationError() }
                    guard let frame = store.read("frame.json", as: SharedFrame.self), frame.sessionID == command.id,
                          frame.id != lastFrameID, Date().timeIntervalSince(frame.capturedAt) < 3 else {
                        if Date().timeIntervalSince(lastProgressAt) > 45 { throw PilotError.message("45秒未收到新广播画面，请结束后重新准备会话") }
                        try await Task.sleep(nanoseconds: 250_000_000); continue
                    }
                    lastFrameID = frame.id
                    lastProgressAt = Date()
                    let deadline = frame.capturedAt.addingTimeInterval(min(20, max(3, configuration.maxFrameAge)))
                    await self.publish("思考", "后台任务正在处理新帧", steps: steps, sessionID: command.id, systemTask: task)
                    try Task.checkCancellation()
                    guard self.authorized(command: command, frame: frame, deadline: deadline) else { throw CancellationError() }
                    let proposal = try await AIClient(configuration: configuration).propose(jpeg: frame.jpeg, task: command.task, frameID: frame.id)
                    try Task.checkCancellation()
                    guard self.authorized(command: command, frame: frame, deadline: deadline) else { throw PilotError.message("截图变化、过期或会话已取消；旧动作已丢弃") }
                    if let reason = SafetyGate.rejection(proposal, task: command.task, config: configuration) {
                        throw PilotError.message("\(reason)。请人工处理后重新开始后台会话；不会重放旧动作。")
                    }
                    if proposal.type == .done { completed = true; break }
                    if proposal.type != .wait {
                        let device = try await hardware.status()
                        await self.publish("执行", proposal.description, steps: steps, sessionID: command.id, systemTask: task)
                        try await hardware.send(proposal, expectedSession: device.session_id, frameDeadline: deadline, stillAuthorized: {
                            guard let latest = store.command, latest.id == command.id, latest.running,
                                  latest.generation == command.generation, store.configuration.uploadConsent,
                                  let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id, lease.expiresAt > Date(),
                                  let fresh = store.read("frame.json", as: SharedFrame.self), fresh.sessionID == command.id else { return false }
                            return Date() < deadline && Self.stable(frame, fresh)
                        })
                        store.log("步骤\(steps + 1)：\(proposal.description)；后台协调模式硬件确认完成")
                    }
                    steps += 1
                    task.progress.completedUnitCount = Int64(steps)
                    await self.publish("观察", "等待新的广播画面验证实际效果", steps: steps, sessionID: command.id, systemTask: task)
                    try await Task.sleep(nanoseconds: UInt64(max(2, min(30, configuration.frameInterval)) * 1_000_000_000))
                }
                await self.publish("停止", completed ? "AI认为完成，仍需你人工确认结果" : "已到达步数或五分钟上限", steps: steps, sessionID: command.id, systemTask: task)
            } catch is CancellationError {
                await self.publish("停止", "后台任务已取消或系统撤销运行时间", steps: steps, sessionID: command.id, systemTask: task)
            } catch {
                store.log("后台会话停止：\(error.localizedDescription)")
                await self.publish("暂停", error.localizedDescription, steps: steps, sessionID: command.id, systemTask: task)
            }
            leaseWriter.cancel()
            self.revoke(sessionID: command.id)
            // An already-cancelled parent task must not immediately cancel the best-effort STOP request.
            // This independent request still has the hardware client's bounded network timeout.
            let cleanup = Task.detached(priority: .utility) { await hardware.stop() }
            await cleanup.value
            task.expirationHandler = nil
            task.setTaskCompleted(success: completed)
            if self.activeSessionID == command.id, self.schedulerID == task.identifier {
                self.schedulerID = nil; self.activeSessionID = nil; self.work = nil
            }
        }
    }

    private func authorized(command: SessionCommand, frame: SharedFrame, deadline: Date) -> Bool {
        let store = SharedStore.shared
        guard let current = store.command, current.id == command.id, current.running, current.generation == command.generation,
              store.configuration.uploadConsent, Date() < deadline,
              let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == command.id, lease.expiresAt > Date(),
              let latest = store.read("frame.json", as: SharedFrame.self), latest.sessionID == command.id else { return false }
        return Self.stable(frame, latest)
    }
    nonisolated private static func stable(_ decision: SharedFrame, _ latest: SharedFrame) -> Bool {
        guard !decision.fingerprint.isEmpty, decision.fingerprint.count == latest.fingerprint.count,
              Date().timeIntervalSince(latest.capturedAt) < 2.5 else { return false }
        let difference = zip(decision.fingerprint, latest.fingerprint).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(difference) / Double(decision.fingerprint.count * 255) < 0.015
    }
    @available(iOS 26.0, *)
    private func publish(_ phase: String, _ detail: String, steps: Int, sessionID: String, systemTask: BGContinuedProcessingTask) async {
        guard SharedStore.shared.command?.id == sessionID else { return }
        try? SharedStore.shared.write(PilotStatus(phase: phase, detail: detail, steps: steps, sessionID: sessionID), to: "status.json")
        systemTask.updateTitle("HIDPilot · \(phase)", subtitle: "\(steps)步 · 五分钟有界会话")
        for activity in Activity<PilotActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.update(ActivityContent(state: .init(phase: phase, steps: steps, updatedAt: Date()), staleDate: Date().addingTimeInterval(15)))
        }
    }
}
