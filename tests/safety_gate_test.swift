import Foundation

// Compile the production configuration, proposal and gate unchanged. No API or HID calls.
@main struct SafetyGateTests {
    static func proposal(_ kind: ActionProposal.Kind) -> ActionProposal {
        ActionProposal(type: kind, dx: kind == .move ? 8 : nil, dy: kind == .move ? 0 : nil,
            wheel: kind == .scroll ? 1 : nil, button: kind == .click ? "left" : nil,
            key: kind == .key ? "ESC" : nil, text: nil,
            purpose: "navigation", risk: "low", requiresConfirmation: false,
            reason: "查看当前界面", pointerVisible: true, highRisk: false, confidence: 0.95)
    }

    static func main() {
        var config = PilotConfiguration()
        config.allowLowRiskNavigation = true
        let goals = ["打开微信给文件传输助手发送消息：你好", "Open WeChat and send hello"]
        for goal in goals {
            for kind in [ActionProposal.Kind.move, .click, .scroll, .key, .wait, .done] {
                let action = proposal(kind)
                precondition(SafetyGate.rejection(action, task: goal, config: config) == nil,
                    "An eventual send goal must not reject an independently safe \(kind) step")
            }
            var search = proposal(.text)
            search.purpose = "search_input"; search.text = "WeChat"
            precondition(SafetyGate.rejection(search, task: goal, config: config) == nil)

            // Removing the goal from keyword matching must not authorize a send click,
            // even when a proposal incorrectly labels that click as low-risk navigation.
            for reason in ["点击发送按钮", "Send the message", "发布内容", "确认付款", "删除会话"] {
                var action = proposal(.click); action.reason = reason
                precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            }
            var action = proposal(.click)
            action.purpose = "send_message"
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            action = proposal(.click); action.risk = "high"
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            action = proposal(.click); action.highRisk = true
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            action = proposal(.click); action.requiresConfirmation = true
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)

            action = proposal(.key); action.key = "ENTER"
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            action = proposal(.text); action.text = "hello" // A message field is not a search field.
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            search.text = "你好"
            precondition(SafetyGate.rejection(search, task: goal, config: config) != nil)
            search.text = "send hello"
            precondition(SafetyGate.rejection(search, task: goal, config: config) != nil)
            precondition(SafetyGate.rejection(proposal(.ask_user), task: goal, config: config) != nil)

            action = proposal(.click); action.pointerVisible = false
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            action = proposal(.move); action.dx = 101
            precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            for confidence in [0.84, Double.nan, Double.infinity, 1.01] {
                action = proposal(.move); action.confidence = confidence
                precondition(SafetyGate.rejection(action, task: goal, config: config) != nil)
            }
        }
        config.allowLowRiskNavigation = false
        precondition(SafetyGate.rejection(proposal(.click), task: goals[0], config: config) != nil)
        checkRejectionDiagnostics()
        checkObservationWait()
        checkNavigationReobservation()
        checkAppLaunchScope()
        print("PASS: send goals permit safe navigation/observation; consequential actions, message input, Chinese text, ENTER, confidence and pointer guards remain restricted")
    }

    static func checkNavigationReobservation() {
        var config = PilotConfiguration(); config.allowLowRiskNavigation = true
        let goal = "打开微信给文件传输助手发送消息：你好"
        var command = SessionCommand(task: goal, running: true, createdAt: Date().addingTimeInterval(-3))
        command.messageScope = MessageScope(intent: MessageIntent.parse(goal)!, sessionID: command.id,
            generation: command.generation, expiresAt: command.createdAt.addingTimeInterval(300))
        command.messageScope!.launch.phase = .opened
        command.messageScope!.launch.visuallyEstablishedAt = Date().addingTimeInterval(-1)
        command.messageScope!.launch.visuallyEstablishedUptime = ProcessInfo.processInfo.systemUptime - 1
        command.messageScope!.launch.visuallyEstablishedFrameID = "verified-launch-frame"
        let capturedAt = Date(), uptime = ProcessInfo.processInfo.systemUptime
        var move = proposal(.move); move.confidence = 0.82
        move.reason = "微信当前为群聊，将指针向左上角返回按钮移动。"
        move.messageEvidence = .init(frameID: "current-frame", app: "微信", recipient: "当前群聊",
            recipientUnambiguous: false, composerFocused: false, composerText: "", sendButtonUnderPointer: false,
            outgoingText: "", newOutgoingMessage: false, deliveryState: "unknown")
        func eligible(_ action: ActionProposal, _ value: SessionCommand? = nil) -> Bool {
            SafetyGate.canReobserveLowConfidenceNavigationMove(action, config: config,
                command: value ?? command, frameID: "current-frame", capturedAt: capturedAt, capturedUptime: uptime)
        }
        precondition(eligible(move))
        precondition(SafetyGate.rejection(move, task: goal, config: config, command: command,
            frameID: "current-frame", capturedAt: capturedAt, capturedUptime: uptime) != nil,
            "Observation eligibility must never authorize the .82 HID proposal")
        for field in 0..<20 {
            var invalid = move
            switch field {
            case 0: invalid.type = .ask_user
            case 1: invalid.type = .click; invalid.button = "left"
            case 2: invalid.risk = "high"
            case 3: invalid.highRisk = true
            case 4: invalid.requiresConfirmation = true
            case 5: invalid.pointerVisible = false
            case 6: invalid.button = "left"
            case 7: invalid.key = "ESC"
            case 8: invalid.text = ""
            case 9: invalid.wheel = 0
            case 10: invalid.dx = nil
            case 11: invalid.dy = 101
            case 12: invalid.purpose = "app_launch_confirmation"
            case 13: invalid.purpose = "message_send"
            case 14: invalid.confidence = .nan
            case 15: invalid.confidence = -0.01
            case 16: invalid.confidence = 0.85
            case 17: invalid.messageEvidence!.app = "其它App"
            case 18: invalid.messageEvidence!.frameID = "old-frame"
            default: invalid.reason = "点击发送按钮"
            }
            precondition(!eligible(invalid), "Ineligible proposal entered navigation reobservation: \(field)")
        }
        var notLaunched = command; notLaunched.messageScope!.launch = MessageLaunch()
        precondition(!eligible(move, notLaunched))
        var pasted = command; pasted.messageScope!.pasteAttempted = true
        precondition(!eligible(move, pasted))
        var sent = command; sent.messageScope!.sendAttempted = true
        precondition(!eligible(move, sent))

        var agent = AgentSession(id: command.id, startedAt: command.createdAt, maxRounds: 20)
        try! agent.observe(frameID: "current-frame", capturedAt: capturedAt, fingerprint: Data([0]))
        precondition(agent.recoverBeforeDispatch("Move not executed; independently inspect a new frame."))
        var stopped = command; stopped.running = false
        precondition(!eligible(move, stopped)) // STOP does not consume or reset the retry budget.
        precondition(agent.recoverBeforeDispatch("Move not executed; independently inspect a new frame."))
        precondition(!agent.recoverBeforeDispatch("Move not executed; independently inspect a new frame."),
            "A third rejection must take the existing pause/STOP path")
        precondition(agent.rounds == 1 && agent.startedAt == command.createdAt)
        precondition(agent.limitReason(now: command.createdAt.addingTimeInterval(300)) != nil)
        precondition(move.confidence == 0.82)
        print("PASS: .82 clean navigation move permits only two fresh observations; HID threshold, other gates, one-shot stages, STOP and round/time budgets stay intact")
    }

    static func checkObservationWait() {
        var config = PilotConfiguration(); config.allowLowRiskNavigation = true
        var wait = proposal(.wait); wait.pointerVisible = false; wait.confidence = 0.6
        wait.reason = "等待系统转场"
        precondition(SafetyGate.rejection(wait, task: "打开微信", config: config) == nil)
        for confidence in [0.0, 0.6, 0.84, 1.0] {
            wait.confidence = confidence
            precondition(SafetyGate.rejection(wait, task: "打开微信", config: config) == nil)
        }
        for confidence in [Double.nan, Double.infinity, -0.01, 1.01] {
            var invalid = wait; invalid.confidence = confidence
            precondition(SafetyGate.rejection(invalid, task: "打开微信", config: config) != nil)
        }
        for field in 0..<12 {
            var invalid = wait
            switch field {
            case 0: invalid.dx = 0
            case 1: invalid.dy = 0
            case 2: invalid.wheel = 0
            case 3: invalid.button = "left"
            case 4: invalid.key = "ESC"
            case 5: invalid.text = ""
            case 6: invalid.risk = "unknown"
            case 7: invalid.highRisk = true
            case 8: invalid.requiresConfirmation = true
            case 9: invalid.confidence = .nan
            case 10: invalid.confidence = -0.01
            default: invalid.confidence = 1.01
            }
            precondition(SafetyGate.rejection(invalid, task: "打开微信", config: config) != nil)
        }
        for purpose in ["other", "message_verify", "app_launch_verify"] {
            var special = wait; special.confidence = 0.84; special.purpose = purpose
            precondition(SafetyGate.rejection(special, task: "打开微信", config: config) != nil)
        }
        let goal = "打开微信给文件传输助手发送消息：你好"
        var command = SessionCommand(task: goal, running: true)
        command.messageScope = MessageScope(intent: MessageIntent.parse(goal)!, sessionID: command.id,
            generation: command.generation, expiresAt: Date().addingTimeInterval(300))
        wait.confidence = 0.6
        precondition(SafetyGate.rejection(wait, task: goal, config: config, command: command,
            frameID: "fresh", capturedAt: Date(), capturedUptime: ProcessInfo.processInfo.systemUptime) == nil)
        command.running = false
        precondition(SafetyGate.rejection(wait, task: goal, config: config, command: command,
            frameID: "fresh", capturedAt: Date(), capturedUptime: ProcessInfo.processInfo.systemUptime) != nil)
        for key in ["TAB", "BACKSPACE", "ENTER"] {
            var unsupported = proposal(.key); unsupported.key = key
            precondition(SafetyGate.rejection(unsupported, task: "打开微信", config: config) != nil)
        }
        print("PASS: pure observation wait permits low confidence without pointer or HID; invalid payload/risk/confidence/scope and unsupported keys remain rejected")
    }

    static func checkRejectionDiagnostics() {
        var config = PilotConfiguration(); config.allowLowRiskNavigation = true
        var ask = proposal(.ask_user)
        ask.confidence = 0.2; ask.pointerVisible = false
        ask.reason = "无法辨认文件传输助手的入口，请确认当前页面。"
        let refusal = SafetyGate.rejection(ask, task: "打开微信", config: config)!
        precondition(refusal.contains(ask.reason) && refusal.contains("20%") && refusal.contains("未定位指针"))
        precondition(ask.description.contains(ask.reason) && ask.description != "ask_user")
        var move = proposal(.move); move.confidence = 0.84; move.reason = "指针与按钮边缘不清楚。"
        let low = SafetyGate.rejection(move, task: "打开微信", config: config)!
        precondition(low.contains(move.reason) && low.contains("84%") && low.contains("85%"))
        move.confidence = 0.85
        precondition(SafetyGate.rejection(move, task: "打开微信", config: config) == nil, "Confidence threshold must remain 0.85")
        ask.reason = "无法定位\n指针\u{202E} token=secret-value sk-abc123abc123abc123"
        let safe = ask.userFacingReason
        precondition(!safe.contains("\n") && !safe.contains("\u{202E}") && !safe.contains("secret-value") && !safe.contains("sk-abc123"))
        ask.reason = String(repeating: "原因", count: 200)
        precondition(ask.userFacingReason.count <= 181)
        ask.reason = "\u{0000}\n "
        precondition(ask.userFacingReason == "模型未提供可显示的简短原因。")
        ask.reason = "{\"reasoning\":\"private\"}"
        precondition(!ask.userFacingReason.contains("private"))
        ask.purpose = "https://private.example/?token=secret-value"; ask.risk = "secret-value"
        ask.text = "body-secret"; ask.key = "key-secret"; ask.button = "button-secret"
        let diagnostic = ask.rejectionDiagnostic(frameAge: 2.5)
        precondition(diagnostic.contains("phase=gate_rejected") && diagnostic.contains("confidence=0.200") && diagnostic.contains("pointerVisible=false"))
        precondition(diagnostic.contains("purpose=unrecognized") && diagnostic.contains("frameAgeSec=2.50"))
        for value in ["private.example", "secret-value", "body-secret", "key-secret", "button-secret", "reasoning"] {
            precondition(!diagnostic.contains(value), "Diagnostics may contain only closed metadata fields")
        }
        ask.confidence = .nan
        precondition(ask.userFacingAssessment.contains("数值无效"))
        precondition(ask.rejectionDiagnostic(frameAge: .infinity).contains("confidence=invalid"))
        precondition(SafetyGate.rejection(ask, task: "打开微信", config: config) != nil)
        print("PASS: ask_user/low-confidence causes, unchanged 0.85 threshold, bounded sanitized/redacted brief reasons and metadata-only rejection diagnostics")
    }

    static func checkAppLaunchScope() {
        let goal = "打开微信给文件传输助手发送消息：你好"
        var command = SessionCommand(task: goal, running: true)
        command.messageScope = MessageScope(intent: MessageIntent.parse(goal)!, sessionID: command.id,
            generation: command.generation, expiresAt: Date().addingTimeInterval(300))
        let config = PilotConfiguration() // The exact scoped handoff does not enable general navigation.
        func rejected(_ action: ActionProposal, _ value: SessionCommand? = command,
                      at: Date = Date(), uptime: Double? = ProcessInfo.processInfo.systemUptime) -> Bool {
            SafetyGate.rejection(action, task: goal, config: config, command: value,
                frameID: "launch-frame", capturedAt: at, capturedUptime: uptime) != nil
        }
        var confirmation = ActionProposal(type: .move, dx: 8, dy: 0,
            purpose: "app_launch_confirmation", risk: "low", requiresConfirmation: false,
            reason: "将指针移到当前微信打开按钮", pointerVisible: true, highRisk: false, confidence: 0.99,
            launchEvidence: .init(frameID: "launch-frame", targetApp: "微信", systemOpenConfirmation: true,
                dialogText: "在“微信”中打开？", openButtonText: "打开", openButtonUnderPointer: false,
                targetAppVisible: false, foregroundApp: "SightLatch"))
        for phase in [MessageLaunch.Phase.pending, .opening, .opened] {
            var value = command; value.messageScope!.launch.phase = phase
            precondition(!rejected(confirmation, value))
        }
        precondition(rejected(confirmation, nil))
        for field in 0..<13 {
            var invalid = confirmation
            switch field {
            case 0: invalid.launchEvidence!.frameID = "old-frame"
            case 1: invalid.launchEvidence!.targetApp = "另一个App"
            case 2: invalid.launchEvidence!.systemOpenConfirmation = false
            case 3: invalid.launchEvidence!.dialogText = "允许微信访问照片？"
            case 4: invalid.launchEvidence!.dialogText = "在微信中打开以确认支付？"
            case 5: invalid.launchEvidence!.openButtonText = "允许"
            case 6: invalid.pointerVisible = false
            case 7: invalid.dx = 101
            case 8: invalid.key = "ENTER"
            case 9: invalid.text = "hello"
            case 10: invalid.wheel = 1
            case 11: invalid.highRisk = true
            default: invalid.requiresConfirmation = true
            }
            precondition(rejected(invalid), "Invalid app-opening evidence escaped field \(field)")
        }
        for title in ["微信登录确认", "安装微信", "继续", "Open", "Open in WeChat and approve permission"] {
            var invalid = confirmation; invalid.launchEvidence!.dialogText = title
            precondition(rejected(invalid))
        }
        for title in ["Open in WeChat?", "“SightLatch”想要打开“微信”", "Open this page in ‘WeChat’?"] {
            var valid = confirmation; valid.launchEvidence!.dialogText = title
            valid.launchEvidence!.openButtonText = "Open"
            precondition(!rejected(valid))
        }
        for kind in [ActionProposal.Kind.scroll, .key, .text, .wait, .done, .ask_user] {
            var invalid = confirmation; invalid.type = kind
            precondition(rejected(invalid))
        }
        confirmation.type = .click; confirmation.dx = nil; confirmation.dy = nil; confirmation.button = "left"
        precondition(rejected(confirmation), "Click requires Open under the actual visible pointer")
        confirmation.launchEvidence!.openButtonUnderPointer = true
        precondition(!rejected(confirmation))
        var invalid = confirmation; invalid.button = "right"; precondition(rejected(invalid))
        precondition(rejected(confirmation, at: Date().addingTimeInterval(-30)))
        precondition(rejected(confirmation, uptime: nil))
        precondition(rejected(confirmation, uptime: ProcessInfo.processInfo.systemUptime - 30))
        precondition(rejected(confirmation, uptime: Double.nan))
        var failed = command; failed.messageScope!.launch.phase = .failed
        precondition(rejected(confirmation, failed))
        let transition = ActionProposal(type: .wait, purpose: "navigation", risk: "low", requiresConfirmation: false,
            reason: "等待启动过渡画面", pointerVisible: false, highRisk: false, confidence: 0.99)
        for phase in [MessageLaunch.Phase.pending, .opening, .opened] {
            var value = command; value.messageScope!.launch.phase = phase
            precondition(!rejected(transition, value))
        }
        precondition(rejected(transition, failed))
        var mislabeledWait = transition; mislabeledWait.purpose = "message_send"; mislabeledWait.risk = "authorized_message"
        precondition(rejected(mislabeledWait), "Transition wait cannot bypass ordinary message evidence")
        for field in 0..<8 {
            var invalid = transition
            switch field {
            case 0: invalid.dx = 1
            case 1: invalid.dy = 1
            case 2: invalid.wheel = 1
            case 3: invalid.button = "left"
            case 4: invalid.key = "ENTER"
            case 5: invalid.text = "hello"
            case 6: invalid.risk = "unknown"
            default: invalid.requiresConfirmation = true
            }
            precondition(rejected(invalid), "Launch transition wait carried HID/risk field \(field)")
        }
        var consumed = command; consumed.messageScope!.pasteAttempted = true
        precondition(rejected(confirmation, consumed))
        precondition(rejected(transition, consumed))
        consumed = command; consumed.messageScope!.sendAttempted = true
        precondition(rejected(confirmation, consumed))

        var verification = ActionProposal(type: .wait, purpose: "app_launch_verify", risk: "low",
            requiresConfirmation: false, reason: "最新画面已显示微信", pointerVisible: false, highRisk: false, confidence: 0.99,
            launchEvidence: .init(frameID: "launch-frame", targetApp: "微信", systemOpenConfirmation: false,
                dialogText: "", openButtonText: "", openButtonUnderPointer: false,
                targetAppVisible: true, foregroundApp: "微信"))
        precondition(!rejected(verification))
        verification.confidence = 0.84; precondition(rejected(verification))
        verification.confidence = 0.85; precondition(!rejected(verification))
        verification.confidence = 0.99
        verification.type = .click; precondition(rejected(verification)); verification.type = .wait
        verification.launchEvidence!.foregroundApp = "SightLatch"; precondition(rejected(verification))
        verification.launchEvidence!.foregroundApp = "微信"
        verification.launchEvidence!.systemOpenConfirmation = true; precondition(rejected(verification))
        verification.launchEvidence!.systemOpenConfirmation = false
        var established = command
        established.messageScope!.launch.phase = .opened
        established.messageScope!.launch.visuallyEstablishedAt = Date().addingTimeInterval(-1)
        established.messageScope!.launch.visuallyEstablishedUptime = ProcessInfo.processInfo.systemUptime - 1
        established.messageScope!.launch.visuallyEstablishedFrameID = "established-frame"
        precondition(rejected(confirmation, established) && rejected(verification, established))
        print("PASS: scoped current-frame WeChat open confirmation and non-HID visual handoff; other dialogs/actions, stale frames, consumed scope and ordinary-click bypass rejected")
    }
}
