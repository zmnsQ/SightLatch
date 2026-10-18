struct PilotConfiguration {
    var deviceURL = "http://192.168.1.2"
    var provider = "responses"
    var apiAccount = "api-private-account"
    var deviceAccount = "device-private-account"
    var uploadConsent = false
    var relativeModeConfirmed = false
    var allowLowRiskNavigation = false
}
struct Status { var phase = "待机"; var steps = 0; var updatedAt = Date() }
struct Recovery { var title = "检查连接" }
struct SharedStore { static let shared = SharedStore(); var available = true }
enum SecretStore { static func load(_ key: String) throws -> String { "TOKEN_NEVER_EXPORT" } }
final class DiagnosticHarness {
    var configuration = PilotConfiguration()
    var status = Status()
    var recovery = Recovery()
    var lastDeviceStatus: DeviceStatus?
    var deviceStatusCheckedAt: Date?
    var observedDeviceURL: String?
    var deviceSummary = ""
    var lastDiagnosticSnapshot: [String: Any]?
    var diagnosticCapturedAt: Date?
    var diagnosticDeviceURL: String?
    var deviceStatusIsFresh: Bool {
        guard let checkedAt = deviceStatusCheckedAt, observedDeviceURL == configuration.deviceURL else { return false }
        return Date().timeIntervalSince(checkedAt) < 10 && lastDeviceStatus != nil
    }
