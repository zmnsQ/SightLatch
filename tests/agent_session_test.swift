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
        precondition(session.limitReason(now: start.addingTimeInterval(300)) != nil)
        var limited = AgentSession(id: "bounded", startedAt: start, maxRounds: 1)
        try limited.observe(frameID: "only", capturedAt: start, fingerprint: image, now: start)
        precondition(limited.limitReason(now: start) != nil)
        precondition(!limited.accepts(frameID: "only", capturedAt: start.addingTimeInterval(1)))
        print("PASS: fresh post-tool frames, same-goal context, no-progress stop, bounded recovery/history, manual resume and round/time limits")
    }
}
