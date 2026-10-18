import ActivityKit
import Foundation

/// Main-app publisher shared by foreground polling and bounded continued processing.
/// ActivityKit does not keep this process alive. Suspended apps may show stale progress.
@MainActor
final class PilotActivityManager {
    static let shared = PilotActivityManager()
    private var pending: [String: Task<Void, Never>] = [:]
    private var latest: [String: (PilotStatus, Bool)] = [:]
    private var lastSent: [String: Date] = [:]
    private var lastState: [String: PilotActivityAttributes.ContentState] = [:]
    private var alerted: [String: Set<String>] = [:]
    private var ended = Set<String>()

    func start(sessionID: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let command = SharedStore.shared.command, command.id == sessionID, command.running else { return }
        // A single session owns this surface; old tasks cannot linger as active controls.
        for activity in Activity<PilotActivityAttributes>.activities where activity.attributes.sessionID != sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard !Activity<PilotActivityAttributes>.activities.contains(where: { $0.attributes.sessionID == sessionID }) else { return }
        // An external STOP may arrive while awaiting the end of an old activity.
        guard let current = SharedStore.shared.command, current.id == sessionID, current.running else { return }
        ended.remove(sessionID)
        let state = PilotActivityAttributes.ContentState(phase: "待广播", steps: 0, updatedAt: Date())
        _ = try? Activity.request(attributes: PilotActivityAttributes(sessionID: sessionID), content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(15)), pushType: nil)
    }

    func publish(_ status: PilotStatus, running: Bool) {
        let id = status.sessionID
        guard !id.isEmpty, !ended.contains(id) else { return }
        latest[id] = (status, running)
        let stage = PilotActivityStage(phase: status.phase)
        let previousStage = lastState[id].map { PilotActivityStage(phase: $0.phase) }
        let immediate = stage.isTerminal || (stage.needsAttention && stage != previousStage)
        if pending[id] != nil && !immediate { return } // Keep latest snapshot; one trailing update.
        pending[id]?.cancel()
        let delay = immediate ? 0 : max(0, 5 - Date().timeIntervalSince(lastSent[id] ?? .distantPast))
        pending[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.pending[id] = nil
            guard let (snapshot, active) = self.latest[id] else { return }
            await self.deliver(snapshot, running: active)
        }
    }

    private func deliver(_ status: PilotStatus, running: Bool) async {
        let id = status.sessionID
        guard !ended.contains(id) else { return }
        let stage = PilotActivityStage(phase: status.phase)
        let state = PilotActivityAttributes.ContentState(phase: status.phase, steps: status.steps, updatedAt: status.updatedAt)
        guard state != lastState[id] else { return }
        lastState[id] = state; lastSent[id] = Date()
        var alert: AlertConfiguration?
        if stage.needsAttention && alerted[id, default: []].insert(stage.rawValue).inserted {
            // Important transitions only, never an alert per tool call or frame.
            alert = AlertConfiguration(title: "SightLatch 有新进展", body: "打开聊天查看任务状态。", sound: .default)
        }
        let terminal = stage.isTerminal && !running
        if terminal { ended.insert(id) }
        for activity in Activity<PilotActivityAttributes>.activities where activity.attributes.sessionID == id {
            let content = ActivityContent(state: state, staleDate: terminal ? nil : status.updatedAt.addingTimeInterval(15))
            await activity.update(content, alertConfiguration: alert)
            if terminal { await activity.end(content, dismissalPolicy: .default) }
        }
    }

    func finish(sessionID: String, phase: String, steps: Int) async {
        pending[sessionID]?.cancel(); pending[sessionID] = nil
        latest[sessionID] = nil
        let status = PilotStatus(phase: phase, detail: "", steps: steps, sessionID: sessionID)
        // Unconfirmed hardware stops stay visible with a warning and working stop control.
        await deliver(status, running: !PilotActivityStage(phase: phase).isTerminal)
    }
}
