import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct MessageScopeTests {
    static let goal = "打开微信，给文件传输助手发送消息：你好"
    static func command() -> SessionCommand {
        var value = SessionCommand(task: goal, running: true)
        value.createdAt = Date().addingTimeInterval(-10)
        value.messageScope = MessageScope(intent: MessageIntent.parse(goal)!, sessionID: value.id,
            generation: value.generation, expiresAt: Date().addingTimeInterval(300), stopGeneration: SharedStore.shared.stopGeneration)
        value.messageScope!.launch = MessageLaunch(phase: .opened,
            acknowledgedAt: Date().addingTimeInterval(-5), acknowledgedUptime: ProcessInfo.processInfo.systemUptime - 5,
            visuallyEstablishedAt: Date().addingTimeInterval(-4), visuallyEstablishedUptime: ProcessInfo.processInfo.systemUptime - 4,
            visuallyEstablishedFrameID: "established", proofSource: "visual_target_app")
        return value
    }
    static func context(_ value: SessionCommand, frame: String = "frame") -> MessageDispatchContext {
        .init(sessionID: value.id, generation: value.generation, frameID: frame, scopeID: value.messageScope!.id)
    }
    static func proposal(_ purpose: String, frame: String = "frame") -> ActionProposal {
        let type: ActionProposal.Kind = purpose == "message_paste" ? .key : purpose == "message_send" ? .click : .done
        return ActionProposal(type: type, button: type == .click ? "left" : nil,
            key: type == .key ? "PASTE_MESSAGE" : nil, purpose: purpose, risk: "authorized_message",
            requiresConfirmation: false, reason: "核对当前消息步骤", pointerVisible: true, highRisk: false, confidence: 0.99,
            messageEvidence: .init(frameID: frame, app: "微信", recipient: "文件传输助手", recipientUnambiguous: true,
                composerFocused: true, composerText: purpose == "message_send" ? "你好" : "", sendButtonUnderPointer: true,
                outgoingText: "你好", newOutgoingMessage: true, deliveryState: "sent"))
    }
    static func main() throws {
        let store = SharedStore()
        if CommandLine.arguments.contains("send-child") {
            do { let value = store.command!; try store.reserveMessageAction(purpose: "message_send", context: context(value)); exit(0) }
            catch { exit(2) }
        }
        precondition(MessageIntent.parse(goal) == MessageIntent(recipient: "文件传输助手", body: "你好"))
        precondition(MessageIntent.parse("打开微信给文件传输助手发送“你好”")?.body == "你好")
        for invalid in ["给文件传输助手发消息", "打开其他App，给朋友发送你好", "打开微信给发送消息：", "打开微信给朋友发送消息：你好\n再发一次"] {
            precondition(MessageIntent.parse(invalid) == nil, invalid)
        }
        var value = command()
        var config = PilotConfiguration(); config.allowLowRiskNavigation = true
        func rejected(_ action: ActionProposal, _ command: SessionCommand?, frame: String = "frame", at: Date = Date()) -> Bool {
            SafetyGate.rejection(action, task: goal, config: config, command: command, frameID: frame, capturedAt: at, capturedUptime: ProcessInfo.processInfo.systemUptime) != nil
        }
        let paste = proposal("message_paste")
        precondition(!rejected(paste, value))
        var unstaged = value; unstaged.messageScope!.clipboardPrepared = false
        precondition(rejected(paste, unstaged), "A continuation cannot paste the previous scope's clipboard")
        let stagingWait = ActionProposal(type: .wait, purpose: "navigation", risk: "low", requiresConfirmation: false,
            reason: "等待当前正文准备", pointerVisible: false, highRisk: false, confidence: 0.99)
        precondition(!rejected(stagingWait, unstaged), "Clipboard readiness is not a second user-confirmation gate")
        unstaged.messageScope!.clipboardPrepared = true
        precondition(!rejected(paste, unstaged))
        precondition(rejected(paste, nil))
        var pendingLaunch = value; pendingLaunch.messageScope!.launch = MessageLaunch()
        precondition(rejected(paste, pendingLaunch), "Message policy must also enforce the app-launch barrier")
        pendingLaunch.messageScope!.launch.phase = .opening
        precondition(rejected(paste, pendingLaunch))
        pendingLaunch.messageScope!.launch.phase = .failed
        precondition(rejected(paste, pendingLaunch))
        for field in 0..<6 {
            var invalid = paste
            switch field {
            case 0: invalid.messageEvidence!.recipient = "另一个人"
            case 1: invalid.messageEvidence!.app = "其他App"
            case 2: invalid.messageEvidence!.recipientUnambiguous = false
            case 3: invalid.messageEvidence!.composerText = "旧草稿"
            case 4: invalid.messageEvidence!.composerFocused = false
            default: invalid.messageEvidence!.frameID = "old"
            }
            precondition(rejected(invalid, value))
        }
        precondition(rejected(paste, value, at: Date().addingTimeInterval(-30)))
        var changed = value; changed.generation += 1; precondition(rejected(paste, changed))
        changed = value; changed.task = "打开微信给别人发送消息：你好"; precondition(rejected(paste, changed))
        changed = value; changed.running = false; precondition(rejected(paste, changed))
        precondition(rejected(proposal("message_send"), value))
        try store.startCommand(value, expectedStopGeneration: store.stopGeneration)
        try store.reserveMessageAction(purpose: "message_paste", context: context(value))
        value = store.command!
        precondition(value.messageScope!.pasteAttempted && rejected(paste, value))
        precondition(!rejected(proposal("message_send"), value))
        var wrongBody = proposal("message_send"); wrongBody.messageEvidence!.composerText = "不相符"
        precondition(rejected(wrongBody, value))
        var navigation = proposal("message_send"); navigation.purpose = "navigation"; navigation.risk = "low"
        precondition(rejected(navigation, value), "Generic click cannot bypass single send reservation")
        navigation.type = .move; navigation.dx = 3; navigation.dy = -2; navigation.reason = "移动到发送按钮"
        precondition(!rejected(navigation, value), "Moving is not sending; exact scoped draft is retained")
        // Actual production file lock, exercised by competing independent processes.
        var children: [Process] = []
        for _ in 0..<6 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = ["send-child"]
            try process.run(); children.append(process)
        }
        for child in children { child.waitUntilExit() }
        precondition(children.filter { $0.terminationStatus == 0 }.count == 1)
        precondition(children.allSatisfy { [0, 2].contains($0.terminationStatus) })
        value = store.command!
        precondition(value.messageScope!.sendAttempted)
        precondition(rejected(proposal("message_send"), value))
        precondition(rejected(paste, value))
        precondition(rejected(navigation, value), "No HID after attempted send")
        let verification = proposal("message_verify", frame: "new-frame")
        precondition(!rejected(verification, value, frame: "new-frame"))
        precondition(rejected(proposal("message_verify"), value), "Original frame cannot verify send")
        precondition(rejected(verification, value, frame: "new-frame", at: value.messageScope!.sendAttemptedAt!.addingTimeInterval(-1)))
        var pending = verification; pending.messageEvidence!.deliveryState = "pending"
        precondition(rejected(pending, value, frame: "new-frame"))
        pending = verification; pending.messageEvidence!.newOutgoingMessage = false
        precondition(rejected(pending, value, frame: "new-frame"))
        try store.verifyMessage(context: context(value, frame: "new-frame"), capturedAt: Date())
        precondition(store.command!.messageScope!.verified)
        do { try store.reserveMessageAction(purpose: "message_send", context: context(value)); preconditionFailure("Verified send replayed") } catch {}
        // Old-generation callbacks cannot consume a replacement session's scope.
        let replacement = command(); try store.startCommand(replacement, expectedStopGeneration: store.stopGeneration)
        do { try store.reserveMessageAction(purpose: "message_paste", context: context(value)); preconditionFailure("Old session mutated replacement") } catch {}
        precondition(!store.command!.messageScope!.pasteAttempted)
        print("PASS: deterministic exact intent, recipient/body/app/frame checks, one-shot paste/send, persisted cross-process consumption, no replay after send, fresh final verification, old-session fence; no network or HID")
    }
}
