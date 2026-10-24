// Only unrelated host fixtures use this already-confirmed hardware state.
// The startup timing tests exercise the real claim/activation methods instead.
extension SessionCommand {
    mutating func fixtureActiveExecution(stopGeneration: String?) {
        let now = Date()
        let capturedAt = max(createdAt, now.addingTimeInterval(-1))
        execution = SessionExecution(phase: .active, stopGeneration: stopGeneration,
            hardware: PreparedHardwareAuthorization(deviceURL: "http://hidbridge.local", softwareControl: true,
                bootID: "fixture", controlEpoch: "fixture", hidGeneration: 1),
            captureOwnerID: "fixture", captureStartedAt: capturedAt,
            startupExpiresAt: capturedAt.addingTimeInterval(10), startedAt: now,
            expiresAt: now.addingTimeInterval(300), hardwareSessionID: "fixture")
    }
}
