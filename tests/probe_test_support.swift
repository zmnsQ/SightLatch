// Test doubles only; production saveDeviceConnection/probe methods are inserted unchanged.
enum PilotError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
struct Profile { var id = "profile"; var configuration = PilotConfiguration() }
struct Workspace { var profiles = [Profile()]; var selectedProfileID = "profile" }
final class SharedStore {
    static let shared = SharedStore()
    var stopGeneration: String? = nil
    var configuration = PilotConfiguration()
    var failWrite = false
    var writes = 0
    func write(_ value: PilotConfiguration, to: String) throws {
        if failWrite { throw PilotError.message("App Group 不可用") }
        configuration = value; writes += 1
    }
}
enum SecretStore {
    static var fail = false
    static var saves: [String] = []
    static func save(_ value: String, account: String) throws {
        if fail { throw PilotError.message("Keychain 保存失败：-34018") }
        saves.append(account)
    }
}
struct DeviceStatus {
    var hid_connected = true
    var boot_id = "boot"
    var control_epoch: String? = String(repeating: "a", count: 32)
    var armed = false
    var pairing_open: Bool? = true
    var supportsSoftwareControl = true
    var accessorySetupServiceUUID: String? = nil
}
enum DevicePairingCloseResult { case closed, unsupported, changed }
struct DevicePairingReceipt { var ok = true; var pairing_open = true; var boot_id = "boot"; var control_epoch = String(repeating: "a", count: 32) }
struct HardwareClient {
    let configuration: PilotConfiguration
    static var pairCalls = 0
    static var closeCalls = 0
    static var pairHandler: (() async throws -> DevicePairingReceipt) = { DevicePairingReceipt() }
    static var closeHandler: (() async throws -> DevicePairingCloseResult) = { .closed }
    func beginPairing(expected: DeviceStatus) async throws -> DevicePairingReceipt { Self.pairCalls += 1; return try await Self.pairHandler() }
    @MainActor
    func closePairingWindow(expected: DevicePairingReceipt, stillOwned: @MainActor () -> Bool) async throws -> DevicePairingCloseResult {
        guard stillOwned() else { return .changed }
        Self.closeCalls += 1; return try await Self.closeHandler()
    }
    static var calls = 0
    static var handler: (() async throws -> DeviceStatus) = { DeviceStatus() }
    func status() async throws -> DeviceStatus { Self.calls += 1; return try await Self.handler() }
}
@MainActor enum SightLatchAccessorySetupAdapter {
    static var releaseCalls = 0
    static func releaseConnectionsForSystemPairing() { releaseCalls += 1 }
}
@MainActor final class ProbeHarness {
    struct BusyState { var isBusy = false }
    var calibrationFlow = BusyState()
    var automaticCalibration = BusyState()
    var calibrationRequestInFlight = false
    var checkingTaskPrerequisites = false
    var deviceProbeTask: Task<DeviceStatus, Error>?
    var deviceProbeID = UUID()
    var probing = false
    var refreshingDeviceStatus = false
    var controllingDevice = false
    var stopping = false
    var preparingRequestInFlight = false
    var sending = false
    var probeState = DeviceProbeState.idle
    var sessionActive = false
    var isSessionActive: Bool { sessionActive || controllingDevice }
    var pairingState = DevicePairingState.idle
    var pairingUsesSystemMouse = false
    var pairingTask: Task<Void, Never>?
    var pairingCancelRequested = false
    var pairingWindowDuration: TimeInterval = 0.08
    var pairingPollNanoseconds: UInt64 = 5_000_000
    var deviceControlID = UUID()
    var storageWarning: String?
    var notice = ""
    var configuration = PilotConfiguration()
    var deviceToken = ""
    var workspace = Workspace()
    var failWorkspace = false
    var deviceObservationID = UUID()
    var lastDeviceStatus: DeviceStatus?
    var deviceStatusCheckedAt: Date?
    var observedDeviceURL: String?
    var deviceSummary = ""
    func persistWorkspace() -> Bool { if failWorkspace { notice = "保存工作区失败"; return false }; return true }
    func acceptDeviceStatus(_ value: DeviceStatus, from: PilotConfiguration) { guard configuration.deviceURL == from.deviceURL else { return }; lastDeviceStatus = value; deviceSummary = "局域网已响应 · BLE 已连接" }
