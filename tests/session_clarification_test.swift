import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct SessionClarificationTests {
    static let store = SharedStore()
    static let goal = "打开微信给联系人甲发送消息：你好"
    static let frameID = "clarification-frame"
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func check(_ expression: @autoclosure () throws -> Bool) rethrows {
        let accepted = try expression(); precondition(accepted)
    }
    static func rejected(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected refusal") } catch {}
    }
    static func command(now: Date = Date(), unlimited: Bool = false) -> SessionCommand {
        let captured = now.addingTimeInterval(-2), started = now.addingTimeInterval(-1.5)
        let end = unlimited ? nil : started.addingTimeInterval(300)
        var value = SessionCommand(task: goal, running: true, createdAt: now.addingTimeInterval(-10))
        value.execution = SessionExecution(phase: .active, stopGeneration: store.stopGeneration,
            hardware: .init(deviceURL: "http://fixture.local", softwareControl: true,
                bootID: "fixture-boot", controlEpoch: "fixture-epoch", hidGeneration: 4),
            captureOwnerID: "fixture-owner", captureStartedAt: captured, startupExpiresAt: captured.addingTimeInterval(10),
            startedAt: started, expiresAt: end, hardwareSessionID: "fixture-hardware-session",
            durationSeconds: unlimited ? nil : 300, unlimitedConfirmed: unlimited, renewableHardwareLease: unlimited,
            hardwareLeaseExpiresAt: unlimited ? now.addingTimeInterval(20) : nil,
            nextRenewalSequence: unlimited ? 3 : nil, lastConfirmedRenewalSequence: unlimited ? 2 : nil)
        value.messageScope = MessageScope(intent: MessageIntent.parse(goal)!, sessionID: value.id,
            generation: value.generation, expiresAt: end, isUnlimited: unlimited,
            stopGeneration: store.stopGeneration, clipboardPrepared: true,
            clipboardExpiresAt: now.addingTimeInterval(200))
        value.messageScope!.launch = MessageLaunch(phase: .opened, acknowledgedAt: now.addingTimeInterval(-1),
            acknowledgedUptime: 1, visuallyEstablishedAt: now.addingTimeInterval(-0.5),
            visuallyEstablishedUptime: 2, visuallyEstablishedFrameID: "established", proofSource: "visual_target_app")
        value.execution!.messageScopeID = value.messageScope!.id
        return value
    }
    static func proposal(alias: String? = nil) -> ActionProposal {
        var value = ActionProposal(type: .ask_user, purpose: "other", risk: "unknown", requiresConfirmation: true,
            reason: "请选择需要继续的方向", pointerVisible: false, highRisk: false, confidence: 0.9)
        if let alias {
            value.clarification = .init(question: "当前联系人是否正确？", options: [
                .init(title: "不可信的模型标签", reply: "不可信的模型回复", recipient: alias)])
            value.messageEvidence = .init(frameID: frameID, app: "微信", recipient: alias,
                recipientUnambiguous: true, composerFocused: false, composerText: "", sendButtonUnderPointer: false,
                outgoingText: "", newOutgoingMessage: false, deliveryState: "unknown")
        }
        return value
    }
    static func pending(_ proposal: ActionProposal, _ command: SessionCommand, now: Date) throws -> SessionClarification {
        try SessionClarificationPolicy.make(proposal: proposal, command: command, frameID: frameID,
            expectedStopGeneration: command.execution?.stopGeneration, actualStopGeneration: command.execution?.stopGeneration,
            uploadConsent: true, now: now)
    }
    static func resolved(_ command: SessionCommand, now: Date) throws -> SessionCommand {
        let question = command.pendingClarification!
        return try SessionClarificationPolicy.resolving(command: command, sessionID: command.id,
            questionID: question.id, optionID: question.options[0].id,
            actualStopGeneration: command.execution?.stopGeneration, uploadConsent: true, now: now)
    }
    static func install(_ command: SessionCommand) throws {
        try store.write(command, to: "command.json")
        try store.write(PilotStatus(phase: "规划", detail: "fixture", steps: 7, sessionID: command.id), to: "status.json")
    }
    static func request(_ command: SessionCommand, proposal value: ActionProposal = proposal()) throws -> SessionClarification {
        try store.requestClarification(proposal: value, sessionID: command.id, generation: command.generation,
            frameID: frameID, expectedStopGeneration: command.execution?.stopGeneration)
    }
    static func main() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "resolve-child" {
            do {
                _ = try store.resolveClarification(sessionID: CommandLine.arguments[2],
                    questionID: CommandLine.arguments[3], optionID: CommandLine.arguments[4]); exit(0)
            } catch { exit(2) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "stop-child" {
            try store.invalidatePendingStarts()
            _ = try store.updateCommand(sessionID: CommandLine.arguments[2]) { $0.running = false }
            return
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!)
        var config = PilotConfiguration(); config.deviceURL = "http://fixture.local"; config.uploadConsent = true
        try store.write(config, to: "configuration.json")
        let now = Date()
        var value = command(now: now)
        let originalExecution = try encoded(value.execution), originalScope = value.messageScope!
        value.pendingClarification = try pending(proposal(alias: "联系人乙"), value, now: now)
        let question = value.pendingClarification!
        precondition(question.options[0].title == "发送给联系人乙")
        precondition(!question.options[0].reply.contains("不可信"))
        let changed = try resolved(value, now: now.addingTimeInterval(0.1))
        precondition(changed.id == value.id && changed.task == value.task && changed.generation == value.generation + 1)
        precondition(changed.messageScope!.id == originalScope.id && changed.messageScope!.intent == originalScope.intent)
        precondition(changed.messageScope!.effectiveRecipient == "联系人乙" && changed.messageScope!.generation == changed.generation)
        precondition(changed.messageScope!.matches(sessionID: changed.id, generation: changed.generation, task: goal, now: now))
        try check(try encoded(changed.execution) == originalExecution)
        try check(try encoded(changed.messageScope!.launch) == encoded(originalScope.launch))
        precondition(changed.messageScope!.clipboardExpiresAt == originalScope.clipboardExpiresAt)
        precondition(changed.pendingClarification == nil && changed.lastClarificationAnswer?.questionID == question.id)
        rejected { _ = try resolved(changedWithOldQuestion(changed, question), now: now) }
        rejected { _ = try SessionClarificationPolicy.resolving(command: changed, sessionID: changed.id,
            questionID: question.id, optionID: question.options[0].id, actualStopGeneration: nil, uploadConsent: true, now: now) }

        // Unreadable/ambiguous, foreign-frame or foreign-app recipients cannot become an option.
        for mode in 0..<5 {
            var ask = proposal(alias: "联系人乙")
            switch mode {
            case 0: ask.messageEvidence!.recipientUnambiguous = false
            case 1: ask.messageEvidence!.frameID = "stale-frame"
            case 2: ask.messageEvidence!.app = "其他应用"
            case 3: ask.messageEvidence!.recipient = "联系人丙"
            default: ask.messageEvidence = nil
            }
            let q = try pending(ask, command(now: now), now: now)
            precondition(q.options.count == 1 && q.options[0].recipient == nil && q.options[0].title == "重新观察")
        }
        var badAsk = proposal(); badAsk.key = "ENTER"
        rejected { _ = try pending(badAsk, command(now: now), now: now) }
        var malformed = proposal(); malformed.type = .click
        rejected { _ = try pending(malformed, command(now: now), now: now) }

        // A clarification is not a new message, including after an unknown send result.
        for sent in [false, true] {
            var attempted = command(now: now)
            attempted.messageScope!.pasteAttempted = true
            attempted.messageScope!.sendAttempted = sent
            attempted.messageScope!.sendFrameID = sent ? "already-sent" : nil
            attempted.messageScope!.sendAttemptedAt = sent ? now.addingTimeInterval(-0.2) : nil
            attempted.pendingClarification = try pending(proposal(alias: "联系人乙"), attempted, now: now)
            precondition(attempted.pendingClarification!.options[0].recipient == nil)
            let answer = try resolved(attempted, now: now)
            var expectedScope = attempted.messageScope!; expectedScope.generation += 1
            try check(try encoded(answer.messageScope) == encoded(Optional(expectedScope)))
            if sent {
                var scope = answer.messageScope!
                precondition(!scope.reserve(purpose: "message_send", context: .init(sessionID: answer.id,
                    generation: answer.generation, frameID: "new-frame", scopeID: scope.id), task: goal, now: now))
            }
        }
        var unlimited = command(now: now, unlimited: true)
        unlimited.pendingClarification = try pending(proposal(), unlimited, now: now)
        let unlimitedAnswer = try resolved(unlimited, now: now)
        try check(try encoded(unlimitedAnswer.execution) == encoded(unlimited.execution))
        rejected { _ = try resolved(unlimited, now: now.addingTimeInterval(21)) }
        rejected { _ = try resolved(value, now: value.execution!.expiresAt!) }
        var stopped = value; stopped.running = false
        rejected { _ = try resolved(stopped, now: now) }
        rejected { _ = try SessionClarificationPolicy.resolving(command: value, sessionID: "foreign-session",
            questionID: question.id, optionID: question.options[0].id, actualStopGeneration: nil, uploadConsent: true, now: now) }
        rejected { _ = try SessionClarificationPolicy.resolving(command: value, sessionID: value.id,
            questionID: question.id, optionID: question.options[0].id, actualStopGeneration: "new-stop", uploadConsent: true, now: now) }
        rejected { _ = try SessionClarificationPolicy.resolving(command: value, sessionID: value.id,
            questionID: question.id, optionID: question.options[0].id, actualStopGeneration: nil, uploadConsent: false, now: now) }

        // Text is bounded and scrubbed; buttons with recipient payload use host titles.
        var noisy = proposal()
        noisy.clarification = .init(question: "token=fixture_secret " + String(repeating: "问", count: 300), options: [
            .init(title: "token=fixture_secret " + String(repeating: "选", count: 90), reply: "token=fixture_secret " + String(repeating: "答", count: 300))])
        let bounded = try pending(noisy, command(now: now), now: now)
        precondition(bounded.question.count <= 160 && bounded.options[0].title.count <= 60 && bounded.options[0].reply.count <= 160)
        try check(!String(data: try encoded(bounded), encoding: .utf8)!.contains("fixture_secret"))

        // Keep the reported colloquial defect explicit: no blind removal of 发 or 说.
        let colloquial = MessageIntent.parse("打开微信给陈明发发送消息说你好")!
        precondition(colloquial.recipient == "陈明发" && colloquial.body == "说你好")
        precondition(MessageIntent.parse("打开微信给陈发发送消息：说你好") == .init(recipient: "陈发", body: "说你好"))
        precondition(MessageIntent.parse("打开微信给陈明发送消息：“说你好”")?.body == "说你好")

        // Real file-lock transition: same question idempotent, status and ledger stay coherent.
        let live = command(); try install(live)
        let q = try request(live)
        try check(try request(live).id == q.id)
        precondition(store.status.phase == "等待用户" && store.status.steps == 7 && store.status.userMessage == q.question)
        rejected { try store.reserveMessageAction(purpose: "message_paste", context: .init(sessionID: live.id,
            generation: live.generation, frameID: frameID, scopeID: live.messageScope!.id)) }
        rejected { try store.enqueueGoalInstruction(.init(sessionID: live.id, generation: live.generation,
            expectedStopGeneration: nil, goal: "打开微信给联系人甲发送消息：重复")) }
        let children = try (0..<2).map { _ -> Process in
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["resolve-child", live.id, q.id, q.options[0].id]
            try child.run(); return child
        }
        children.forEach { $0.waitUntilExit() }
        precondition(children.map(\.terminationStatus).sorted() == [0, 2], "Only one process may consume the answer")
        precondition(store.command!.generation == live.generation + 1 && store.command!.pendingClarification == nil)
        precondition(store.status.phase == "观察" && store.status.steps == 7 && store.status.userMessage == nil)
        try check(try encoded(store.command!.execution) == encoded(live.execution))

        let racing = command(); try install(racing); let rq = try request(racing)
        let stopChild = Process(); stopChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        stopChild.arguments = ["stop-child", racing.id]
        let answerChild = Process(); answerChild.executableURL = stopChild.executableURL
        answerChild.arguments = ["resolve-child", racing.id, rq.id, rq.options[0].id]
        try stopChild.run(); try answerChild.run()
        stopChild.waitUntilExit(); answerChild.waitUntilExit()
        precondition(stopChild.terminationStatus == 0 && [0, 2].contains(answerChild.terminationStatus))
        precondition(store.command!.running == false, "STOP wins final state regardless of answer ordering")
        rejected { _ = try store.resolveClarification(sessionID: racing.id, questionID: rq.id, optionID: rq.options[0].id) }

        let fenced = command(); try install(fenced); let fq = try request(fenced)
        try store.invalidatePendingStarts()
        rejected { _ = try store.resolveClarification(sessionID: fenced.id, questionID: fq.id, optionID: fq.options[0].id) }
        precondition(store.command!.pendingClarification?.id == fq.id)
        let disabled = command(); try install(disabled); let dq = try request(disabled)
        config.uploadConsent = false; try store.write(config, to: "configuration.json")
        rejected { _ = try store.resolveClarification(sessionID: disabled.id, questionID: dq.id, optionID: dq.options[0].id) }
        config.uploadConsent = true; try store.write(config, to: "configuration.json")
        let uncertain = command(); try install(uncertain); let uq = try request(uncertain)
        try store.recordUnconfirmedHardwareStop(sessionID: uncertain.id, deviceURL: config.deviceURL, bootID: "fixture-boot")
        rejected { _ = try store.resolveClarification(sessionID: uncertain.id, questionID: uq.id, optionID: uq.options[0].id) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hardware-stop-uncertain.json"))

        let failedStatus = command(); try install(failedStatus)
        try store.write(PilotStatus(phase: "请核实硬件停止", detail: "fixture", steps: 8, sessionID: failedStatus.id), to: "status.json")
        rejected { _ = try request(failedStatus) }

        let missingStatus = command(); try install(missingStatus)
        try Data("invalid secondary status".utf8).write(to: directory.appendingPathComponent("status.json"))
        let msq = try request(missingStatus)
        precondition(store.command!.pendingClarification?.id == msq.id)

        // A status write failure cannot turn a committed answer into a retryable failure.
        let secondary = command(); try install(secondary); let sq = try request(secondary)
        try Data("invalid secondary status".utf8).write(to: directory.appendingPathComponent("status.json"))
        let secondaryAnswer = try store.resolveClarification(sessionID: secondary.id, questionID: sq.id, optionID: sq.options[0].id)
        precondition(secondaryAnswer.pendingClarification == nil && store.command!.generation == secondary.generation + 1)
        print("session clarification pure and file-lock transitions passed")
    }
    static func changedWithOldQuestion(_ command: SessionCommand, _ question: SessionClarification) -> SessionCommand {
        var result = command; result.pendingClarification = question; return result
    }
}
