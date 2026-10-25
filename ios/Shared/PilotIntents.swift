import AppIntents
import ActivityKit
import Foundation

struct AnswerPilotClarificationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "回答 SightLatch"
    static var description = IntentDescription("回答当前问题，随后读取新画面继续当前任务。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "会话") var sessionID: String
    @Parameter(title: "问题") var questionID: String
    @Parameter(title: "选项") var optionID: String
    init() {}
    init(sessionID: String, questionID: String, optionID: String) {
        self.sessionID = sessionID
        self.questionID = questionID
        self.optionID = optionID
    }
    func perform() async throws -> some IntentResult {
        let store = SharedStore.shared
        _ = try store.resolveClarification(sessionID: sessionID, questionID: questionID, optionID: optionID)
        await PilotActivityPublisher.shared.publish(store.status)
        return .result()
    }
}

// Included in App and Widget targets. LiveActivityIntent asks the system to run perform in the App process.
// Never call perform directly from ReplayKit to pretend that it wakes the main App.
struct RefreshPilotStatusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "刷新 SightLatch 状态"
    static var description = IntentDescription("读取本机最新广播状态，并刷新当前实时活动。不会启动或恢复自动操作。")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        let snapshot = SharedStore.shared.status
        await PilotActivityPublisher.shared.publish(snapshot)
        return .result()
    }
}

struct StopPilotSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止 SightLatch 会话"
    static var description = IntentDescription("停止自动操作并解除 ESP32 控制。网络失败时请拔掉板子的 USB 电源；有物理急停的板型也可使用急停。")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = SharedStore.shared
        let snapshot = store.status
        let stopCommandID = store.command?.id
        var phase = "停止请求失败，请急停"
        var sessionID = snapshot.sessionID
        var localRevoked = true
        var hardwareConfirmed = false
        do {
            try store.invalidatePendingStarts()
            if let command = store.command {
                sessionID = command.id
                try store.updateCommand(sessionID: command.id) { $0.running = false }
            }
        } catch { localRevoked = false }
        store.remove("lease.json"); store.remove("frame.json")
        do {
            try await HardwareClient(configuration: store.configuration).stopAndVerify(expectedSessionID: stopCommandID)
            hardwareConfirmed = true
            phase = localRevoked ? "停止" : "硬件已停止，请结束广播"
        } catch {
            phase = localRevoked ? "停止未确认，请急停" : "停止请求失败，请急停"
        }
        let detail = hardwareConfirmed ? "设备已停止，请结束屏幕共享。" : "设备停止尚未确认，请断开板子电源并结束屏幕共享。"
        // Keep foreground refresh from replacing a stop warning with an older observing snapshot.
        if store.command?.id == sessionID {
            try? store.write(PilotStatus(phase: phase, detail: detail, steps: snapshot.steps, sessionID: sessionID), to: "status.json")
        }
        await PilotActivityPublisher.shared.publish(PilotStatus(phase: phase,
            detail: detail, steps: snapshot.steps, sessionID: sessionID), running: false)
        if hardwareConfirmed { await PilotActivityPublisher.shared.finishAfterHardwareStop(sessionID: sessionID) }
        // An unconfirmed STOP keeps the warning and its working stop control visible.
        return .result(dialog: "\(phase)。\(detail)")
    }
}
