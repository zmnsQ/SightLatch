import Foundation

@main
struct PilotActivityPresentationTests {
    static func main() {
        let cases: [(String, PilotActivityStage)] = [
            ("待广播", .ready), ("启动", .starting), ("启动控制", .starting), ("观察", .observing), ("规划", .planning),
            ("执行", .executing), ("暂停", .needsInput), ("需输入", .needsInput),
            ("需确认", .needsInput), ("等待确认", .needsInput),
            ("停止未确认，请急停", .failed), ("请核实硬件停止", .failed),
            ("完成", .completed), ("硬件已解除ARM", .stopped), ("停止", .stopped),
            ("https://private.example/secret?token=abc", .unknown)
        ]
        for (phase, expected) in cases {
            let stage = PilotActivityStage(phase: phase)
            precondition(stage == expected, "Unexpected classification: \(phase)")
            precondition(!stage.title.isEmpty && !stage.symbol.isEmpty && !stage.summary.isEmpty)
            precondition(!stage.summary.contains("token=") && !stage.title.contains("private.example"))
        }
        precondition(!PilotActivityStage.needsInput.isTerminal)
        precondition(!PilotActivityStage.failed.isTerminal)
        precondition(PilotActivityStage.completed.isTerminal && PilotActivityStage.stopped.isTerminal)
        precondition(!PilotActivityStage.executing.needsAttention)
        precondition(PilotActivityStage.needsInput.needsAttention)
        precondition(PilotActivitySummary.task("微信给联系人发送不公开的正文") == "微信消息任务")
        precondition(PilotActivitySummary.task("WeChat open a chat") == "微信操作任务")
        precondition(PilotActivitySummary.task("https://private.example/secret?token=abc") == "屏幕操作任务")
        let actions = [
            ("相对移动 x=12, y=-3", "调整指针位置"), ("点击 left", "点击当前目标"),
            ("滚动 1", "滚动当前页面"), ("按键 PASTE_MESSAGE", "填入本次授权正文"), ("按键 SEND_MESSAGE_ENTER", "发送本次授权消息"),
            ("输入文本（9 字符）", "准备文字输入"), ("private recipient secret", "执行当前单步操作")
        ]
        for (detail, expected) in actions {
            precondition(PilotActivitySummary.action(phase: "执行", detail: detail) == expected)
        }
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = start.addingTimeInterval(300)
        precondition(PilotActivitySummary.executionInterval(startedAt: nil, expiresAt: nil) == nil,
                     "Preparation cannot manufacture an execution timer")
        precondition(PilotActivitySummary.executionInterval(startedAt: start, expiresAt: nil) == nil)
        precondition(PilotActivitySummary.executionInterval(startedAt: nil, expiresAt: deadline) == nil)
        let interval = PilotActivitySummary.executionInterval(startedAt: start, expiresAt: deadline)!
        precondition(interval.lowerBound == start && interval.upperBound == deadline)
        // A later rendering/update must retain the exact persisted deadline.
        precondition(PilotActivitySummary.executionInterval(startedAt: start, expiresAt: deadline) == interval)
        precondition(PilotActivitySummary.executionInterval(startedAt: start, expiresAt: start) == nil)
        precondition(PilotActivitySummary.executionInterval(startedAt: start, expiresAt: start.addingTimeInterval(-1)) == nil)
        precondition(PilotActivitySummary.executionInterval(startedAt: start, expiresAt: start.addingTimeInterval(3600)) != nil)
        precondition(PilotActivitySummary.executionInterval(startedAt: Date(timeIntervalSince1970: .nan), expiresAt: deadline) == nil)
        precondition(PilotActivitySummary.presentationPhase("观察", awaitingCapture: true) == "待广播")
        precondition(PilotActivitySummary.presentationPhase("待广播", awaitingCapture: true) == "待广播")
        precondition(PilotActivitySummary.presentationPhase("执行", awaitingCapture: false) == "执行")
        precondition(PilotActivitySummary.presentationPhase("观察", awaitingCapture: false, startingHardware: true) == "启动控制")
        precondition(PilotActivitySummary.presentationPhase("待广播", awaitingCapture: false, executionActive: true) == "观察")
        for phase in ["暂停", "完成", "停止", "停止未确认，请急停", "请核实硬件停止"] {
            precondition(PilotActivitySummary.presentationPhase(phase, awaitingCapture: true) == phase,
                         "Waiting copy must not hide terminal or hardware-stop warnings")
            precondition(PilotActivitySummary.presentationPhase(phase, awaitingCapture: false, startingHardware: true) == phase)
        }
        let canary = "secretToken_should_never_be_published person@example.invalid"
        let noticeCases: [(String, String, PilotActivityNotice)] = [
            ("暂停", "收件人尚未确认 " + canary, .recipient),
            ("暂停", "正文不匹配 " + canary, .draft),
            ("暂停", "焦点位置不明 " + canary, .focus),
            ("暂停", "置信度不足 " + canary, .confidence),
            ("暂停", "画面过期 " + canary, .screen),
            ("暂停", "网络失败 " + canary, .connection),
            ("暂停", "权限撤销 " + canary, .permission),
            ("暂停", "按钮遮挡 " + canary, .target),
            ("暂停", canary, .help),
            ("停止未确认，请急停", canary, .stopUncertain),
            ("完成", canary, .finished),
        ]
        for (phase, detail, expected) in noticeCases {
            let notice = PilotActivityNotice.classify(phase: phase, detail: detail)
            precondition(notice == expected)
            precondition(notice!.text.count > 8 && !notice!.text.contains(canary) && !notice!.alertTitle.contains(canary))
        }
        precondition(PilotActivityNotice.classify(phase: "执行", detail: canary) == nil)
        precondition(PilotActivityNotice.classify(phase: "暂停", detail: "无法继续当前步骤") == .help)
        let message = PilotActivitySummary.userMessage("请确认当前按钮；token=do-not-show 密码：hidden-password")!
        precondition(message.contains("请确认当前按钮") && !message.contains("do-not-show") && !message.contains("hidden-password"))
        precondition(PilotActivitySummary.userMessage(String(repeating: "说明", count: 100))!.count == 80)
        precondition(PilotActivitySummary.userMessage("<analysis>never display</analysis>") == nil)
        precondition(PilotActivitySummary.userMessage("{\"reason\":\"raw json\"}") == nil)
        precondition(PilotActivityNotice.classify(phase: "暂停", detail: "设备已停止；停止未确认时请急停") == .connection,
                     "Conditional emergency copy must not invent an uncertain STOP")
        let oldJSON = Data(#"{"phase":"待广播","steps":0,"updatedAt":1000}"#.utf8)
        let legacy = try! JSONDecoder().decode(PilotActivityAttributes.ContentState.self, from: oldJSON)
        precondition(legacy.executionStartedAt == nil && legacy.executionExpiresAt == nil)
        precondition(legacy.eventID == nil && legacy.noticeCode == nil && legacy.running == nil && legacy.isUnlimited == nil)
        let oldInitializer = PilotActivityAttributes.ContentState(phase: "待广播", steps: 0, updatedAt: start)
        precondition(oldInitializer.executionStartedAt == nil && oldInitializer.executionExpiresAt == nil)
        let active = PilotActivityAttributes.ContentState(phase: "观察", steps: 1, updatedAt: start,
            executionStartedAt: start, executionExpiresAt: deadline, isUnlimited: false, eventID: "event-1", noticeCode: "target", running: true)
        let roundTrip = try! JSONDecoder().decode(PilotActivityAttributes.ContentState.self, from: JSONEncoder().encode(active))
        precondition(roundTrip == active)
        print("PASS: activity stages/closed AI summaries/old JSON, persisted finite clock without fixed 300s display cap, warnings preserved")
    }
}
