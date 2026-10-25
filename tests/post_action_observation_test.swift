import Foundation

@main struct PostActionObservationTests {
    static func main() {
        let completed = Date(timeIntervalSince1970: 100)
        var policy = PostActionObservationPolicy()
        func allowed(_ age: TimeInterval, capturedAge: TimeInterval? = nil, lastCapture: Date = completed,
                     interval: TimeInterval = 3, busy: Bool = false) -> Bool {
            policy.permitsCapture(now: completed.addingTimeInterval(age),
                capturedAt: completed.addingTimeInterval(capturedAge ?? age),
                lastCapture: lastCapture, interval: interval, busy: busy)
        }
        precondition(!allowed(2.99) && allowed(3), "Ordinary wait/failure paths retain their interval")
        precondition(!allowed(3, busy: true))
        precondition(!allowed(0.99, interval: 1) && allowed(1, interval: 1), "Continued capture's ordinary interval remains unchanged")
        policy.completed(at: completed)
        precondition(policy.eligibleAfter == completed.addingTimeInterval(0.35))
        precondition(!allowed(0.2))
        precondition(!allowed(0.2, lastCapture: .distantPast), "Do not encode an unsettled frame even if the ordinary interval elapsed")
        precondition(allowed(0.35))
        precondition(!allowed(0.4, capturedAge: 0.2), "Queued frames sampled before settling cannot become the post-action observation")
        precondition(!allowed(0.4, busy: true))
        precondition(policy.eligibleAfter != nil, "Busy/skipped frames do not consume the one-shot")
        precondition(allowed(0.5))
        policy.beganEncoding()
        precondition(policy.eligibleAfter == nil)
        let encodedAt = completed.addingTimeInterval(0.5)
        precondition(!allowed(0.8, lastCapture: encodedAt))
        precondition(!allowed(3.49, lastCapture: encodedAt) && allowed(3.5, lastCapture: encodedAt), "The following ordinary frame does not inherit priority")
        policy.completed(at: completed)
        policy.reset()
        precondition(policy.eligibleAfter == nil && !allowed(0.5), "Generation/STOP reset cannot revive early observation")
        print("PASS: production one-shot post-HID observation at 350ms, fresh sample requirement, busy retention, encoding consumption, ordinary intervals and reset; no HID")
    }
}
