import Foundation

enum SecretStore { static func load(_ account: String) throws -> String { "mock" }; static func save(_ value: String, account: String) throws {} }
enum AddressPolicy { static func device(_ value: String) throws -> URL { URL(string: value)! } }
extension PilotConfiguration { func validate() throws {} }
struct DeviceStatus {
    var hid_connected = true, busy = false, armed = false
    var boot_id = "boot", session_id = "session", control_epoch: String? = "epoch"
    var supportsSoftwareControl = true
    var control_lease_mode: String? = "none"
    var lease_remaining_ms: Int? = 60_000
}
@MainActor final class SharedStore {
    static let shared = SharedStore()
    var stopGeneration = 0
    var configuration = PilotConfiguration()
    func write(_ value: PilotConfiguration, to: String) throws { configuration = value }
}
@MainActor struct HardwareClient {
    let configuration: PilotConfiguration
    static var device = DeviceStatus()
    static var calls: [String] = []
    static var armDelay: UInt64 = 0
    static var failStop = false
    func status() async throws -> DeviceStatus { Self.calls.append("status"); return Self.device }
    func armSoftwareControl(expected: DeviceStatus, mode: String? = nil) async throws -> DeviceStatus {
        precondition(mode == "calibration")
        Self.calls.append("arm")
        if Self.armDelay > 0 { try await Task.sleep(nanoseconds: Self.armDelay) }
        guard expected.boot_id == Self.device.boot_id, expected.control_epoch == Self.device.control_epoch else { throw CancellationError() }
        Self.device.armed = true; Self.device.control_lease_mode = mode; return Self.device
    }
    func stopAndVerify() async throws {
        Self.calls.append("stop")
        if Self.failStop { throw CancellationError() }
        Self.device.armed = false
    }
    func send(_ proposal: ActionProposal, expectedSession: String, frameDeadline: Date? = nil,
              stillAuthorized: (() -> Bool)? = nil, sessionAuthorized: (() -> Bool)? = nil) async throws {
        guard Self.device.armed, expectedSession == Self.device.session_id, stillAuthorized?() == true,
              frameDeadline! > Date() else { throw CancellationError() }
        precondition(proposal.type == .move)
        Self.calls.append("move")
    }
}
@MainActor final class PilotViewModel {
    var configuration = PilotConfiguration(), deviceToken = "", notice = ""
    var storageWarning: String?
    var calibrationFlow = PointerCalibrationState()
    var calibrationConfiguration: PilotConfiguration?
    var calibrationTimeoutTask: Task<Void, Never>?
    var calibrationRequestInFlight = false
    var sending = false, probing = false
    var taskFlow = TaskPlanningState()
    var isSessionActive: Bool { calibrationFlow.isBusy || sending }
}
@main struct CalibrationTests {
    @MainActor static func main() async throws {
        let model = PilotViewModel()
        precondition(!model.configuration.relativeModeConfirmed && model.configuration.model.isEmpty)
        HardwareClient.device.control_lease_mode = nil
        await model.beginPointerCalibration()
        precondition(!HardwareClient.calls.contains("arm"), "Old firmware must be rejected before ARM")
        HardwareClient.device.control_lease_mode = "none"
        await model.beginPointerCalibration()
        precondition(model.calibrationActive, "First-time calibration must not require a model or previous calibration")
        precondition(!model.taskFlow.consumePermission(goal: "unplanned"))
        precondition(!model.confirmPointerCalibration())
        let before = HardwareClient.calls.filter { $0 == "move" }.count
        await model.moveCalibrationPointer(dx: 21, dy: 0)
        await model.moveCalibrationPointer(dx: 10, dy: 10)
        precondition(HardwareClient.calls.filter { $0 == "move" }.count == before)
        await model.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(model.calibrationFlow.moved)
        await model.endPointerCalibration()
        precondition(model.calibrationFlow.phase == .finished && !HardwareClient.device.armed)
        precondition(!model.configuration.relativeModeConfirmed, "Stopping is not user confirmation")
        precondition(model.confirmPointerCalibration() && model.configuration.relativeModeConfirmed)
        precondition(!model.taskFlow.consumePermission(goal: "unplanned"))
        // Closing during an in-flight ARM must drain the late reply and STOP again.
        HardwareClient.armDelay = 100_000_000
        let pending = Task { await model.beginPointerCalibration() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.endPointerCalibration()
        await pending.value
        precondition(!HardwareClient.device.armed && !model.calibrationActive)
        precondition(model.calibrationFlow.phase == .error, "No observed move must not become verified calibration")
        HardwareClient.armDelay = 0
        await model.beginPointerCalibration()
        model.calibrationFlow.expiresAt = Date().addingTimeInterval(-1)
        let moves = HardwareClient.calls.filter { $0 == "move" }.count
        await model.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(HardwareClient.calls.filter { $0 == "move" }.count == moves)
        await model.endPointerCalibration()
        await model.beginPointerCalibration()
        HardwareClient.device.boot_id = "rebooted"
        await model.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(!HardwareClient.device.armed && !model.calibrationActive)
        await model.beginPointerCalibration()
        HardwareClient.failStop = true
        await model.endPointerCalibration()
        precondition(model.calibrationFlow.phase == .error && !model.confirmPointerCalibration())
        HardwareClient.failStop = false
        print("PASS: real calibration extension with mocked hardware: first-use entry without AI/calibration, task remains unauthorized, bounded single-axis move, stop before explicit user confirmation, cancelled late ARM drained, expiry/reboot/failed STOP fail closed; no real hardware/API")
    }
}
