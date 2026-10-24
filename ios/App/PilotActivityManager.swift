import ActivityKit
import Foundation
import Combine
import UIKit

/// Starts only in the foreground; real status publications share one app/extension
/// relay. ActivityKit and Darwin notifications never keep this process alive.
@MainActor
final class PilotActivityManager: ObservableObject {
    enum Availability { case ready, waitingForForeground, disabled, active, failed, ended }
    static let shared = PilotActivityManager()
    @Published private(set) var message = ""
    @Published private(set) var availability: Availability = .ready
    private var activityChanges: PilotActivityChangeObserver?
    private var stateObservers: [String: Task<Void, Never>] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private var deferredStart: (id: String, stopGeneration: String?)?
    // The tuple preserves an explicitly submitted nil fence; it is never
    // replaced with the latest global STOP value when retrying an old session.
    private var submittedStart: (id: String, stopGeneration: String?)?
    private var startGeneration = UUID()

    private init() {
        activityChanges = PilotActivityChangeObserver { [weak self] in
            Task { @MainActor [weak self] in
                let store = SharedStore.shared
                self?.publish(store.status, running: store.command?.running == true)
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let deferred = self.deferredStart else { return }
                guard self.isCurrent(deferred.id, stopGeneration: deferred.stopGeneration) else {
                    self.deferredStart = nil; return
                }
                await self.start(sessionID: deferred.id, expectedStopGeneration: deferred.stopGeneration)
            }
        }
    }

    /// Returns a user-facing warning, never aborting the authorized screen task.
    @discardableResult
    func start(sessionID: String, expectedStopGeneration: String?) async -> String? {
        let token = UUID(); startGeneration = token
        let fence = expectedStopGeneration
        guard isCurrent(sessionID, stopGeneration: fence) else {
            deferredStart = nil
            return report("会话已停止，未创建实时活动。", as: .ended)
        }
        submittedStart = (sessionID, fence)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            deferredStart = nil
            return report("实时活动未获允许。请在系统设置 → SightLatch → 实时活动中开启。", as: .disabled)
        }
        guard UIApplication.shared.applicationState == .active else {
            return deferUntilForeground(sessionID, fence: fence)
        }
        // A single session owns this surface; old tasks cannot linger as active controls.
        for activity in Activity<PilotActivityAttributes>.activities where activity.attributes.sessionID != sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
            guard startGeneration == token, isCurrent(sessionID, stopGeneration: fence) else { return nil }
        }
        // The system broadcast panel may have become visible while ending an older activity.
        guard startGeneration == token, isCurrent(sessionID, stopGeneration: fence) else { return nil }
        guard UIApplication.shared.applicationState == .active else {
            return deferUntilForeground(sessionID, fence: fence)
        }
        if let existing = Activity<PilotActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) {
            deferredStart = nil; observe(existing)
            report("实时活动已向系统注册。可在锁屏查看，灵动岛的显示位置由系统决定。", as: .active)
            return nil
        }
        guard let command = SharedStore.shared.command, command.id == sessionID else { return nil }
        let snapshot = SharedStore.shared.status
        let status = snapshot.sessionID == sessionID ? snapshot : PilotStatus(phase: "待广播", detail: "", steps: 0, sessionID: sessionID)
        let state = contentState(status)
        let attributes = PilotActivityAttributes(sessionID: sessionID,
            taskSummary: PilotActivitySummary.task(command.task),
            startedAt: command.execution?.phase == .active ? command.executionStartedAt : nil)
        do {
            // Check both sides of request: another process can persist STOP
            // even though this MainActor segment does not suspend.
            guard isCurrent(sessionID, stopGeneration: fence), UIApplication.shared.applicationState == .active else {
                return deferUntilForeground(sessionID, fence: fence)
            }
            let activity = try Activity.request(attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(45), relevanceScore: 1), pushType: nil)
            guard startGeneration == token, isCurrent(sessionID, stopGeneration: fence) else {
                if startGeneration == token { deferredStart = nil }
                await activity.end(nil, dismissalPolicy: .immediate)
                return nil
            }
            deferredStart = nil
            observe(activity)
            report("实时活动已向系统注册。可在锁屏查看，长按灵动岛可展开。", as: .active)
            return nil
        } catch {
            if let activityError = error as? ActivityAuthorizationError, activityError == .visibility {
                return deferUntilForeground(sessionID, fence: fence)
            }
            deferredStart = nil
            return report(Self.failureMessage(error), as: .failed)
        }
    }

    @discardableResult
    func retry() async -> String? {
        guard let command = SharedStore.shared.command, command.running else {
            return report("当前没有进行中的会话。", as: .ended)
        }
        if let submitted = submittedStart, submitted.id == command.id {
            return await start(sessionID: command.id, expectedStopGeneration: submitted.stopGeneration)
        }
        if let scope = command.messageScope,
           scope.matches(sessionID: command.id, generation: command.generation, task: command.task) {
            return await start(sessionID: command.id, expectedStopGeneration: scope.stopGeneration)
        }
        return report("未保存本次实时活动的启动边界，请重新准备会话后再试。", as: .failed)
    }

    func publish(_ status: PilotStatus, running: Bool) {
        let status = Self.presentationStatus(status, running: running)
        guard !status.sessionID.isEmpty else { return }
        // Each actual thinking/tool boundary is submitted; one-second UI polling
        // of the same stored snapshot is deduplicated by the shared publisher.
        Task { await PilotActivityPublisher.shared.publish(status, running: running) }
    }

    private func deliver(_ status: PilotStatus, running: Bool) async {
        await PilotActivityPublisher.shared.publish(Self.presentationStatus(status, running: running), running: running)
    }

    func finish(sessionID: String, phase: String, steps: Int) async {
        if deferredStart?.id == sessionID { deferredStart = nil; startGeneration = UUID() }
        if submittedStart?.id == sessionID { submittedStart = nil }
        let stored = SharedStore.shared.status
        let status = stored.sessionID == sessionID && stored.phase == phase
            ? stored : PilotStatus(phase: phase, detail: "", steps: steps, sessionID: sessionID)
        // Unconfirmed hardware stops stay visible with a warning and working stop control.
        await deliver(status, running: !PilotActivityStage(phase: phase).isTerminal)
    }

    private func contentState(_ status: PilotStatus) -> PilotActivityAttributes.ContentState {
        let command = SharedStore.shared.command
        return PilotActivityPublisher.state(status, command: command, running: command?.id == status.sessionID && command?.running == true)
    }

    /// A revoked attempt cannot keep advertising a resumable task or time budget.
    /// Keep the original status/detail in the App; only this ActivityKit copy ends.
    static func presentationStatus(_ status: PilotStatus, running: Bool) -> PilotStatus {
        let activePhases = ["待广播", "准备", "启动", "启动控制", "观察", "广播中", "规划", "思考", "执行"]
        guard !running, activePhases.contains(status.phase) else { return status }
        var ended = status
        ended.phase = "停止"
        return ended
    }

    private func isCurrent(_ id: String, stopGeneration: String?) -> Bool {
        guard let command = SharedStore.shared.command else { return false }
        return !id.isEmpty && command.id == id && command.running && SharedStore.shared.configuration.uploadConsent
            && SharedStore.shared.stopGeneration == stopGeneration
    }

    private func deferUntilForeground(_ id: String, fence: String?) -> String {
        guard isCurrent(id, stopGeneration: fence) else {
            deferredStart = nil; return report("会话已停止，未创建实时活动。", as: .ended)
        }
        deferredStart = (id, fence)
        return report("实时活动尚未创建：系统要求 App 位于前台。回到 SightLatch 后会补充显示。", as: .waitingForForeground)
    }

    @discardableResult
    private func report(_ text: String, as state: Availability) -> String {
        availability = state; message = text; return text
    }

    private func observe(_ activity: Activity<PilotActivityAttributes>) {
        let id = activity.id
        guard stateObservers[id] == nil else { return }
        stateObservers[id] = Task { [weak self] in
            defer { self?.stateObservers[id] = nil }
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self else { return }
                // Do not let an older activity overwrite a newer session's diagnostics.
                guard SharedStore.shared.command?.id == activity.attributes.sessionID else { return }
                if state == .dismissed {
                    self.report("实时活动已被移除。可回到 App 重新显示。", as: .ended)
                    break
                } else if state == .ended {
                    self.report("实时活动已结束；任务摘要会暂时保留在锁屏。", as: .ended)
                    break
                }
            }
        }
    }

    static func failureMessage(_ error: Error) -> String {
        let remedy: String
        switch error as? ActivityAuthorizationError {
        case .denied: remedy = "请在系统设置 → SightLatch → 实时活动中开启。"
        case .unsupported: remedy = "当前系统或设备不支持实时活动。"
        case .globalMaximumExceeded, .targetMaximumExceeded: remedy = "系统的实时活动数量已达上限，请先结束其他活动后重试。"
        case .unsupportedTarget, .unentitled: remedy = "当前安装包的实时活动配置不可用，需要检查 Widget 扩展和本机签名。"
        case .visibility: remedy = "请回到 App 前台后重试。"
        case .attributesTooLarge: remedy = "活动数据超出系统限制，需要检查活动摘要。"
        default: remedy = "系统未能创建实时活动，请回到 App 重试。"
        }
        let detail = error as NSError
        return "实时活动未显示：\(remedy)（\(detail.domain) \(detail.code)：\(detail.localizedDescription)）"
    }
}
