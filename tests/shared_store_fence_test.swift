import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main struct SharedStoreFenceTests {
    static func main() throws {
        let store = SharedStore()
        if CommandLine.arguments.contains("stop-child") { try store.invalidatePendingStarts(); return }
        let initial = store.stopGeneration
        try store.startCommand(SessionCommand(id: "first", task: "observe", running: true), expectedStopGeneration: initial)
        try store.invalidatePendingStarts()
        try store.updateCommand(sessionID: "first") { $0.running = false }
        do {
            try store.startCommand(SessionCommand(id: "stale-prepare", task: "observe", running: true), expectedStopGeneration: initial)
            preconditionFailure("STOP was bypassed by pending prepare")
        } catch {}
        precondition(store.command?.id == "first" && store.command?.running == false)
        let next = store.stopGeneration
        try store.startCommand(SessionCommand(id: "second", task: "observe", running: true), expectedStopGeneration: next)
        let old = try store.updateCommand(sessionID: "first") { $0.running = false }
        precondition(!old && store.command?.id == "second" && store.command?.running == true)
        // Cross-process stop must invalidate a previously captured prepare token.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [CommandLine.arguments[0], "stop-child"]
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        do {
            try store.startCommand(SessionCommand(id: "late-parent", task: "observe", running: true), expectedStopGeneration: next)
            preconditionFailure("Cross-process STOP fence was ignored")
        } catch {}
        let captureFence = store.stopGeneration
        let reason = "广播扩展未读到有效校准"
        let oldSessionFailure = try store.recordCaptureStartupFailure(sessionID: "first", generation: 0,
            expectedStopGeneration: captureFence, reason: reason)
        precondition(!oldSessionFailure)
        let oldGenerationFailure = try store.recordCaptureStartupFailure(sessionID: "second", generation: 1,
            expectedStopGeneration: captureFence, reason: reason)
        precondition(!oldGenerationFailure)
        let stoppedFailure = try store.recordCaptureStartupFailure(sessionID: "second", generation: 0,
            expectedStopGeneration: next, reason: reason)
        precondition(!stoppedFailure, "An old fence cannot overwrite explicit STOP")
        precondition(store.command?.running == true && store.read("capture-status.json", as: CaptureObservation.self) == nil)
        let recordedFailure = try store.recordCaptureStartupFailure(sessionID: "second", generation: 0,
            expectedStopGeneration: captureFence, reason: reason)
        precondition(recordedFailure)
        let failure = store.read("capture-status.json", as: CaptureObservation.self)!
        precondition(failure.startupFailureReason == reason && !failure.hasFreshFrame)
        precondition(failure.failureStopGeneration == captureFence && store.command?.running == false)
        precondition(store.status.sessionID == "second" && store.status.detail == reason)
        try store.startCommand(SessionCommand(id: "capture-newer", task: "observe", running: true), expectedStopGeneration: captureFence)
        try store.write(PilotStatus(phase: "待广播", detail: "new session", steps: 0, sessionID: "capture-newer"), to: "status.json")
        let lateFailure = try store.recordCaptureStartupFailure(sessionID: "second", generation: 0,
            expectedStopGeneration: captureFence, reason: "late error")
        precondition(!lateFailure)
        precondition(store.command?.running == true && store.status.detail == "new session")
        // Speech only queues a goal. Its completed-action commit changes the
        // generation and rebuilds message authority without extending session life.
        var configuration = PilotConfiguration(); configuration.uploadConsent = true
        try store.write(configuration, to: "configuration.json")
        let oldGoal = "打开微信给文件传输助手发送消息 旧正文"
        let newGoal = "打开微信给文件传输助手发送消息 新正文"
        var voiceCommand = SessionCommand(id: "voice-session", task: oldGoal, running: true,
            createdAt: Date().addingTimeInterval(-10))
        voiceCommand.messageScope = MessageScope(intent: MessageIntent.parse(oldGoal)!, sessionID: voiceCommand.id,
            generation: 0, expiresAt: voiceCommand.createdAt.addingTimeInterval(300),
            stopGeneration: captureFence, clipboardPrepared: true)
        voiceCommand.messageScope!.pasteAttempted = true
        voiceCommand.messageScope!.sendAttempted = true
        let oldScopeID = voiceCommand.messageScope!.id
        try store.startCommand(voiceCommand, expectedStopGeneration: captureFence)
        let instruction = SessionGoalInstruction(sessionID: voiceCommand.id, generation: 0,
            expectedStopGeneration: captureFence, goal: newGoal)
        try store.enqueueGoalInstruction(instruction)
        precondition(store.command?.task == oldGoal && store.command?.generation == 0)
        let applied = try store.applyPendingGoal(sessionID: voiceCommand.id, expectedGeneration: 0)!
        precondition(applied.id == voiceCommand.id && applied.createdAt == voiceCommand.createdAt)
        precondition(applied.generation == 1 && applied.task == newGoal)
        precondition(applied.messageScope?.id != oldScopeID && applied.messageScope?.intent.body == "新正文")
        precondition(applied.messageScope?.generation == 1 && applied.messageScope?.stopGeneration == captureFence)
        precondition(applied.messageScope?.expiresAt == voiceCommand.createdAt.addingTimeInterval(300))
        precondition(applied.messageScope?.clipboardPrepared == false && applied.messageScope?.launch.phase == .pending)
        precondition(applied.messageScope?.pasteAttempted == false && applied.messageScope?.sendAttempted == false)
        let replay = try store.applyPendingGoal(sessionID: voiceCommand.id, expectedGeneration: 1)
        precondition(replay == nil, "A consumed instruction cannot apply twice")
        do {
            try store.markMessageClipboardPrepared(context: .init(sessionID: voiceCommand.id, generation: 0,
                frameID: "clipboard", scopeID: oldScopeID), expectedStopGeneration: captureFence)
            preconditionFailure("Old-generation clipboard work authorized a new body")
        } catch {}
        let clipboardContext = MessageDispatchContext(sessionID: applied.id, generation: applied.generation,
            frameID: "clipboard", scopeID: applied.messageScope!.id)
        try store.confirmMessageAppVisible(context: clipboardContext, expectedStopGeneration: captureFence,
            capturedAt: Date(), capturedUptime: ProcessInfo.processInfo.systemUptime)
        do {
            try store.reserveMessageAction(purpose: "message_paste", context: clipboardContext)
            preconditionFailure("A new scoped message pasted the previous body's clipboard")
        } catch {}
        try store.markMessageClipboardPrepared(context: clipboardContext, expectedStopGeneration: captureFence)
        precondition(store.command?.messageScope?.clipboardPrepared == true)
        try store.reserveMessageAction(purpose: "message_paste", context: clipboardContext)
        // An old runtime cannot consume/delete a new generation's pending goal.
        let navigation = SessionGoalInstruction(sessionID: voiceCommand.id, generation: 1,
            expectedStopGeneration: captureFence, goal: "查看当前页面")
        try store.enqueueGoalInstruction(navigation)
        let staleRuntime = try store.applyPendingGoal(sessionID: voiceCommand.id, expectedGeneration: 0)
        precondition(staleRuntime == nil && store.read("voice-instruction.json", as: SessionGoalInstruction.self)?.id == navigation.id)
        let navigationCommand = try store.applyPendingGoal(sessionID: voiceCommand.id, expectedGeneration: 1)!
        precondition(navigationCommand.generation == 2 && navigationCommand.messageScope == nil)
        do {
            try store.enqueueGoalInstruction(instruction)
            preconditionFailure("Old-generation speech was accepted")
        } catch {}
        let revoked = SessionGoalInstruction(sessionID: voiceCommand.id, generation: 2,
            expectedStopGeneration: captureFence, goal: "返回上一页")
        try store.enqueueGoalInstruction(revoked)
        configuration.uploadConsent = false
        try store.write(configuration, to: "configuration.json")
        let revokedApply = try store.applyPendingGoal(sessionID: voiceCommand.id, expectedGeneration: 2)
        precondition(revokedApply == nil && store.command?.generation == 2)
        configuration.uploadConsent = true
        try store.write(configuration, to: "configuration.json")
        try store.enqueueGoalInstruction(revoked)
        try store.invalidatePendingStarts()
        let stoppedApply = try store.applyPendingGoal(sessionID: voiceCommand.id, expectedGeneration: 2)
        precondition(stoppedApply == nil && store.command?.generation == 2, "STOP must win over queued speech")
        var expired = SessionCommand(id: "expired-voice", task: "observe", running: true,
            createdAt: Date().addingTimeInterval(-301))
        try store.startCommand(expired, expectedStopGeneration: store.stopGeneration)
        let expiredInstruction = SessionGoalInstruction(sessionID: expired.id, generation: 0,
            expectedStopGeneration: store.stopGeneration, goal: "查看当前页面")
        do {
            try store.enqueueGoalInstruction(expiredInstruction)
            preconditionFailure("Speech renewed an expired session")
        } catch {}
        try store.write(expiredInstruction, to: "voice-instruction.json")
        let expiredApply = try store.applyPendingGoal(sessionID: expired.id, expectedGeneration: 0)
        precondition(expiredApply == nil && store.command?.generation == 0)
        expired.createdAt = Date().addingTimeInterval(-60)
        try store.startCommand(expired, expectedStopGeneration: store.stopGeneration)
        var staleInstruction = SessionGoalInstruction(sessionID: expired.id, generation: 0,
            expectedStopGeneration: store.stopGeneration, goal: "查看当前页面")
        staleInstruction.createdAt = Date().addingTimeInterval(-31)
        try store.write(staleInstruction, to: "voice-instruction.json")
        let staleApply = try store.applyPendingGoal(sessionID: expired.id, expectedGeneration: 0)
        precondition(staleApply == nil && store.command?.generation == 0)
        // A corrupt persisted fence cannot be treated as first-run nil.
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!).appendingPathComponent("stop-generation.json")
        try Data("damaged".utf8).write(to: url)
        do {
            try store.startCommand(SessionCommand(id: "corrupt", task: "observe", running: true), expectedStopGeneration: nil)
            preconditionFailure("Corrupt fence must fail closed")
        } catch {}
        print("PASS: persisted STOP fence, old-session callback, cross-process fence, completed-action goal commit, fresh scopes and clipboard gate, no queued replay or lifetime renewal, damaged-state fail closed")
    }
}
