import Foundation

@main
struct VoiceFeedbackPreferencesTests {
    @MainActor static func main() {
        let suite = "SightLatch.tests.voiceFeedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VoiceFeedbackPreferences(defaults: defaults)
        preferences.spokenFeedbackEnabled = false
        preferences.provider = .fishAudio
        preferences.fishModel = .s21Pro
        preferences.fishReferenceID = "test-voice-id"

        let reopened = VoiceFeedbackPreferences(defaults: UserDefaults(suiteName: suite)!)
        precondition(!reopened.spokenFeedbackEnabled,
                     "Reopening the app must preserve an explicitly disabled announcement switch")
        precondition(reopened.provider == .fishAudio && reopened.fishModel == .s21Pro)
        precondition(reopened.fishReferenceID == "test-voice-id")
        reopened.provider = .system
        reopened.reloadAvailableVoices()
        precondition(!reopened.spokenFeedbackEnabled,
                     "Changing provider or refreshing voices must not enable announcements")

        var playback = VoiceFeedbackPlaybackGate()
        precondition(playback.begin(intent: .automatic, feedbackEnabled: reopened.spokenFeedbackEnabled) == nil)
        precondition(playback.begin(intent: .preview, feedbackEnabled: reopened.spokenFeedbackEnabled) != nil)
        precondition(!reopened.spokenFeedbackEnabled,
                     "Explicit preview permission must not change the persistent switch")
        print("PASS: persisted mute survives reopening, provider changes and preview")
    }
}
