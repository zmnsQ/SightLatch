import AppIntents
import ActivityKit
import Foundation

// Included in App and Widget targets. LiveActivityIntent asks the system to run perform in the App process.
// Never call perform directly from ReplayKit to pretend that it wakes the main App.
struct RefreshPilotStatusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "刷新HIDPilot状态"
    static var description = IntentDescription("读取本机最新广播状态，并刷新当前实时活动。不会启动或恢复自动操作。")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        let snapshot = SharedStore.shared.status
        for activity in Activity<PilotActivityAttributes>.activities where activity.attributes.sessionID == snapshot.sessionID {
            await activity.update(ActivityContent(state: .init(phase: snapshot.phase, steps: snapshot.steps, updatedAt: snapshot.updatedAt), staleDate: snapshot.updatedAt.addingTimeInterval(15)))
        }
        return .result()
    }
}

struct StopPilotSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止HIDPilot会话"
    static var description = IntentDescription("请求停止广播自动操作并解除ESP32硬件ARM。网络失败时仍需物理急停。")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        let store = SharedStore.shared
        let snapshot = store.status
        var phase = "停止请求失败，请急停"
        var sessionID = snapshot.sessionID
        var localRevoked = true
        do {
            if let command = store.command {
                sessionID = command.id
                try store.updateCommand(sessionID: command.id) { $0.running = false }
            }
        } catch { localRevoked = false }
        store.remove("lease.json"); store.remove("frame.json")
        do {
            try await HardwareClient(configuration: store.configuration).stopAndVerify()
            phase = localRevoked ? "硬件已解除ARM" : "硬件已停止，请结束广播"
        } catch {
            phase = localRevoked ? "停止未确认，请急停" : "停止请求失败，请急停"
        }
        for activity in Activity<PilotActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.update(ActivityContent(state: .init(phase: phase, steps: snapshot.steps, updatedAt: Date()), staleDate: Date().addingTimeInterval(15)))
        }
        // Keep the activity visible so a request is not mistaken for confirmed broadcast termination.
        return .result()
    }
}
