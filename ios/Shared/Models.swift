import Foundation
import ActivityKit

struct PilotConfiguration: Codable {
    var provider = "responses"
    var endpoint = "https://api.openai.com/v1/responses"
    var model = ""
    var deviceURL = "http://hidbridge.local"
    var uploadConsent = false
    var relativeModeConfirmed = false
    var allowLowRiskNavigation = false
    var gatewayVisionConfirmed: Bool?
    var calibratedAt: Date?
    var continuedProcessingEnabled: Bool?
    var maxSteps = 20
    var frameInterval: Double = 3
    var maxFrameAge: Double = 15
    var calibrationX: Double = 100
    var calibrationY: Double = 100
    var orientation = "portrait"
    var apiAccount: String { "api|" + provider + "|" + endpoint }
    var deviceAccount: String { "device|" + deviceURL }
}

struct SessionCommand: Codable {
    var id = UUID().uuidString
    var task: String
    var running: Bool
    var generation: Int = 0
    var createdAt = Date()
}

struct PilotStatus: Codable {
    var phase: String
    var detail: String
    var steps: Int
    var updatedAt = Date()
    var sessionID: String
    static let idle = PilotStatus(phase: "待机", detail: "尚未开始广播", steps: 0, sessionID: "")
}

struct ActionProposal: Codable {
    enum Kind: String, Codable { case move, click, scroll, key, text, wait, done, ask_user }
    var type: Kind
    var dx: Int?
    var dy: Int?
    var wheel: Int?
    var button: String?
    var key: String?
    var text: String?
    var purpose: String
    var risk: String
    var requiresConfirmation: Bool
    var reason: String
    var pointerVisible: Bool
    var highRisk: Bool
    var confidence: Double

    var description: String {
        switch type {
        case .move: return "相对移动 x=\(dx ?? 0), y=\(dy ?? 0)"
        case .scroll: return "滚动 \(wheel ?? 0)"
        case .click: return "点击 \(button ?? "left")"
        case .key: return "按键 \(key ?? "")"
        case .text: return "输入文本（\(text?.count ?? 0) 字符）"
        default: return type.rawValue
        }
    }
}

struct LogEntry: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var message: String
}

struct PilotActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var steps: Int
        var updatedAt: Date
    }
    var sessionID: String
}

enum PilotError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct SharedFrame: Codable {
    var sessionID: String
    var id: String
    var capturedAt: Date
    var jpeg: Data
    var fingerprint: Data
}
struct ExecutionLease: Codable {
    var sessionID: String
    var expiresAt: Date
}
