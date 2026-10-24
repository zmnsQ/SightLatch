import Foundation

@main
struct VoiceDeadlineTests {
    static func main() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = SessionVoiceDeadline()
        precondition(clock.bind(phase: 0, expiresAt: origin.addingTimeInterval(300),
            now: origin.addingTimeInterval(240), uptime: 100))
        precondition(clock.uptimeDeadline == 160) // The wait has 60 seconds left.
        precondition(clock.bind(phase: 1, expiresAt: origin.addingTimeInterval(250),
            now: origin.addingTimeInterval(240), uptime: 100))
        precondition(clock.uptimeDeadline == 110)
        let executionEnd = origin.addingTimeInterval(544)
        precondition(clock.bind(phase: 2, expiresAt: executionEnd,
            now: origin.addingTimeInterval(244), uptime: 104))
        precondition(clock.uptimeDeadline == 404) // Confirmed ARM gets its fixed 300 seconds.
        precondition(clock.bind(phase: 2, expiresAt: executionEnd,
            now: origin.addingTimeInterval(300), uptime: 160))
        precondition(clock.uptimeDeadline == 404)
        // A backward wall-clock change cannot extend the already bound phase.
        precondition(clock.bind(phase: 2, expiresAt: executionEnd,
            now: origin.addingTimeInterval(290), uptime: 170))
        precondition(clock.uptimeDeadline == 404)
        precondition(!clock.bind(phase: 2, expiresAt: executionEnd.addingTimeInterval(1),
            now: origin.addingTimeInterval(301), uptime: 171))
        precondition(!clock.bind(phase: 1, expiresAt: origin.addingTimeInterval(310),
            now: origin.addingTimeInterval(301), uptime: 171))
        precondition(!clock.bind(phase: 2, expiresAt: executionEnd,
            now: executionEnd, uptime: 404))

        var resumed = SessionVoiceDeadline()
        precondition(resumed.bind(phase: 2, expiresAt: executionEnd,
            now: origin.addingTimeInterval(500), uptime: 1_000))
        precondition(resumed.uptimeDeadline == 1_044) // Reopening listening does not renew the task.
        precondition(!resumed.bind(phase: 2, expiresAt: executionEnd,
            now: origin.addingTimeInterval(530), uptime: 1_044))

        var latePoll = SessionVoiceDeadline()
        precondition(latePoll.bind(phase: 1, expiresAt: origin.addingTimeInterval(250),
            now: origin.addingTimeInterval(240), uptime: 100))
        // The task activated before the startup limit; the next audio callback
        // can observe that persisted transition after its old local limit.
        precondition(latePoll.bind(phase: 2, expiresAt: executionEnd,
            now: origin.addingTimeInterval(251), uptime: 111))
        precondition(latePoll.uptimeDeadline == 404)
        var unlimited = SessionVoiceDeadline()
        precondition(unlimited.bind(phase: 0, expiresAt: origin.addingTimeInterval(300), now: origin, uptime: 100))
        precondition(unlimited.bind(phase: 2, expiresAt: nil, unlimited: true, now: origin, uptime: 101))
        precondition(unlimited.isUnlimited && unlimited.uptimeDeadline == nil)
        precondition(unlimited.bind(phase: 2, expiresAt: nil, unlimited: true, now: origin.addingTimeInterval(9999), uptime: 9999))
        precondition(!unlimited.bind(phase: 1, expiresAt: origin.addingTimeInterval(10000), now: origin, uptime: 102))
        var invalid = SessionVoiceDeadline()
        precondition(!invalid.bind(phase: 2, expiresAt: nil, now: origin, uptime: 100))
        print("PASS: voice follows fixed preparation/startup/execution deadlines; refresh, reopening and clock rollback do not renew them")
    }
}
