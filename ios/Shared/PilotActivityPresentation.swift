import Foundation

/// Closed presentation states; arbitrary task/model/screenshot strings stay in the app.
enum PilotActivityStage: String {
    case ready, starting, observing, planning, executing, needsInput, failed, completed, stopped, unknown
    init(phase: String) {
        switch phase {
        case "待广播", "准备": self = .ready
        case "启动", "启动控制": self = .starting
        case "观察", "广播中": self = .observing
        case "规划", "思考": self = .planning
        case "执行": self = .executing
        case "暂停", "需输入", "等待用户", "需确认", "等待确认": self = .needsInput
        case "硬件已停止，请结束广播": self = .failed
        case "完成", "已完成": self = .completed
        case "停止", "硬件已解除ARM": self = .stopped
        default:
            self = phase.contains("失败") || phase.contains("急停") || phase.contains("未确认") || phase.contains("核实") ? .failed : .unknown
        }
    }
    var title: String {
        switch self {
        case .ready: return "等待开始共享"
        case .starting: return "准备设备控制"
        case .observing: return "查看屏幕"
        case .planning: return "规划下一步"
        case .executing: return "执行操作"
        case .needsInput: return "需要你看一下"
        case .failed: return "请检查会话"
        case .completed: return "任务已结束"
        case .stopped: return "自动操作已停止"
        case .unknown: return "会话状态"
        }
    }
    var symbol: String {
        switch self {
        case .ready: return "record.circle"
        case .starting: return "link"
        case .observing: return "eye"
        case .planning: return "sparkles"
        case .executing: return "cursorarrow.motionlines"
        case .needsInput: return "bubble.left.and.bubble.right.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    var summary: String {
        switch self {
        case .ready: return "从系统开始屏幕共享；收到真实画面后开始执行计时。"
        case .starting: return "已收到共享画面，正在确认本次设备控制。"
        case .needsInput: return "打开聊天查看原因；不会自动确认敏感操作。"
        case .failed: return "打开聊天检查；停止未确认时请物理急停。"
        case .completed, .stopped: return "请从系统结束屏幕广播；物理急停始终优先。"
        default: return "仅显示进度摘要；打开聊天查看实际操作记录。"
        }
    }
    var needsAttention: Bool { self == .needsInput || self == .failed || self == .completed }
    var isTerminal: Bool { self == .completed || self == .stopped }
}

/// A semantic summary of an AI/harness request, never an excerpt from its reason.
enum PilotActivityNotice: String, Codable {
    case recipient, draft, focus, target, confidence, screen, connection, permission, help, stopUncertain, finished
    static func classify(phase: String, detail: String) -> Self? {
        let stage = PilotActivityStage(phase: phase)
        if stage == .completed { return .finished }
        guard stage == .needsInput || stage == .failed else { return nil }
        let text = (phase + " " + detail).lowercased()
        // Conditional emergency instructions in an ordinary detail do not prove
        // that STOP failed. Classify explicit failure phases, not quoted history.
        if phase.contains("停止未确认") || phase.contains("未确认硬件停止") || phase.contains("请核实硬件停止") || phase.contains("停止请求失败") || phase.contains("急停") { return .stopUncertain }
        if ["收件人", "联系人", "recipient", "目标聊天"].contains(where: text.contains) { return .recipient }
        if ["正文", "草稿", "composer text"].contains(where: text.contains) { return .draft }
        if ["聚焦", "焦点", "focused"].contains(where: text.contains) { return .focus }
        if ["置信度", "把握不足", "confidence"].contains(where: text.contains) { return .confidence }
        if ["连接", "网络", "蓝牙", "设备"].contains(where: text.contains) { return .connection }
        if ["授权", "许可", "权限"].contains(where: text.contains) { return .permission }
        if ["截图", "画面", "屏幕", "广播", "新帧"].contains(where: text.contains) { return .screen }
        if ["按钮", "目标", "定位", "遮挡"].contains(where: text.contains) { return .target }
        return .help
    }
    var text: String {
        switch self {
        case .recipient: return "目标聊天尚未确认，请查看当前步骤"
        case .draft: return "消息正文需要核对，未继续发送"
        case .focus: return "输入位置需要确认，已暂停操作"
        case .target: return "当前操作目标需要你确认"
        case .confidence: return "操作依据不够清晰，已暂停执行"
        case .screen: return "共享画面需要检查，旧动作不会重放"
        case .connection: return "设备连接需要检查，已暂停控制"
        case .permission: return "本次操作授权需要你处理"
        case .help: return "AI 需要你处理当前步骤，点按查看说明"
        case .stopUncertain: return "设备停止尚未确认，请打开 App 核实"
        case .finished: return "本轮已结束，请检查实际结果"
        }
    }
    var alertTitle: String {
        switch self {
        case .finished: return "SightLatch 任务已结束"
        case .stopUncertain: return "SightLatch 停止需要核实"
        default: return "SightLatch 需要你处理"
        }
    }
}

/// Keep recipients, message bodies and arbitrary model text off the Lock Screen.
enum PilotActivitySummary {
    static func task(_ goal: String) -> String {
        let text = goal.lowercased()
        if text.contains("微信") || text.contains("wechat") {
            return text.contains("发送") || text.contains("发消息") || text.contains("send") ? "微信消息任务" : "微信操作任务"
        }
        return "屏幕操作任务"
    }

    static func action(phase: String, detail: String) -> String {
        let stage = PilotActivityStage(phase: phase)
        switch stage {
        case .ready: return "等待系统屏幕广播"
        case .starting: return "正在准备设备控制"
        case .observing: return "读取新画面，核实实际结果"
        case .planning: return "根据当前画面选择下一步"
        case .executing:
            if detail == "按键 SEND_MESSAGE_ENTER" { return "发送本次授权消息" }
            if detail == "按键 PASTE_MESSAGE" { return "填入本次授权正文" }
            if detail.hasPrefix("定位并点击") { return "定位并点击当前目标" }
            if detail.hasPrefix("定位到当前画面") { return "定位当前目标" }
            if detail.hasPrefix("相对移动") { return "调整指针位置" }
            if detail.hasPrefix("点击") { return "点击当前目标" }
            if detail.hasPrefix("滚动") { return "滚动当前页面" }
            if detail.hasPrefix("按键") { return "使用键盘快捷键" }
            if detail.hasPrefix("输入文本") { return "准备文字输入" }
            return "执行当前单步操作"
        case .needsInput: return "已暂停，等待你处理"
        case .failed: return "停止状态需要核实"
        case .completed: return "请检查任务的实际结果"
        case .stopped: return "设备控制已停止"
        case .unknown: return "打开聊天查看最新状态"
        }
    }

    /// This is an explicitly provided brief AI message, never a technical detail,
    /// full model response, screenshot transcript, or provider reasoning.
    static func userMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = raw.unicodeScalars.map { scalar -> String in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return " "
            default: return String(scalar)
            }
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty, !clean.hasPrefix("{"), !clean.hasPrefix("[{"), !clean.hasPrefix("[\""),
              !clean.hasPrefix("```"), !clean.lowercased().contains("<think>"), !clean.lowercased().contains("<analysis>") else { return nil }
        var safe = clean
        let patterns = [#"(?i)\b(?:bearer\s+|(?:token|api[_ -]?key|password)\s*[:=]\s*)[^\s，。；;]+"#,
                        #"(?:密码|密钥|令牌)\s*[:=：]\s*[^\s，。；;]+"#,
                        #"(?i)\b(?:sk-[a-z0-9_-]{12,}|[a-z0-9_-]{32,})\b"#,
                        #"(?i)https?://[^\s，。；;]+"#]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            safe = expression.stringByReplacingMatches(in: safe, range: NSRange(safe.startIndex..., in: safe), withTemplate: "[内容已隐藏]")
        }
        return safe.count > 80 ? String(safe.prefix(79)) + "…" : safe
    }

    /// Display only. Never derives a deadline from preparation, the current date,
    /// or an ActivityKit update; the capture owner persists both execution dates.
    static func executionInterval(startedAt: Date?, expiresAt: Date?) -> ClosedRange<Date>? {
        guard let startedAt, let expiresAt,
              startedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > startedAt else { return nil }
        return startedAt...expiresAt
    }

    static func presentationPhase(_ phase: String, awaitingCapture: Bool,
                                  startingHardware: Bool = false, executionActive: Bool = false) -> String {
        let stage = PilotActivityStage(phase: phase)
        let ordinary = [.ready, .starting, .observing, .planning, .executing].contains(stage)
        if awaitingCapture, ordinary { return "待广播" }
        if startingHardware, ordinary { return "启动控制" }
        if executionActive, stage == .ready || stage == .starting { return "观察" }
        return phase
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import CoreFoundation

/// An advisory signal only. It can notify an already-running main app; it cannot
/// wake a suspended process, grant execution time, or resume device control.
enum PilotActivityRelay {
    static let notification = CFNotificationName("com.sightlatch.activity-status-changed" as CFString)
    static func statusDidChange(_ status: PilotStatus) {
        Task { await PilotActivityPublisher.shared.publish(status) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notification, nil, nil, true)
    }
}

final class PilotActivityChangeObserver {
    private let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<PilotActivityChangeObserver>.fromOpaque(observer).takeUnretainedValue().changed()
            }, PilotActivityRelay.notification.rawValue, nil, .deliverImmediately)
    }
    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), PilotActivityRelay.notification, nil)
    }
}

struct PilotActivityDeliveryDiagnostic: Codable {
    var sessionID: String
    var source: String
    var phase: String
    var steps: Int
    var matchedActivities: Int
    var submitted: Bool
    var alertRequested: Bool
    var ended: Bool? = nil
    var at = Date()
}

/// Used by the app and the capture extension. It only updates existing activities.
/// A zero match is recorded instead of claiming an extension update succeeded.
actor PilotActivityPublisher {
    static let shared = PilotActivityPublisher()
    private var lastState: [String: PilotActivityAttributes.ContentState] = [:]

    static func state(_ status: PilotStatus, command: SessionCommand?, running: Bool) -> PilotActivityAttributes.ContentState {
        let command = command?.id == status.sessionID ? command : nil
        let sourcePhase = running && command?.pendingClarification != nil ? "等待用户" :
            (!running && [.ready, .starting, .observing, .planning, .executing].contains(PilotActivityStage(phase: status.phase)) ? "停止" : status.phase)
        let phase = PilotActivitySummary.presentationPhase(sourcePhase,
            awaitingCapture: running && command?.execution?.phase == .awaitingCapture,
            startingHardware: running && command?.execution?.phase == .startingHardware,
            executionActive: running && command?.execution?.phase == .active)
        let active = running && command?.execution?.phase == .active
        let start = active ? command?.executionStartedAt : nil
        let end = active ? command?.execution?.expiresAt : nil
        let interval = PilotActivitySummary.executionInterval(startedAt: start, expiresAt: end)
        let notice = PilotActivityNotice.classify(phase: phase, detail: status.detail)
        return .init(phase: phase, steps: max(0, status.steps), updatedAt: status.updatedAt,
            actionSummary: PilotActivitySummary.action(phase: phase, detail: status.detail),
            executionStartedAt: start, executionExpiresAt: interval?.upperBound,
            isUnlimited: active && command?.execution?.isUnlimited == true && start != nil && end == nil,
            eventID: "\(status.updatedAt.timeIntervalSince1970):\(status.steps):\(PilotActivityStage(phase: phase).rawValue)",
            noticeCode: notice?.rawValue, running: running,
            noticeMessage: PilotActivityStage(phase: phase).needsAttention ? PilotActivitySummary.userMessage(command?.pendingClarification?.question ?? status.userMessage) : nil,
            clarificationID: running ? command?.pendingClarification?.id : nil,
            clarificationOptions: running ? command?.pendingClarification?.options.map { PilotClarificationAction(id: $0.id, title: $0.title) } : nil)
    }

    /// Called only after the hardware client's verified STOP receipt, never from
    /// a timer or from absence of an error record. Attention states remain open.
    func finishAfterHardwareStop(sessionID: String) async {
        let store = SharedStore.shared
        let status = store.status
        guard status.sessionID == sessionID, PilotActivityStage(phase: status.phase).isTerminal else { return }
        await publish(status, running: false)
        let latest = store.status
        guard latest.sessionID == sessionID, latest.updatedAt == status.updatedAt,
              PilotActivityStage(phase: latest.phase).isTerminal else { return }
        let state = Self.state(latest, command: store.command, running: false)
        let activities = Activity<PilotActivityAttributes>.activities.filter { $0.attributes.sessionID == sessionID }
        for activity in activities {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(900)), timestamp: latest.updatedAt)
        }
        let source = Bundle.main.bundleURL.pathExtension == "appex" ? "extension" : "app"
        let diagnostic = PilotActivityDeliveryDiagnostic(sessionID: sessionID, source: source,
            phase: PilotActivityStage(phase: state.phase).rawValue, steps: state.steps,
            matchedActivities: activities.count, submitted: !activities.isEmpty, alertRequested: false, ended: !activities.isEmpty)
        try? store.write(diagnostic, to: "activity-publication-\(source).json")
    }

    func publish(_ status: PilotStatus, running suppliedRunning: Bool? = nil) async {
        guard !status.sessionID.isEmpty else { return }
        let store = SharedStore.shared
        let command = store.command
        guard command?.id == status.sessionID else { return } // A stale owner cannot update a replacement's surface.
        let running = command?.running == true && suppliedRunning != false
        let state = Self.state(status, command: command, running: running)
        guard lastState[status.sessionID].map({ $0.updatedAt > state.updatedAt || $0 == state }) != true else { return }
        let activities = Activity<PilotActivityAttributes>.activities.filter { $0.attributes.sessionID == status.sessionID }
        let stage = PilotActivityStage(phase: state.phase)
        var diagnostic = PilotActivityDeliveryDiagnostic(sessionID: status.sessionID,
            source: Bundle.main.bundleURL.pathExtension == "appex" ? "extension" : "app",
            phase: stage.rawValue, steps: state.steps, matchedActivities: activities.count, submitted: false, alertRequested: false)
        guard !activities.isEmpty else { try? store.write(diagnostic, to: "activity-publication-\(diagnostic.source).json"); return }
        var alert: AlertConfiguration?
        if stage.needsAttention, let notice = state.noticeCode.flatMap(PilotActivityNotice.init(rawValue:)) {
            let key = state.clarificationID ?? "\(command?.generation ?? 0):\(stage.rawValue):\(state.steps):\(notice.rawValue)"
            if store.claimActivityAlert(sessionID: status.sessionID, key: key) {
                alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: notice.alertTitle),
                    body: LocalizedStringResource(stringLiteral: state.noticeMessage ?? notice.text), sound: .default)
            }
        }
        lastState[status.sessionID] = state
        // Keep the non-running result visible: hardware STOP completes after the
        // task's terminal status and can still fail. An ActivityKit-ended surface
        // cannot receive that critical later warning. New preparation ends the
        // previous session. Verified STOP explicitly ends a completed/stopped
        // result through finishAfterHardwareStop; the user may also dismiss it.
        for activity in activities {
            let content = ActivityContent(state: state, staleDate: stage.isTerminal ? nil : state.updatedAt.addingTimeInterval(45), relevanceScore: stage.needsAttention ? 1 : 0.8)
            await activity.update(content, alertConfiguration: alert, timestamp: state.updatedAt)
        }
        diagnostic.submitted = true; diagnostic.alertRequested = alert != nil
        try? store.write(diagnostic, to: "activity-publication-\(diagnostic.source).json")
    }
}
#endif
