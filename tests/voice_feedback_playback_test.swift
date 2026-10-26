import Foundation

@main
struct VoiceFeedbackPlaybackTests {
    static func main() {
        var gate = VoiceFeedbackPlaybackGate()
        precondition(gate.begin(intent: .automatic, feedbackEnabled: false) == nil,
                     "A muted task must not enqueue startup or completion speech")
        let first = gate.begin(intent: .automatic, feedbackEnabled: true)!
        precondition(gate.permits(first, feedbackEnabled: true))
        precondition(!gate.permits(first, feedbackEnabled: false),
                     "Mute must reject a response even before cancellation is delivered")
        gate.cancel()
        precondition(!gate.permits(first, feedbackEnabled: true),
                     "Re-enabling feedback must not resurrect audio cancelled while muted")
        let sample = gate.begin(intent: .preview, feedbackEnabled: false)!
        precondition(gate.permits(sample, feedbackEnabled: false),
                     "An explicit sample is allowed without enabling task announcements")
        gate.cancel()
        precondition(!gate.permits(sample, feedbackEnabled: false),
                     "Closing a preview or switching provider invalidates its late synthesis")
        let obsolete = gate.begin(intent: .preview, feedbackEnabled: false)!
        let current = gate.begin(intent: .preview, feedbackEnabled: false)!
        precondition(!gate.permits(obsolete, feedbackEnabled: false))
        precondition(gate.permits(current, feedbackEnabled: false))
        precondition(gate.begin(intent: .automatic, feedbackEnabled: false) == nil)
        precondition(!gate.permits(current, feedbackEnabled: false),
                     "A muted automatic entry cannot inherit explicit preview permission")
        let activeTask = gate.begin(intent: .automatic, feedbackEnabled: true)!
        gate.cancel()
        precondition(!gate.permits(activeTask, feedbackEnabled: true),
                     "STOP or session replacement must reject in-flight responses")
        print("PASS: feedback mute, explicit preview, replacement, and late-response cancellation")
    }
}
