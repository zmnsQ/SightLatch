import Foundation
import Combine

struct PilotShortcutRequest: Identifiable {
    let id = UUID()
    let task: String?
    let startVoice: Bool
}

/// App-only, in-memory handoff. Never writes a running command or starts ReplayKit.
@MainActor
final class PilotShortcutRouter: ObservableObject {
    static let shared = PilotShortcutRouter()
    @Published private(set) var pendingRequest: PilotShortcutRequest?
    @Published private(set) var voiceRequestID: UUID?

    func open(task: String? = nil, startVoice: Bool = false) {
        let trimmed = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingRequest = PilotShortcutRequest(task: trimmed?.isEmpty == false ? trimmed : nil, startVoice: startVoice)
    }
    @discardableResult
    func consume() -> PilotShortcutRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
    func activateVoiceRequest() { voiceRequestID = UUID() }
    func consumeVoiceRequest() -> Bool {
        guard voiceRequestID != nil else { return false }
        voiceRequestID = nil
        return true
    }
}
