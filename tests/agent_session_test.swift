import Foundation

@main struct AgentSessionTests {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var session = AgentSession(id: "goal-1", startedAt: start, maxRounds: 50)
        let image = Data(repeating: 100, count: 16)
        try session.observe(frameID: "f1", capturedAt: start, fingerprint: image, now: start)
        session.record(action: "click", outcome: "hardware_completed", at: start.addingTimeInterval(2))
        precondition(!session.accepts(frameID: "during-hid", capturedAt: start.addingTimeInterval(1)))
        precondition(!session.accepts(frameID: "equal", capturedAt: start.addingTimeInterval(2)))
        precondition(session.accepts(frameID: "after-hid", capturedAt: start.addingTimeInterval(3)))
        precondition(session.modelContext.contains("hardware_completed"))
        precondition(session.modelContext.contains("goal-1"))
        precondition(session.modelContext.contains("never UI success"))
        for n in 2...4 {
            try session.observe(frameID: "f\(n)", capturedAt: start.addingTimeInterval(Double(n + 3)), fingerprint: image, now: start)
            session.record(action: "wait", outcome: "no HID", at: start.addingTimeInterval(Double(n + 3)))
        }
        do {
            try session.observe(frameID: "f5", capturedAt: start.addingTimeInterval(9), fingerprint: image, now: start)
            preconditionFailure("No-progress loop must stop")
        } catch is HarnessError {}
        session.manualResume(at: start.addingTimeInterval(10))
        try session.observe(frameID: "f6", capturedAt: start.addingTimeInterval(11), fingerprint: image, now: start)
        precondition(session.rounds == 5, "Manual intervention must not reset budget")
        precondition(session.recoverBeforeDispatch("network", at: start))
        precondition(session.recoverBeforeDispatch("stale", at: start))
        precondition(!session.recoverBeforeDispatch("third failure", at: start))
        session.record(action: "wait", outcome: "no HID", at: start)
        precondition(session.recoverBeforeDispatch("new failure", at: start))
        for n in 0..<30 { session.record(action: "a\(n)", outcome: "completed", at: start) }
        precondition(session.results.count == 12)
        precondition(session.results.first?.action == "a18")
        let roundsBeforeReplacement = session.rounds
        session.replaceGoal(at: start.addingTimeInterval(20))
        precondition(session.results.count == 1 && session.results.first?.action == "new_user_goal")
        precondition(!session.modelContext.contains("a29"), "Old goal actions cannot leak into replacement goal context")
        precondition(session.rounds == roundsBeforeReplacement && session.startedAt == start, "New spoken goals cannot renew time or step budgets")
        precondition(!session.accepts(frameID: "before-replacement", capturedAt: start.addingTimeInterval(19)))
        precondition(session.accepts(frameID: "after-replacement", capturedAt: start.addingTimeInterval(21)))
        precondition(session.limitReason(now: start.addingTimeInterval(300)) != nil)
        var limited = AgentSession(id: "bounded", startedAt: start, maxRounds: 1)
        try limited.observe(frameID: "only", capturedAt: start, fingerprint: image, now: start)
        precondition(limited.limitReason(now: start) != nil)
        precondition(!limited.accepts(frameID: "only", capturedAt: start.addingTimeInterval(1)))

        // Unsubmitted proposals and launch proof still use round/freshness budgets,
        // but neither add nor erase prior unsuccessful UI attempts.
        var counting = AgentSession(id: "counting", startedAt: start, maxRounds: 20)
        try counting.observe(frameID: "c0", capturedAt: start, fingerprint: image, now: start)
        counting.record(action: "move", outcome: "hardware_completed", at: start.addingTimeInterval(1))
        try counting.observe(frameID: "c1", capturedAt: start.addingTimeInterval(2), fingerprint: image, now: start)
        counting.record(action: "app_launch_verify", outcome: "visual proof; no HID", at: start.addingTimeInterval(3), countsAsUIAttempt: false)
        try counting.observe(frameID: "c2", capturedAt: start.addingTimeInterval(4), fingerprint: image, now: start)
        counting.record(action: "move", outcome: "hardware_completed", at: start.addingTimeInterval(5))
        try counting.observe(frameID: "c3", capturedAt: start.addingTimeInterval(6), fingerprint: image, now: start)
        for n in 0..<2 {
            precondition(counting.recoverBeforeDispatch("expired before POST", at: start.addingTimeInterval(Double(7 + n * 2))))
            try counting.observe(frameID: "retry\(n)", capturedAt: start.addingTimeInterval(Double(8 + n * 2)), fingerprint: image, now: start)
        }
        precondition(!counting.recoverBeforeDispatch("third expiry", at: start.addingTimeInterval(11)))
        precondition(counting.rounds == 6, "Unsubmitted re-observations still consume planning rounds")
        counting.record(action: "observe", outcome: "launch advanced; no HID", at: start.addingTimeInterval(12), countsAsUIAttempt: false)
        try counting.observe(frameID: "c4", capturedAt: start.addingTimeInterval(13), fingerprint: image, now: start)
        // A second observation without another tool result cannot count the same attempt twice.
        try counting.observe(frameID: "c5", capturedAt: start.addingTimeInterval(14), fingerprint: image, now: start)
        counting.record(action: "wait", outcome: "no HID", at: start.addingTimeInterval(15))
        try counting.observe(frameID: "c6", capturedAt: start.addingTimeInterval(16), fingerprint: image, now: start)
        counting.record(action: "click", outcome: "hardware_completed", at: start.addingTimeInterval(17))
        do {
            try counting.observe(frameID: "c7", capturedAt: start.addingTimeInterval(18), fingerprint: image, now: start)
            preconditionFailure("Four actual attempts, including wait, must still stop; recovery cannot reset their count")
        } catch is HarnessError {}
        precondition(counting.limitReason(now: start.addingTimeInterval(300)) != nil)

        var preserved = AgentSession(id: "pending", startedAt: start, maxRounds: 20)
        try preserved.observe(frameID: "p0", capturedAt: start, fingerprint: image, now: start)
        preserved.record(action: "click", outcome: "hardware_completed", at: start.addingTimeInterval(1))
        preserved.record(action: "observe", outcome: "context only", at: start.addingTimeInterval(1), countsAsUIAttempt: false)
        for n in 1...3 {
            try preserved.observe(frameID: "p\(n)", capturedAt: start.addingTimeInterval(Double(n * 2)), fingerprint: image, now: start)
            preserved.record(action: "wait", outcome: "no HID", at: start.addingTimeInterval(Double(n * 2 + 1)))
        }
        do {
            try preserved.observe(frameID: "p4", capturedAt: start.addingTimeInterval(8), fingerprint: image, now: start)
            preconditionFailure("Context-only logs cannot mask an attempt awaiting comparison")
        } catch is HarnessError {}

        // An observed visual change, even without a new UI attempt, clears the stall window.
        let changed = Data(repeating: 180, count: image.count)
        var progress = AgentSession(id: "progress", startedAt: start, maxRounds: 20)
        try progress.observe(frameID: "v0", capturedAt: start, fingerprint: image, now: start)
        for n in 1...3 {
            progress.record(action: "move", outcome: "hardware_completed", at: start.addingTimeInterval(Double(n * 2 - 1)))
            try progress.observe(frameID: "v\(n)", capturedAt: start.addingTimeInterval(Double(n * 2)), fingerprint: image, now: start)
        }
        progress.record(action: "observe", outcome: "no HID", at: start.addingTimeInterval(7), countsAsUIAttempt: false)
        try progress.observe(frameID: "changed", capturedAt: start.addingTimeInterval(8), fingerprint: changed, now: start)
        for n in 1...3 {
            progress.record(action: "wait", outcome: "no HID", at: start.addingTimeInterval(Double(9 + n * 2)))
            try progress.observe(frameID: "after-change\(n)", capturedAt: start.addingTimeInterval(Double(10 + n * 2)), fingerprint: changed, now: start)
        }
        progress.record(action: "wait", outcome: "no HID", at: start.addingTimeInterval(17))
        do {
            try progress.observe(frameID: "after-change4", capturedAt: start.addingTimeInterval(18), fingerprint: changed, now: start)
            preconditionFailure("Real visual change starts a new four-attempt stall window")
        } catch is HarnessError {}
        var clarification = AgentSession(id: "question", startedAt: start, maxRounds: 8, durationSeconds: 90)
        try clarification.observe(frameID: "question-frame", capturedAt: start, fingerprint: image, now: start)
        clarification.record(action: "message_send", outcome: "hardware_completed; verify only", at: start.addingTimeInterval(1))
        let answerAt = start.addingTimeInterval(20)
        let priorRounds = clarification.rounds
        clarification.manualResume(at: answerAt)
        clarification.record(action: "user_answer", outcome: "重新观察", at: answerAt, countsAsUIAttempt: false)
        precondition(!clarification.accepts(frameID: "old", capturedAt: answerAt))
        precondition(!clarification.accepts(frameID: "old2", capturedAt: answerAt.addingTimeInterval(-1)))
        precondition(clarification.accepts(frameID: "new", capturedAt: answerAt.addingTimeInterval(1)))
        precondition(clarification.rounds == priorRounds && clarification.modelContext.contains("message_send"))
        precondition(clarification.limitReason(now: start.addingTimeInterval(90)) != nil)
        print("PASS: fresh post-tool frames, precise UI-attempt stall counting, launch/non-dispatch exclusions without resets, bounded recovery/history, real-change reset and unchanged round/time limits")
    }
}
