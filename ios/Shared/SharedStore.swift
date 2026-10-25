import Foundation
import Security
import Darwin

/// A separate OS lock spans the actual asynchronous hardware request. State
/// writes and STOP fences remain usable while this lock is held.
final class HardwareChannelLease: @unchecked Sendable {
    let ticket: String
    fileprivate let descriptor: Int32
    fileprivate init(ticket: String, descriptor: Int32) { self.ticket = ticket; self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
private struct HardwareChannelRecord: Codable {
    var ticket: String; var sessionID: String; var deviceURL: String; var bootID: String
    var mayHavePosted: Bool? = nil // nil is an older interrupted record and remains conservative.
}
struct HardwareChannelBusy: Error {}

// App Group never contains API/device secrets. Optional continued mode temporarily stores the latest protected frame; default mode does not.
final class SharedStore {
    static let shared = SharedStore()
    private let queue = DispatchQueue(label: "HIDPilot.files")
    private var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PilotAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    var available: Bool { directory != nil }
    func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        queue.sync {
            guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }
    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        guard let lockURL = directory?.appendingPathComponent("state.lock") else { throw PilotError.message("App Group 不可用，请检查三个 target 的签名配置。") }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PilotError.message("无法打开共享状态锁") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw PilotError.message("无法锁定共享状态") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func writeUnlocked<T: Encodable>(_ value: T, to name: String) throws {
        guard let url = directory?.appendingPathComponent(name) else { throw PilotError.message("App Group 不可用，请检查三个 target 的签名配置。") }
        let data = try JSONEncoder().encode(value)
        if name == "frame.json" {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var protectedURL = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
        } else {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        #if os(iOS) && canImport(ActivityKit)
        if name == "status.json", let status = value as? PilotStatus {
            queue.async { PilotActivityRelay.statusDidChange(status) }
        }
        #endif
    }
    func claimActivityAlert(sessionID: String, key: String) -> Bool {
        (try? queue.sync { try withFileLock {
            guard let directory, !sessionID.isEmpty, !key.isEmpty, key.count <= 200 else { return false }
            let url = directory.appendingPathComponent("activity-alerts.json")
            var claims = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))) ?? [:]
            guard !(claims[sessionID] ?? []).contains(key) else { return false }
            claims[sessionID, default: []].append(key)
            if claims.count > 8 { claims = [sessionID: claims[sessionID]!] }
            try writeUnlocked(claims, to: "activity-alerts.json")
            return true
        } }) ?? false
    }
    func write<T: Encodable>(_ value: T, to name: String) throws {
        try queue.sync { try withFileLock { try writeUnlocked(value, to: name) } }
    }
    // Persisted cancellation fence shared by UI and Live Activity / shortcut STOP.
    var stopGeneration: String? { read("stop-generation.json", as: String.self) }
    func invalidatePendingStarts() throws {
        try write(UUID().uuidString, to: "stop-generation.json")
    }
    func startCommand(_ command: SessionCommand, expectedStopGeneration: String?) throws {
        try queue.sync {
            try withFileLock {
                guard let directory else { throw PilotError.message("App Group 不可用") }
                let fenceURL = directory.appendingPathComponent("stop-generation.json")
                let current: String?
                if FileManager.default.fileExists(atPath: fenceURL.path) {
                    current = try JSONDecoder().decode(String.self, from: Data(contentsOf: fenceURL))
                } else { current = nil }
                guard current == expectedStopGeneration else { throw PilotError.message("已收到停止请求，请重新主动开始。") }
                let hardwareChannel = try preparedStartHardwareChannelUnlocked(authorization: command.execution?.hardware)
                try writeUnlocked(command, to: "command.json")
                withExtendedLifetime(hardwareChannel) {}
            }
        }
    }
    private func hardwareChannelUnlocked() throws -> HardwareChannelLease? {
        guard let url = directory?.appendingPathComponent("hardware-operation.lock") else { throw PilotError.message("App Group 不可用") }
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PilotError.message("无法打开硬件操作锁") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return HardwareChannelLease(ticket: UUID().uuidString, descriptor: descriptor)
    }
    private func hardwareRecordUnlocked() throws -> HardwareChannelRecord? {
        guard let url = directory?.appendingPathComponent("hardware-channel.json"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HardwareChannelRecord.self, from: Data(contentsOf: url))
    }
    private func uncertainHardwareRecordsUnlocked() throws -> [HardwareChannelRecord] {
        guard let url = directory?.appendingPathComponent("hardware-stop-uncertain.json"), FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if let records = try? JSONDecoder().decode([HardwareChannelRecord].self, from: data) { return records }
        // Migrate an interrupted operation written by the first local version.
        return [try JSONDecoder().decode(HardwareChannelRecord.self, from: data)]
    }
    private func preserveUncertainHardwareRecordUnlocked(_ record: HardwareChannelRecord) throws {
        var records = try uncertainHardwareRecordsUnlocked()
        if !records.contains(where: { $0.ticket == record.ticket }) { records.append(record) }
        try writeUnlocked(records, to: "hardware-stop-uncertain.json")
    }
    private func preparedStartHardwareChannelUnlocked(authorization: PreparedHardwareAuthorization?) throws -> HardwareChannelLease {
        guard let channel = try hardwareChannelUnlocked() else { throw PilotError.message("旧会话仍在完成设备授权或停止，请稍后明确重试。") }
        try validateHardwareRecoveryUnlocked(authorization: authorization)
        return channel
    }
    private func validateHardwareRecoveryUnlocked(authorization: PreparedHardwareAuthorization?) throws {
        if let abandoned = try hardwareRecordUnlocked() {
            if abandoned.mayHavePosted != false { try preserveUncertainHardwareRecordUnlocked(abandoned) }
            if let url = directory?.appendingPathComponent("hardware-channel.json") { try FileManager.default.removeItem(at: url) }
        }
        let previousRecords = try uncertainHardwareRecordsUnlocked()
        var retained: [HardwareChannelRecord] = []
        for previous in previousRecords {
            guard let authorization, !authorization.bootID.isEmpty, previous.bootID != "unknown",
                  previous.bootID != authorization.bootID else {
                throw PilotError.message("上次设备清理结果不明，尚不能开启新会话。请重新给ESP供电，再检查设备后明确重试。")
            }
            // Only this target's fresh reboot proves its old TCP/ARM epoch ended.
            // Another target may run, but cannot erase the first target's record.
            if previous.deviceURL != authorization.deviceURL { retained.append(previous) }
        }
        if retained.count != previousRecords.count { try writeUnlocked(retained, to: "hardware-stop-uncertain.json") }
    }
    /// Returns nil for a busy channel or a stale/losing capture owner. Never
    /// wait for a network operation while holding the state lock or MainActor.
    func acquireCaptureHardwareChannel(sessionID: String, captureOwnerID: String) throws -> HardwareChannelLease? {
        try queue.sync { try withFileLock {
            guard let channel = try hardwareChannelUnlocked(), let directory else { return nil }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")) else { return nil }
            let command = try JSONDecoder().decode(SessionCommand.self, from: data)
            guard command.id == sessionID,
                  command.execution?.captureOwnerID == captureOwnerID ||
                    (command.execution?.phase == .awaitingCapture && command.execution?.captureOwnerID == nil) else { return nil }
            guard try hardwareRecordUnlocked() == nil else { throw PilotError.message("旧硬件操作结果不明，需要重新给设备供电后再开始。") }
            try validateHardwareRecoveryUnlocked(authorization: command.execution?.hardware)
            let record = HardwareChannelRecord(ticket: channel.ticket, sessionID: sessionID,
                deviceURL: command.execution?.hardware.deviceURL ?? "unknown", bootID: command.execution?.hardware.bootID ?? "unknown")
            try writeUnlocked(record, to: "hardware-channel.json")
            return channel
        } }
    }
    func finishCaptureHardwareChannel(_ channel: HardwareChannelLease, confirmed: Bool) throws {
        try queue.sync { try withFileLock {
            guard let record = try hardwareRecordUnlocked(), record.ticket == channel.ticket else { return }
            if !confirmed, record.mayHavePosted != false { try preserveUncertainHardwareRecordUnlocked(record) }
            if let url = directory?.appendingPathComponent("hardware-channel.json") { try FileManager.default.removeItem(at: url) }
        } }
    }
    func identifyHardwareChannel(_ channel: HardwareChannelLease, deviceURL: String, bootID: String) throws {
        try queue.sync { try withFileLock {
            guard var record = try hardwareRecordUnlocked(), record.ticket == channel.ticket, !bootID.isEmpty else {
                throw PilotError.message("硬件操作所有权已变化")
            }
            record.deviceURL = deviceURL; record.bootID = bootID; record.mayHavePosted = true
            try writeUnlocked(record, to: "hardware-channel.json")
        } }
    }
    func acquireStopHardwareChannel(deviceURL: String, expectedSessionID: String?, captureOwnerID: String?) throws -> HardwareChannelLease? {
        try queue.sync { try withFileLock {
            guard let channel = try hardwareChannelUnlocked() else { throw HardwareChannelBusy() }
            let command: SessionCommand? = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("command.json")) }
                .flatMap { try? JSONDecoder().decode(SessionCommand.self, from: $0) }
            if let expectedSessionID { guard command?.id == expectedSessionID else { return nil } }
            if let captureOwnerID {
                guard command?.execution?.captureOwnerID == captureOwnerID ||
                    (command?.execution?.phase == .awaitingCapture && command?.execution?.captureOwnerID == nil) else { return nil }
            }
            if let previous = try hardwareRecordUnlocked(), previous.mayHavePosted != false { try preserveUncertainHardwareRecordUnlocked(previous) }
            let record = HardwareChannelRecord(ticket: channel.ticket, sessionID: command?.id ?? "none",
                deviceURL: deviceURL,
                bootID: command?.execution?.hardware.deviceURL == deviceURL ? command?.execution?.hardware.bootID ?? "unknown" : "unknown",
                mayHavePosted: false)
            try writeUnlocked(record, to: "hardware-channel.json")
            return channel
        } }
    }
    func recordRuntimeStopFailure(sessionID: String, captureOwnerID: String?) {
        _ = try? updateCommand(sessionID: sessionID) { command in
            guard captureOwnerID == nil || command.execution?.captureOwnerID == captureOwnerID else { return }
            command.running = false
            let previous = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("status.json")) }
                .flatMap { try? JSONDecoder().decode(PilotStatus.self, from: $0) }
            try writeUnlocked(PilotStatus(phase: "请核实硬件停止", detail: "本地执行已撤销，但未确认设备停止。请断开设备电源后重新检查。",
                steps: previous?.sessionID == sessionID ? previous?.steps ?? 0 : 0, sessionID: sessionID), to: "status.json")
        }
    }
    func recordUnconfirmedHardwareStop(sessionID: String, deviceURL: String, bootID: String) throws {
        try queue.sync { try withFileLock {
            try preserveUncertainHardwareRecordUnlocked(HardwareChannelRecord(ticket: UUID().uuidString, sessionID: sessionID, deviceURL: deviceURL, bootID: bootID))
        } }
    }
    // Serialize read-modify-write across App, ReplayKit and LiveActivityIntent processes.
    // Old-session callbacks cannot replace a newly prepared session or resurrect a stopped command.
    @discardableResult
    func updateCommand(sessionID: String, expectedStopGeneration: String? = nil, enforceStopGeneration: Bool = false, _ mutation: (inout SessionCommand) throws -> Void) throws -> Bool {
        try queue.sync {
            try withFileLock {
                if enforceStopGeneration {
                    guard let fenceURL = directory?.appendingPathComponent("stop-generation.json") else { throw PilotError.message("App Group 不可用") }
                    let actual = FileManager.default.fileExists(atPath: fenceURL.path)
                        ? try JSONDecoder().decode(String.self, from: Data(contentsOf: fenceURL)) : nil
                    guard actual == expectedStopGeneration else { throw PilotError.message("已收到停止请求；旧操作不能继续。") }
                }
                guard let url = directory?.appendingPathComponent("command.json"),
                      let data = try? Data(contentsOf: url) else { return false }
                var current = try JSONDecoder().decode(SessionCommand.self, from: data)
                guard current.id == sessionID else { return false }
                try mutation(&current)
                try writeUnlocked(current, to: "command.json")
                return true
            }
        }
    }
    // Startup diagnostics cannot revoke or replace a newer command or an
    // explicit STOP. Keep their session, generation and STOP fence together.
    @discardableResult
    func recordCaptureStartupFailure(sessionID: String, generation: Int,
                                     expectedStopGeneration: String?, reason: String) throws -> Bool {
        try queue.sync {
            try withFileLock {
                guard let directory else { throw PilotError.message("App Group 不可用") }
                let fenceURL = directory.appendingPathComponent("stop-generation.json")
                let fence = FileManager.default.fileExists(atPath: fenceURL.path)
                    ? try JSONDecoder().decode(String.self, from: Data(contentsOf: fenceURL)) : nil
                guard fence == expectedStopGeneration else { return false }
                let commandURL = directory.appendingPathComponent("command.json")
                guard let data = try? Data(contentsOf: commandURL) else { return false }
                var command = try JSONDecoder().decode(SessionCommand.self, from: data)
                guard command.id == sessionID, command.generation == generation, command.running else { return false }
                guard command.execution?.captureOwnerID == nil else { return false } // A rejected duplicate cannot revoke the winning capture.
                let observation = CaptureObservation(sessionID: sessionID, state: "failed", generation: generation,
                    failureReason: reason, failureStopGeneration: expectedStopGeneration)
                command.running = false
                try writeUnlocked(command, to: "command.json")
                try writeUnlocked(observation, to: "capture-status.json")
                try writeUnlocked(PilotStatus(phase: "停止", detail: reason, steps: 0, sessionID: sessionID), to: "status.json")
                return true
            }
        }
    }
    // Used only while this instance's file queue and cross-process lock are held.
    private func currentUploadConsentUnlocked() -> Bool {
        guard let url = directory?.appendingPathComponent("configuration.json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(PilotConfiguration.self, from: data) else { return false }
        return configuration.uploadConsent
    }
    private func currentContinuedModeUnlocked() -> Bool {
        guard let url = directory?.appendingPathComponent("configuration.json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(PilotConfiguration.self, from: data) else { return false }
        return configuration.continuedProcessingEnabled == true
    }
    private func currentDeviceURLUnlocked() -> String? {
        guard let url = directory?.appendingPathComponent("configuration.json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(PilotConfiguration.self, from: data) else { return nil }
        return configuration.deviceURL
    }
    /// One real capture consumes the prepared start. Neither process reload,
    /// repeated frames nor an ARM failure can create a second execution window.
    func claimCaptureExecution(sessionID: String, generation: Int, expectedStopGeneration: String?,
                               captureOwnerID: String, firstFrame: CaptureObservation) throws -> SessionCommand {
        var claimed: SessionCommand?
        let changed = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            let now = Date()
            guard currentUploadConsentUnlocked(), command.authorizationIsCurrent(now: now), command.generation == generation,
                  var execution = command.execution, execution.phase == .awaitingCapture,
                  execution.stopGeneration == expectedStopGeneration,
                  currentDeviceURLUnlocked() == execution.hardware.deviceURL, !captureOwnerID.isEmpty,
                  firstFrame.sessionID == sessionID, firstFrame.generation == generation, firstFrame.hasFreshFrame,
                  let capturedAt = firstFrame.receivedAt, capturedAt >= command.createdAt, capturedAt <= now,
                  capturedAt < command.preparationExpiresAt,
                  (firstFrame.sourceWidth ?? 0) > 0, (firstFrame.sourceHeight ?? 0) > 0 else {
                throw PilotError.message("首次广播画面或准备授权已过期；请明确开始一个新会话。")
            }
            let end = capturedAt.addingTimeInterval(SessionExecution.hardwareStartupTimeout)
            guard end > now, execution.hardware.physicalExpiresAt.map({ $0 > now }) ?? true else { throw PilotError.message("首帧启动或物理ARM期限已结束；不会自动续租。") }
            execution.phase = .startingHardware
            execution.captureOwnerID = captureOwnerID; execution.captureStartedAt = capturedAt; execution.startupExpiresAt = end
            execution.messageScopeID = command.messageScope?.id
            command.execution = execution
            if let scope = command.messageScope {
                guard scope.matches(sessionID: command.id, generation: command.generation, task: command.task, now: capturedAt),
                      scope.stopGeneration == expectedStopGeneration else { throw PilotError.message("首帧到达时消息授权已变化。") }
            }
            claimed = command
        }
        guard changed, let claimed else { throw PilotError.message("首帧启动时会话已更换。") }
        return claimed
    }
    func activateCaptureExecution(sessionID: String, generation: Int, expectedStopGeneration: String?, captureOwnerID: String,
        hardwareBootID: String, controlEpoch: String?, hidGeneration: UInt32?, hardwareSessionID: String,
        hardwareLeaseRemainingMS: Int? = nil) throws -> SessionCommand {
        var activated: SessionCommand?
        let changed = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.authorizationIsCurrent(), command.generation == generation,
                  var execution = command.execution, execution.phase == .startingHardware,
                  execution.stopGeneration == expectedStopGeneration, execution.captureOwnerID == captureOwnerID,
                  currentDeviceURLUnlocked() == execution.hardware.deviceURL,
                  execution.hardware.bootID == hardwareBootID, execution.hardware.controlEpoch == controlEpoch,
                  execution.hardware.hidGeneration == hidGeneration, !hardwareSessionID.isEmpty,
                  command.messageScope?.id == execution.messageScopeID,
                  execution.hardware.softwareControl || execution.hardware.physicalSessionID == hardwareSessionID else {
                throw PilotError.message("首帧控制授权、设备代次或停止状态已变化，不会重新ARM。")
            }
            let startedAt = Date()
            guard execution.startupExpiresAt.map({ startedAt < $0 }) == true else { throw PilotError.message("首次设备授权已超时，不能迟到激活。") }
            let maximum = startedAt.addingTimeInterval(execution.boundedDuration)
            let end: Date?
            if execution.hardware.softwareControl { end = execution.isUnlimited ? nil : maximum }
            else {
                guard !execution.isUnlimited,
                      let remaining = hardwareLeaseRemainingMS, remaining > 0, remaining <= 300000,
                      let preparedEnd = execution.hardware.physicalExpiresAt else { throw PilotError.message("物理ARM剩余期限未确认，不能不限时运行。") }
                end = min(preparedEnd, startedAt.addingTimeInterval(Double(remaining) / 1000), maximum)
            }
            guard end.map({ $0 > startedAt }) ?? execution.isUnlimited else { throw PilotError.message("物理ARM期限已结束；不会自动续租。") }
            if execution.renewableHardwareLease == true {
                guard let remaining = hardwareLeaseRemainingMS, remaining > 0, remaining <= 30000 else { throw PilotError.message("设备未确认短期控制租约。") }
                execution.hardwareLeaseExpiresAt = startedAt.addingTimeInterval(Double(remaining) / 1000)
                execution.nextRenewalSequence = 1
            }
            execution.hardwareSessionID = hardwareSessionID; execution.phase = .active
            execution.startedAt = startedAt; execution.expiresAt = end
            command.execution = execution; activated = command
            if var scope = command.messageScope {
                guard scope.stopGeneration == expectedStopGeneration,
                      execution.captureStartedAt.flatMap({ captured in scope.expiresAt.map { captured < $0 } }) == true else { throw PilotError.message("首次捕获时的消息授权已失效。") }
                scope.expiresAt = end; scope.isUnlimited = execution.isUnlimited; command.messageScope = scope; activated = command
            }
        }
        guard changed, let activated else { throw PilotError.message("首帧控制授权的会话已更换。") }
        return activated
    }
    func reserveHardwareRenewal(sessionID: String, captureOwnerID: String, expectedStopGeneration: String?) throws -> SessionCommand {
        var result: SessionCommand?
        let updated = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.authorizationIsCurrent(requireActive: true),
                  var execution = command.execution, execution.renewableHardwareLease == true,
                  execution.captureOwnerID == captureOwnerID,
                  execution.stopGeneration == expectedStopGeneration,
                  currentDeviceURLUnlocked() == execution.hardware.deviceURL,
                  let sequence = execution.nextRenewalSequence, sequence > 0, sequence < Int(UInt32.max) else {
                throw PilotError.message("续租授权已撤销；不会重新ARM。")
            }
            result = command // The reserved sequence is consumed before any POST.
            execution.nextRenewalSequence = sequence + 1; command.execution = execution
        }
        guard updated, let result else { throw PilotError.message("续租会话已更换。") }
        return result
    }
    func confirmHardwareRenewal(sessionID: String, captureOwnerID: String, expectedStopGeneration: String?,
                                sequence: Int, remainingMS: Int, requestStartedAt: Date) throws {
        guard remainingMS > 0, remainingMS <= 30000 else { throw PilotError.message("续租期限无效。") }
        let updated = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.authorizationIsCurrent(requireActive: true),
                  var execution = command.execution, execution.renewableHardwareLease == true,
                  execution.captureOwnerID == captureOwnerID, execution.nextRenewalSequence == sequence + 1,
                  (execution.lastConfirmedRenewalSequence ?? 0) < sequence,
                  execution.stopGeneration == expectedStopGeneration,
                  currentDeviceURLUnlocked() == execution.hardware.deviceURL else { throw CancellationError() }
            // Subtract the whole request latency rather than overstate the remaining hardware lease.
            let end = requestStartedAt.addingTimeInterval(Double(remainingMS) / 1000)
            guard end > Date() else { throw PilotError.message("续租响应已过期。") }
            execution.lastConfirmedRenewalSequence = sequence
            execution.hardwareLeaseExpiresAt = command.authorizationExpiresAt.map { min($0, end) } ?? end
            command.execution = execution
        }
        guard updated else { throw CancellationError() }
    }
    /// A real first frame starts the scheduler handoff, not the user's earlier
    /// preparation. No executor or synthetic lease exists while awaiting it.
    func claimContinuedStart(sessionID: String, generation: Int, expectedStopGeneration: String?,
                             firstFrame: CaptureObservation) throws -> SessionCommand {
        var claimed: SessionCommand?
        let updated = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), currentContinuedModeUnlocked(), command.running, command.generation == generation,
                  command.authorizationIsCurrent(requireActive: true),
                  var execution = command.continuedExecution, execution.phase == .awaitingFirstFrame,
                  execution.stopGeneration == expectedStopGeneration,
                  firstFrame.sessionID == sessionID, firstFrame.generation == generation, firstFrame.hasFreshFrame,
                  let receivedAt = firstFrame.receivedAt, receivedAt >= command.createdAt, receivedAt <= Date() else {
                throw PilotError.message("后台执行启动前的首帧、会话或停止边界已失效。")
            }
            execution.phase = .starting; execution.requestedAt = Date()
            command.continuedExecution = execution
            claimed = command
        }
        guard updated, let claimed else { throw PilotError.message("后台执行启动时会话已变化。") }
        return claimed
    }
    /// Publish the real lease before making the execution owner active. Readers
    /// may see a waiting owner with a lease, never an active owner without one.
    func activateContinuedStart(sessionID: String, generation: Int, expectedStopGeneration: String?) throws -> SessionCommand {
        var activated: SessionCommand?
        let updated = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), currentContinuedModeUnlocked(), command.running, command.generation == generation,
                  command.authorizationIsCurrent(requireActive: true),
                  var execution = command.continuedExecution, execution.phase == .starting,
                  execution.stopGeneration == expectedStopGeneration, let requestedAt = execution.requestedAt,
                  Date().timeIntervalSince(requestedAt) >= 0,
                  Date().timeIntervalSince(requestedAt) < ContinuedExecution.startupTimeout else {
                throw PilotError.message("后台执行回调已过期或会话已停止，不会接管。")
            }
            try writeUnlocked(ExecutionLease(sessionID: sessionID, expiresAt: command.boundedDeadline(after: 6)), to: "lease.json")
            execution.phase = .active; command.continuedExecution = execution
            activated = command
        }
        guard updated, let activated else { throw PilotError.message("后台执行回调的会话已变化。") }
        return activated
    }
    @discardableResult
    func failContinuedStart(sessionID: String, generation: Int, expectedStopGeneration: String?,
                            expectedRequestedAt: Date? = nil, reason: String) throws -> Bool {
        var failed = false
        let updated = try updateCommand(sessionID: sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard command.running, command.generation == generation,
                  let execution = command.continuedExecution,
                  execution.stopGeneration == expectedStopGeneration else { return }
            if let expectedRequestedAt {
                guard execution.requestedAt == expectedRequestedAt,
                      execution.phase == .starting || execution.phase == .active else { return }
            } else {
                guard execution.phase == .awaitingFirstFrame, execution.requestedAt == nil else { return }
            }
            try writeUnlocked(PilotStatus(phase: "暂停", detail: reason, steps: 0, sessionID: sessionID), to: "status.json")
            command.running = false
            failed = true
        }
        return updated && failed
    }
    /// Only the active executor may stage a question after discarding its
    /// proposal, before any side-effecting request. This never changes ARM.
    func requestClarification(proposal: ActionProposal, sessionID: String, generation: Int,
                              frameID: String, expectedStopGeneration: String?) throws -> SessionClarification {
        try queue.sync { try withFileLock {
            guard let directory else { throw PilotError.message("App Group 不可用") }
            var command = try JSONDecoder().decode(SessionCommand.self,
                from: Data(contentsOf: directory.appendingPathComponent("command.json")))
            guard command.id == sessionID, command.generation == generation else {
                throw PilotError.message("提问所属会话已变化；不会替换当前任务。")
            }
            try requireConfirmedClarificationControlUnlocked(command)
            let pending = try SessionClarificationPolicy.make(proposal: proposal, command: command,
                frameID: frameID, expectedStopGeneration: expectedStopGeneration,
                actualStopGeneration: clarificationFenceUnlocked(), uploadConsent: currentUploadConsentUnlocked())
            command.pendingClarification = pending
            try writeUnlocked(command, to: "command.json")
            // The command is authoritative if a secondary status write fails.
            // Readers can still derive the waiting UI from pendingClarification.
            try? writeClarificationStatusUnlocked(sessionID: sessionID, phase: "等待用户",
                detail: pending.question, userMessage: pending.question)
            return pending
        } }
    }
    /// App and Live Activity answers compete for the same persisted question.
    /// The winning answer bumps the generation once, retaining every attempt
    /// ledger, execution timestamp and hardware identity from the old command.
    func resolveClarification(sessionID: String, questionID: String, optionID: String) throws -> SessionCommand {
        try queue.sync { try withFileLock {
            guard let directory else { throw PilotError.message("App Group 不可用") }
            let command = try JSONDecoder().decode(SessionCommand.self,
                from: Data(contentsOf: directory.appendingPathComponent("command.json")))
            try requireConfirmedClarificationControlUnlocked(command)
            let resolved = try SessionClarificationPolicy.resolving(command: command, sessionID: sessionID,
                questionID: questionID, optionID: optionID, actualStopGeneration: clarificationFenceUnlocked(),
                uploadConsent: currentUploadConsentUnlocked())
            try writeUnlocked(resolved, to: "command.json")
            try? writeClarificationStatusUnlocked(sessionID: sessionID, phase: "观察",
                detail: "已收到选择，正在查看新画面", userMessage: nil)
            return resolved
        } }
    }
    private func writeClarificationStatusUnlocked(sessionID: String, phase: String,
                                                  detail: String, userMessage: String?) throws {
        guard let directory else { return }
        let url = directory.appendingPathComponent("status.json")
        let previous = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(PilotStatus.self, from: Data(contentsOf: url)) : nil
        guard previous == nil || previous?.sessionID == sessionID else { return }
        try writeUnlocked(PilotStatus(phase: phase, detail: detail, steps: previous?.steps ?? 0,
            sessionID: sessionID, userMessage: userMessage), to: "status.json")
    }
    private func clarificationFenceUnlocked() throws -> String? {
        guard let directory else { throw PilotError.message("App Group 不可用") }
        let url = directory.appendingPathComponent("stop-generation.json")
        return FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(String.self, from: Data(contentsOf: url)) : nil
    }
    private func requireConfirmedClarificationControlUnlocked(_ command: SessionCommand) throws {
        if let directory {
            let status = (try? Data(contentsOf: directory.appendingPathComponent("status.json")))
                .flatMap { try? JSONDecoder().decode(PilotStatus.self, from: $0) }
            guard status?.sessionID != command.id || status?.phase != "请核实硬件停止" else {
                throw PilotError.message("设备停止尚未确认，不能通过回答恢复执行。")
            }
        }
        let uncertain = try uncertainHardwareRecordsUnlocked()
        guard !uncertain.contains(where: { record in
            record.sessionID == command.id || record.bootID == command.execution?.hardware.bootID ||
                (record.bootID == "unknown" && record.deviceURL == command.execution?.hardware.deviceURL)
        }) else { throw PilotError.message("设备操作结果不明，不能通过回答恢复执行。") }
    }
    /// Last local instruction wins within one still-active generation. The
    /// runtime, not the speech callback, commits it after its hardware receipt.
    func enqueueGoalInstruction(_ instruction: SessionGoalInstruction) throws {
        try queue.sync { try withFileLock {
            guard let directory else { throw PilotError.message("App Group 不可用") }
            let command = try JSONDecoder().decode(SessionCommand.self,
                from: Data(contentsOf: directory.appendingPathComponent("command.json")))
            let fenceURL = directory.appendingPathComponent("stop-generation.json")
            let fence = FileManager.default.fileExists(atPath: fenceURL.path)
                ? try JSONDecoder().decode(String.self, from: Data(contentsOf: fenceURL)) : nil
            let now = Date()
            let goal = instruction.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentUploadConsentUnlocked(), command.running, command.pendingClarification == nil,
                  command.id == instruction.sessionID, command.generation == instruction.generation,
                  fence == instruction.expectedStopGeneration,
                  command.authorizationIsCurrent(now: now),
                  instruction.createdAt >= command.createdAt, instruction.createdAt <= now,
                  now.timeIntervalSince(instruction.createdAt) < 30,
                  !instruction.id.isEmpty, !goal.isEmpty, goal.count <= 2000 else {
                throw PilotError.message("续指令的会话、停止状态或有效时间已变化；未替换当前目标。")
            }
            var pending = instruction
            pending.goal = goal
            try writeUnlocked(pending, to: "voice-instruction.json")
        } }
    }
    /// Call only when this runtime has no HID request in flight. Generation
    /// changes invalidate every old proposal before a new frame is planned.
    func applyPendingGoal(sessionID: String, expectedGeneration: Int) throws -> SessionCommand? {
        try queue.sync { try withFileLock {
            guard let directory else { throw PilotError.message("App Group 不可用") }
            let pendingURL = directory.appendingPathComponent("voice-instruction.json")
            guard FileManager.default.fileExists(atPath: pendingURL.path) else { return nil }
            let pending = try JSONDecoder().decode(SessionGoalInstruction.self, from: Data(contentsOf: pendingURL))
            let commandURL = directory.appendingPathComponent("command.json")
            guard FileManager.default.fileExists(atPath: commandURL.path) else { return nil }
            var command = try JSONDecoder().decode(SessionCommand.self, from: Data(contentsOf: commandURL))
            // A stale runtime cannot delete a newer session's queued instruction.
            guard command.id == sessionID, command.generation == expectedGeneration,
                  command.pendingClarification == nil else { return nil }
            let fenceURL = directory.appendingPathComponent("stop-generation.json")
            let fence = FileManager.default.fileExists(atPath: fenceURL.path)
                ? try JSONDecoder().decode(String.self, from: Data(contentsOf: fenceURL)) : nil
            let now = Date()
            let goal = pending.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentUploadConsentUnlocked(), command.running,
                  pending.sessionID == sessionID, pending.generation == expectedGeneration,
                  fence == pending.expectedStopGeneration,
                  command.authorizationIsCurrent(now: now),
                  pending.createdAt >= command.createdAt, pending.createdAt <= now,
                  now.timeIntervalSince(pending.createdAt) < 30,
                  !pending.id.isEmpty, !goal.isEmpty, goal.count <= 2000,
                  command.generation < Int.max else {
                try FileManager.default.removeItem(at: pendingURL)
                return nil
            }
            command.task = goal
            command.generation += 1
            if let intent = MessageIntent.parse(goal) {
                command.messageScope = MessageScope(intent: intent, sessionID: command.id,
                    generation: command.generation, expiresAt: command.authorizationExpiresAt,
                    isUnlimited: command.isUnlimited, stopGeneration: pending.expectedStopGeneration, clipboardPrepared: false)
            } else { command.messageScope = nil }
            try writeUnlocked(command, to: "command.json")
            // If removal fails, the committed generation still makes replay impossible.
            try? FileManager.default.removeItem(at: pendingURL)
            return command
        } }
    }
    /// The foreground host calls this only after writing this scope's exact body
    /// to the local clipboard; it cannot mark an old or replaced scope ready.
    func markMessageClipboardPrepared(context: MessageDispatchContext, expectedStopGeneration: String?, expiresAt: Date? = nil) throws {
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.running, command.generation == context.generation,
                  command.authorizationIsCurrent(),
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.stopGeneration == expectedStopGeneration,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task) else {
                throw PilotError.message("消息正文准备时会话已变化；不会授权粘贴。")
            }
            let clipboardEnd = min(expiresAt ?? command.boundedDeadline(after: 600), command.boundedDeadline(after: 600))
            guard clipboardEnd > Date() else { throw PilotError.message("消息正文准备已过期，请回前台重新准备。") }
            scope.clipboardPrepared = true
            scope.clipboardExpiresAt = clipboardEnd
            command.messageScope = scope
        }
        guard updated else { throw PilotError.message("消息正文准备时会话已变化；不会授权粘贴。") }
    }
    func beginMessageLaunch(context: MessageDispatchContext, expectedStopGeneration: String?, firstFrame: CaptureObservation) throws {
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.authorizationIsCurrent(requireActive: true), command.generation == context.generation,
                  command.pendingClarification == nil,
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.stopGeneration == expectedStopGeneration,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
                  scope.launch.phase == .pending, firstFrame.sessionID == command.id,
                  firstFrame.generation == command.generation, firstFrame.hasFreshFrame,
                  let receivedAt = firstFrame.receivedAt, receivedAt >= command.createdAt, receivedAt <= Date() else {
                throw PilotError.message("打开微信前的会话或首帧已变化。")
            }
            scope.launch.phase = .opening
            scope.launch.requestedUptime = ProcessInfo.processInfo.systemUptime
            command.messageScope = scope
        }
        guard updated else { throw PilotError.message("打开微信的会话已变化。") }
    }
    func releaseMessageLaunchClaim(context: MessageDispatchContext, expectedStopGeneration: String?) throws {
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard command.running, command.generation == context.generation,
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.stopGeneration == expectedStopGeneration,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
                  scope.launch.phase == .opening, scope.launch.dispatchedUptime == nil else {
                throw PilotError.message("已派发或失效的微信请求不能重新进入等待。");
            }
            scope.launch.phase = .pending
            scope.launch.requestedUptime = nil
            command.messageScope = scope
        }
        guard updated else { throw PilotError.message("打开微信的会话已变化。") }
    }
    func markMessageLaunchDispatched(context: MessageDispatchContext, expectedStopGeneration: String?) throws {
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.running, command.generation == context.generation,
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.stopGeneration == expectedStopGeneration,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
                  scope.launch.phase == .opening, scope.launch.dispatchedUptime == nil else {
                throw PilotError.message("微信打开请求已派发或授权已失效，不会重放。");
            }
            scope.launch.dispatchedUptime = ProcessInfo.processInfo.systemUptime
            command.messageScope = scope
        }
        guard updated else { throw PilotError.message("打开微信的会话已变化。") }
    }
    /// Only the runtime's fresh target-app evidence gate may call this method.
    /// It records the actual evidence frame, never a guessed HID position or API success.
    @discardableResult
    func confirmMessageAppVisible(context: MessageDispatchContext, expectedStopGeneration: String?,
                                  capturedAt: Date, capturedUptime: Double?) throws -> Bool {
        var established = false
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.running, command.generation == context.generation,
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.stopGeneration == expectedStopGeneration,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
                  [.pending, .opening, .opened].contains(scope.launch.phase), !context.frameID.isEmpty,
                  capturedAt >= command.createdAt, capturedAt <= Date(), Date().timeIntervalSince(capturedAt) < 20,
                  let capturedUptime, capturedUptime.isFinite,
                  capturedUptime <= ProcessInfo.processInfo.systemUptime,
                  ProcessInfo.processInfo.systemUptime - capturedUptime < 20,
                  scope.launch.requestedUptime.map({ capturedUptime > $0 }) ?? true else {
                throw PilotError.message("确认微信画面的会话、停止状态或截图已失效。");
            }
            if scope.launch.isVisuallyEstablished { return } // Duplicate evidence cannot move the barrier.
            scope.launch.phase = .opened
            scope.launch.visuallyEstablishedAt = capturedAt
            scope.launch.visuallyEstablishedUptime = capturedUptime
            scope.launch.visuallyEstablishedFrameID = context.frameID
            scope.launch.proofSource = "visual_target_app"
            scope.launch.failure = nil
            command.messageScope = scope
            established = true
        }
        guard updated else { throw PilotError.message("确认微信画面的会话已变化。") }
        return established
    }
    @discardableResult
    func finishMessageLaunch(context: MessageDispatchContext, expectedStopGeneration: String?, opened: Bool, failure: String? = nil) throws -> Bool {
        var accepted = false
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard currentUploadConsentUnlocked(), command.running, command.generation == context.generation,
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.stopGeneration == expectedStopGeneration,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task) else {
                throw PilotError.message("打开微信的回调已失效。");
            }
            if scope.launch.isVisuallyEstablished {
                // Keep successful system acknowledgement as diagnostics only.
                // It cannot change visual timestamps, source, phase or task UI.
                if opened {
                    scope.launch.acknowledgedAt = Date()
                    scope.launch.acknowledgedUptime = ProcessInfo.processInfo.systemUptime
                    command.messageScope = scope
                }
                return
            }
            guard scope.launch.phase == .opening else { throw PilotError.message("打开微信的回调已失效。") }
            scope.launch.phase = opened ? .opened : .failed
            scope.launch.failure = opened ? nil : (failure ?? "系统未接受微信打开请求，本轮已停止；原计划已保留，可重新检查并继续。")
            if opened {
                scope.launch.acknowledgedAt = Date()
                scope.launch.acknowledgedUptime = ProcessInfo.processInfo.systemUptime
                scope.launch.proofSource = "system_open_receipt"
            }
            command.messageScope = scope
            accepted = true
        }
        guard updated else { throw PilotError.message("打开微信的会话已变化。") }
        return accepted
    }
    func reserveMessageAction(purpose: String, context: MessageDispatchContext) throws {
        let expectedStopGeneration = command?.messageScope?.stopGeneration
        let updated = try updateCommand(sessionID: context.sessionID, expectedStopGeneration: expectedStopGeneration, enforceStopGeneration: true) { command in
            guard command.running, command.generation == context.generation, command.pendingClarification == nil,
                  var scope = command.messageScope, scope.launch.isVisuallyEstablished,
                  purpose != "message_paste" || scope.clipboardIsReady,
                  scope.reserve(purpose: purpose, context: context, task: command.task) else {
                throw PilotError.message("消息动作授权已变化或已使用；不会重发。")
            }
            command.messageScope = scope
        }
        guard updated else { throw PilotError.message("消息会话已变化；不会执行。") }
    }
    func verifyMessage(context: MessageDispatchContext, capturedAt: Date) throws {
        let updated = try updateCommand(sessionID: context.sessionID) { command in
            guard command.running, command.generation == context.generation, command.pendingClarification == nil,
                  var scope = command.messageScope, scope.id == context.scopeID,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
                  scope.sendAttempted, !scope.verified, scope.sendFrameID != context.frameID,
                  let attemptedAt = scope.sendAttemptedAt, capturedAt > attemptedAt else {
                throw PilotError.message("发送后的新画面核验已失效；不会重发。")
            }
            scope.verified = true; command.messageScope = scope
        }
        guard updated else { throw PilotError.message("消息核验会话已变化。") }
    }
    func readFailure<T: Decodable>(_ name: String, as type: T.Type) -> String? {
        queue.sync {
            guard let directory else { return "App Group 不可用，请检查签名配置" }
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do { _ = try JSONDecoder().decode(type, from: Data(contentsOf: url)); return nil }
            catch { return "\(name)无法读取或格式损坏；原文件未删除，请先备份应用数据再恢复设置。" }
        }
    }
    // Recovery never overwrites the only copy of a damaged file.
    func preserveSettingsForRecovery() throws {
        try queue.sync {
            try withFileLock {
                guard let directory else { throw PilotError.message("App Group 不可用") }
                let suffix = UUID().uuidString
                for name in ["configuration.json", "workspace.json"] {
                    let source = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name + ".recovery-" + suffix))
                    }
                }
            }
        }
    }
    func remove(_ name: String) {
        queue.sync {
            guard let url = directory?.appendingPathComponent(name) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
    var configuration: PilotConfiguration { read("configuration.json", as: PilotConfiguration.self) ?? PilotConfiguration() }
    var command: SessionCommand? { read("command.json", as: SessionCommand.self) }
    var status: PilotStatus { read("status.json", as: PilotStatus.self) ?? .idle }
    var logs: [LogEntry] { read("logs.json", as: [LogEntry].self) ?? [] }
    // Extension is sole writer during broadcasting; the app only reads this file.
    func log(_ message: String, sessionID: String? = nil) {
        var entries = logs
        entries.append(LogEntry(message: message, sessionID: sessionID))
        try? write(Array(entries.suffix(100)), to: "logs.json")
    }
}

enum SecretStore {
    private static func query(_ account: String) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PilotKeychainGroup") as? String, !group.contains("$(") else {
            throw PilotError.message("Keychain access group 未正确展开，请检查签名。")
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "HIDPilot", kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group]
    }
    static func save(_ value: String, account: String) throws {
        let base = try query(account)
        if value.isEmpty {
            let result = SecItemDelete(base as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw PilotError.message("Keychain 删除失败：\(result)") }; return
        }
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            let result = SecItemAdd(base.merging(values) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw PilotError.message("Keychain 保存失败：\(result)") }; return
        }
        guard update == errSecSuccess else { throw PilotError.message("Keychain 更新失败：\(update)") }
    }
    static func load(_ account: String) throws -> String {
        var value = try query(account)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(value as CFDictionary, &item)
        guard result == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PilotError.message("缺少共享凭据（\(account)），或设备尚未首次解锁。状态：\(result)")
        }
        return text
    }
}
