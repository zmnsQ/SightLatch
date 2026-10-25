import Foundation

enum SecretStore { static func load(_ account: String) throws -> String { "mock" }; static func save(_ value: String, account: String) throws {} }
enum AddressPolicy { static func device(_ value: String) throws -> URL { URL(string: value)! } }
extension PilotConfiguration { func validate() throws {} }
extension DeviceStatus {
    static func calibrationFixture(positionKnown: Bool? = nil, probeSupported: Bool? = true) -> DeviceStatus {
        // Decode the real wire type so mocks cannot hide production type/capability drift.
        let pointerFields = positionKnown.map {
            ",\"pointer_position_known\":\($0),\"pointer_mode\":\"relative\",\"hid_report_mode\":\"absolute\",\"relative_logical_step\":40"
        } ?? ""
        let probeFields = probeSupported.map { ",\"calibration_probe_supported\":\($0)" } ?? ""
        let json = """
        {"ok":true,"boot_id":"boot","uptime_ms":0,"armed":false,
         "hid_connected":true,"session_id":"session","next_sequence":1,"busy":false,
         "control_mode":"software","control_epoch":"epoch",
         "control_lease_mode":"none","lease_remaining_ms":60000,
         "absolute_pointer_supported":true,"absolute_probe_supported":true,"hid_generation":9,
         "absolute_position_known":false\(pointerFields)\(probeFields)}
        """
        return try! JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
    }
}
@MainActor struct HardwareClient {
    let configuration: PilotConfiguration
    static var device = DeviceStatus.calibrationFixture()
    static var calls: [String] = []
    static var armDelay: UInt64 = 0
    static var failStop = false
    static var failMove = false
    static var failProbe = false
    static var onProbe: (() -> Void)?
    static var onAbsoluteProbe: ((Int, Int) -> Void)?
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
    func sendCalibrationProbe(id: String, expectedBootID: String, expectedSession: String,
                              expectedControlEpoch: String?, frameDeadline: Date,
                              stillAuthorized: () -> Bool, willDispatch: () -> Void) async throws {
        guard stillAuthorized(), Self.device.armed, Self.device.calibration_probe_supported == true,
              Self.device.boot_id == expectedBootID, Self.device.session_id == expectedSession,
              Self.device.control_epoch == expectedControlEpoch, frameDeadline > Date() else { throw CancellationError() }
        Self.calls.append("probe")
        willDispatch(); Self.onProbe?()
        if Self.failProbe { throw PilotError.message("mock probe receipt failure") }
        guard stillAuthorized() else { throw CancellationError() }
    }
    func sendAbsoluteCalibrationProbe(id: String, hidX: Int, hidY: Int, expectedBootID: String,
        expectedHIDGeneration: UInt32, expectedSession: String, expectedControlEpoch: String?,
        frameDeadline: Date, stillAuthorized: @escaping () -> Bool, willDispatch: @escaping () -> Void) async throws -> DeviceStatus {
        guard stillAuthorized(), Self.device.armed, Self.device.absolute_probe_supported == true,
              Self.device.boot_id == expectedBootID, Self.device.session_id == expectedSession,
              Self.device.control_epoch == expectedControlEpoch, Self.device.hid_generation == expectedHIDGeneration,
              frameDeadline > Date() else { throw CancellationError() }
        Self.calls.append("absolute_probe")
        willDispatch(); Self.onAbsoluteProbe?(hidX, hidY)
        if Self.failProbe { throw PilotError.message("mock absolute receipt failure") }
        guard stillAuthorized() else { throw CancellationError() }
        Self.device.absolute_position_known = true; Self.device.absolute_hid_x = hidX; Self.device.absolute_hid_y = hidY
        return Self.device
    }
    func send(_ proposal: ActionProposal, expectedSession: String, frameDeadline: Date? = nil,
              stillAuthorized: (() -> Bool)? = nil, sessionAuthorized: (() -> Bool)? = nil) async throws {
        guard Self.device.armed, expectedSession == Self.device.session_id, stillAuthorized?() == true,
              frameDeadline! > Date() else { throw CancellationError() }
        precondition(proposal.type == .move)
        Self.calls.append("move")
        if Self.failMove { throw CancellationError() }
        if Self.device.pointer_position_known != nil { Self.device.pointer_position_known = true }
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
    var automaticCalibration = AutomaticCalibrationState()
    var isSessionActive: Bool { calibrationFlow.isBusy || sending }
}
@main struct CalibrationTests {
    @MainActor static func main() async throws {
        // New adapters must establish position through positioning, never a measurement ARM.
        let adapterModel = PilotViewModel()
        HardwareClient.device = .calibrationFixture(positionKnown: true, probeSupported: nil)
        await adapterModel.beginPointerCalibration()
        precondition(HardwareClient.calls == ["status"] && !HardwareClient.device.armed,
                     "Missing probe capability must reject before ARM with an upgrade explanation")
        precondition(adapterModel.notice.contains("固件"))
        HardwareClient.calls = []
        HardwareClient.device = .calibrationFixture(positionKnown: false)
        precondition(HardwareClient.device.pointer_mode == "relative" && HardwareClient.device.hid_report_mode == "absolute")
        precondition(HardwareClient.device.relative_logical_step == 40)
        await adapterModel.beginPointerCalibration()
        precondition(HardwareClient.calls == ["status"] && !HardwareClient.device.armed,
                     "Unknown adapter position must be rejected before measurement ARM")
        await adapterModel.beginPointerCalibration(purpose: .positioning)
        precondition(adapterModel.calibrationActive && adapterModel.calibrationFlow.pointerPositionKnown == false)
        HardwareClient.failMove = true
        await adapterModel.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(adapterModel.calibrationFlow.pointerPositionKnown == false && !HardwareClient.device.armed,
                     "A failed positioning move must not mark the adapter position as known")
        HardwareClient.failMove = false
        await adapterModel.beginPointerCalibration(purpose: .positioning)
        await adapterModel.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(adapterModel.calibrationFlow.pointerPositionKnown == true && !adapterModel.calibrationFlow.moved)
        await adapterModel.endPointerCalibration()
        precondition(!adapterModel.configuration.relativeModeConfirmed)
        await adapterModel.beginPointerCalibration()
        precondition(adapterModel.calibrationActive && adapterModel.calibrationFlow.pointerPositionKnown == true)
        await adapterModel.endPointerCalibration()
        // Fresh device status takes precedence over remembered knowledge from a previous lease.
        HardwareClient.device.pointer_position_known = false; HardwareClient.calls = []
        await adapterModel.beginPointerCalibration()
        precondition(HardwareClient.calls == ["status"] && !HardwareClient.device.armed)
        HardwareClient.device = .calibrationFixture(); HardwareClient.calls = []
        precondition(HardwareClient.device.pointer_position_known == nil && HardwareClient.device.pointer_mode == nil,
                     "Old firmware must remain decodable without adapter fields")
        let model = PilotViewModel()
        precondition(SharedStore.shared.stopGeneration == nil)
        precondition(!model.configuration.relativeModeConfirmed && model.configuration.model.isEmpty)
        HardwareClient.device.control_lease_mode = nil
        await model.beginPointerCalibration()
        precondition(!HardwareClient.calls.contains("arm"), "Old firmware must be rejected before ARM")
        HardwareClient.device.control_lease_mode = "none"
        await model.beginPointerCalibration()
        precondition(model.calibrationActive, "First-time calibration must not require a model or previous calibration")
        precondition(model.calibrationFlow.stopGeneration == nil, "A missing persisted STOP fence is a valid initial snapshot")
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
        precondition(SharedStore.shared.configuration.relativeModeConfirmed, "Confirmation must persist through the production store")
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
        // A cross-process STOP changes the persisted optional UUID fence, not an integer counter.
        try SharedStore.shared.invalidatePendingStarts()
        let fence = SharedStore.shared.stopGeneration
        precondition(fence != nil && UUID(uuidString: fence!) != nil)
        await model.beginPointerCalibration()
        precondition(model.calibrationActive && model.calibrationFlow.stopGeneration == fence)
        try SharedStore.shared.invalidatePendingStarts()
        precondition(SharedStore.shared.stopGeneration != fence)
        let movesBeforeStop = HardwareClient.calls.filter { $0 == "move" }.count
        await model.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(HardwareClient.calls.filter { $0 == "move" }.count == movesBeforeStop,
                     "A changed persisted STOP fence must block calibration movement")
        precondition(!HardwareClient.device.armed && !model.calibrationActive)
        await model.beginPointerCalibration()
        HardwareClient.failStop = true
        await model.endPointerCalibration()
        precondition(model.calibrationFlow.phase == .error && !model.confirmPointerCalibration())
        HardwareClient.failStop = false
        // Positioning movement is never measurement evidence or a successful saved calibration.
        await model.endPointerCalibration()
        model.configuration.relativeModeConfirmed = false
        await model.beginPointerCalibration(purpose: .positioning)
        precondition(model.calibrationActive)
        await model.moveCalibrationPointer(dx: 10, dy: 0)
        precondition(!model.calibrationFlow.moved)
        await model.endPointerCalibration()
        precondition(model.calibrationFlow.phase == .finished && model.calibrationFlow.stopConfirmed)
        precondition(!model.confirmPointerCalibration() && !model.configuration.relativeModeConfirmed)
        let armCount = HardwareClient.calls.filter { $0 == "arm" }.count
        await model.beginPointerCalibration(expectedStopGeneration: "stale-fence", enforceStopGeneration: true)
        precondition(HardwareClient.calls.filter { $0 == "arm" }.count == armCount)
        print("PASS: production calibration, DeviceStatus and SharedStore with mocked hardware: first-use entry, bounded movement, persisted confirmation, cancelled late ARM drained, optional UUID STOP fence blocks stale movement, expiry/reboot/failed STOP fail closed; no real hardware/API")
    }
}
