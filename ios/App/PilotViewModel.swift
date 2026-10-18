import SwiftUI
import Combine
import ActivityKit
import UIKit

@MainActor
final class PilotViewModel: ObservableObject {
    @Published var automaticCalibration = AutomaticCalibrationState()
    var calibrationObservation: CalibrationObservation?
    var calibrationCanvasContext: PointerCalibrationContext?
    var calibrationCanvasWidth: Double = 0
    var calibrationCanvasHeight: Double = 0
    @Published var calibrationFlow = PointerCalibrationState()
    var calibrationConfiguration: PilotConfiguration?
    var calibrationTimeoutTask: Task<Void, Never>?
    var calibrationRequestInFlight = false
    @Published var taskFlow = TaskPlanningState()
    var planningTask: Task<String, Error>?
    @Published var configuration = SharedStore.shared.configuration
    @Published var task = ""
    @Published var workspace = SharedStore.shared.read("workspace.json", as: WorkspaceState.self) ?? WorkspaceState()
    @Published var selectedTaskID: String?
    @Published var lastDeviceStatus: DeviceStatus?
    // Diagnostic-only cache. Never consulted by freshness, authorization or task execution.
    private(set) var lastDiagnosticSnapshot: [String: Any]?
    private(set) var diagnosticCapturedAt: Date?
    private(set) var diagnosticDeviceURL: String?
    @Published var deviceSummary = "尚未检查局域网 / BLE"
    @Published var apiKey = ""
    @Published var deviceToken = ""
    @Published var status = SharedStore.shared.status
    @Published var logs = SharedStore.shared.logs
    @Published var notice = "开发源码版本：iOS实际构建与真机行为仍需验证"
    @Published var prepared = false
    @Published var sending = false
    @Published var preparing = false
    @Published var stopping = false
    @Published var probing = false
    @Published var probeState = DeviceProbeState.idle
    @Published var pairingState = DevicePairingState.idle
    @Published var controllingDevice = false
    @Published var deviceStatusCheckedAt: Date?
    private var preparingRequestInFlight = false
    private var refreshingDeviceStatus = false
    private var deviceProbeTask: Task<DeviceStatus, Error>?
    private var deviceProbeID = UUID()
    private var pairingTask: Task<Void, Never>?
    private var pairingCancelRequested = false
    private let pairingWindowDuration: TimeInterval = 30
    private let pairingPollNanoseconds: UInt64 = 1_000_000_000
    private var deviceControlID = UUID()
    private var deviceObservationID = UUID()
    private var observedDeviceURL: String?
    private var lastDevicePoll = Date.distantPast
    var deviceStatusIsFresh: Bool {
        guard let checkedAt = deviceStatusCheckedAt, observedDeviceURL == configuration.deviceURL else { return false }
        return Date().timeIntervalSince(checkedAt) < 10 && lastDeviceStatus != nil
    }
    var softwareControlAvailable: Bool { deviceStatusIsFresh && lastDeviceStatus?.supportsSoftwareControl == true }
    @Published var storageWarning: String? = nil
    private var preparationID = UUID()
    var isSessionActive: Bool { calibrationFlow.isBusy || preparingRequestInFlight || preparing || stopping || sending || controllingDevice || SharedStore.shared.command?.running == true }
    private var ticker: AnyCancellable?

    init() {
        storageWarning = SharedStore.shared.readFailure("workspace.json", as: WorkspaceState.self)
            ?? SharedStore.shared.readFailure("configuration.json", as: PilotConfiguration.self)
        initializeWorkspace()
        if let storageWarning { notice = storageWarning }
        prepared = SharedStore.shared.command?.running == true
        if let command = SharedStore.shared.command {
            if task.isEmpty { task = command.task }
        }
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        if configuration.automaticCalibrationProfile != nil, configuration.relativeModeConfirmed {
            do { try validateAutomaticCalibrationContext() }
            catch {
                let reason = error.localizedDescription
                notice = reason
                if isSessionActive && !stopping { Task { await stop(); notice = reason + " 已停止当前会话。" } }
            }
        }
        // Poll only an explicitly checked device, in the foreground. This never arms it.
        if !deviceStatusIsFresh, lastDeviceStatus != nil {
            lastDeviceStatus = nil
            deviceSummary = "设备状态已过期，请重新检查；不能据此确认 BLE 或控制授权。"
        }
        if UIApplication.shared.applicationState == .active, observedDeviceURL == configuration.deviceURL,
           !probing, !refreshingDeviceStatus, !controllingDevice, !stopping, !preparing, !sending, Date().timeIntervalSince(lastDevicePoll) >= 3 {
            lastDevicePoll = Date()
            Task { await refreshDeviceStatus() }
        }
        status = SharedStore.shared.status
        logs = SharedStore.shared.logs
        syncTaskStatus()
        syncPlanningState()
        if !preparing { prepared = SharedStore.shared.command?.running == true }
        if status.phase == "停止", let command = SharedStore.shared.command, command.id == status.sessionID, command.running {
            try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
            prepared = false
        }
        PilotActivityManager.shared.publish(status, running: SharedStore.shared.command?.running == true)
    }
    @discardableResult
    func save() -> Bool {
        guard storageWarning == nil else { notice = storageWarning!; return false }
        guard !isSessionActive else { notice = "修改配置或密钥前请先停止会话。"; return false }
        do {
            configuration.deviceURL = try AddressPolicy.device(configuration.deviceURL).absoluteString
            try configuration.validate()
            configuration.maxSteps = min(50, max(1, configuration.maxSteps))
            if !apiKey.isEmpty { try SecretStore.save(apiKey, account: configuration.apiAccount); apiKey = "" }
            if !deviceToken.isEmpty { try SecretStore.save(deviceToken, account: configuration.deviceAccount); deviceToken = "" }
            try SharedStore.shared.write(configuration, to: "configuration.json")
            if let index = workspace.profiles.firstIndex(where: { $0.id == workspace.selectedProfileID }) {
                workspace.profiles[index].configuration = configuration
                guard persistWorkspace() else {
                    notice = "连接设置已写入，但档案保存失败。请重试保存；不要把本次视为完整保存。"
                    return false
                }
            }
            notice = "设置已保存。密钥仅存共享 Keychain，并绑定当前端点；留空不覆盖。"
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    func deleteSecrets() {
        guard !isSessionActive else { notice = "删除凭据前请先停止会话。"; return }
        do {
            try SecretStore.save("", account: configuration.apiAccount); try SecretStore.save("", account: configuration.deviceAccount)
            notice = "API Key 和设备 Token 已删除"
        } catch { notice = error.localizedDescription }
    }
    private func acceptDeviceStatus(_ value: DeviceStatus, from checkedConfiguration: PilotConfiguration) {
        guard configuration.deviceURL == checkedConfiguration.deviceURL else { return }
        lastDiagnosticSnapshot = value.redactedDiagnosticFields
        diagnosticCapturedAt = Date()
        diagnosticDeviceURL = checkedConfiguration.deviceURL
        observedDeviceURL = checkedConfiguration.deviceURL
        deviceStatusCheckedAt = Date()
        lastDeviceStatus = value
        deviceSummary = value.hid_connected ? "设备已连接" : "局域网已响应 · 蓝牙尚未连接"
    }
    func refreshDeviceStatus() async {
        guard !probing, !refreshingDeviceStatus, !controllingDevice, !stopping, !preparingRequestInFlight, !sending else { return }
        refreshingDeviceStatus = true
        let observationID = UUID()
        deviceObservationID = observationID
        defer { refreshingDeviceStatus = false }
        let checkedConfiguration = configuration
        do {
            let value = try await HardwareClient(configuration: checkedConfiguration).status()
            guard deviceObservationID == observationID else { return }
            acceptDeviceStatus(value, from: checkedConfiguration)
        } catch {
            guard deviceObservationID == observationID, configuration.deviceURL == checkedConfiguration.deviceURL else { return }
            lastDeviceStatus = nil; deviceStatusCheckedAt = nil
            deviceSummary = "设备不可达或检查失败，BLE / 控制状态未知；必要时拔掉 USB 电源。"
        }
    }
    func cancelProbe() {
        guard probing else { return }
        deviceProbeID = UUID()
        deviceObservationID = UUID()
        deviceProbeTask?.cancel()
        deviceProbeTask = nil
        probing = false
        probeState = .init(phase: .failure, message: "检查已取消，可以重试。", failure: .cancelled)
    }
    // Hardware onboarding does not validate or save an unfinished AI/model form.
    private func saveDeviceConnection() -> Bool {
        guard storageWarning == nil else { notice = storageWarning!; return false }
        guard !isSessionActive else { notice = "请先停止当前会话。"; return false }
        do {
            let address = try AddressPolicy.device(configuration.deviceURL).absoluteString
            guard address.count <= 255 else { throw PilotError.message("设备地址过长。") }
            var saved = SharedStore.shared.configuration
            let changedDevice = saved.deviceURL != address
            saved.deviceURL = address
            if changedDevice { saved.relativeModeConfirmed = false }
            // Only explicitly entered tokens are saved, bound to this exact validated endpoint.
            // No automatic credential migration or copying to a different host.
            if !deviceToken.isEmpty { try SecretStore.save(deviceToken, account: saved.deviceAccount) }
            try SharedStore.shared.write(saved, to: "configuration.json")
            if let index = workspace.profiles.firstIndex(where: { $0.id == workspace.selectedProfileID }) {
                if workspace.profiles[index].configuration.deviceURL != address {
                    workspace.profiles[index].configuration.relativeModeConfirmed = false
                }
                workspace.profiles[index].configuration.deviceURL = address
                guard persistWorkspace() else { return false }
            }
            configuration.deviceURL = address
            if changedDevice { configuration.relativeModeConfirmed = false }
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    func probe() async {
        guard !probing else { return } // Coalesce repeated taps; do not queue network work.
        guard !isSessionActive else {
            probeState = .init(phase: .failure, message: "请先停止当前会话，再保存并检查设备。")
            return
        }
        let probeID = UUID()
        deviceProbeID = probeID
        let stopGeneration = SharedStore.shared.stopGeneration
        probing = true
        probeState = .init(phase: .saving, message: "正在保存连接设置…")
        defer {
            if deviceProbeID == probeID { probing = false; deviceProbeTask = nil }
        }
        // Yield before synchronous Keychain/App Group work so the spinner can appear.
        await Task.yield()
        guard deviceProbeID == probeID else { return }
        guard SharedStore.shared.stopGeneration == stopGeneration, !Task.isCancelled else {
            probeState = .init(phase: .failure, message: "检查已取消，可以重试。", failure: .cancelled)
            return
        }
        guard saveDeviceConnection() else {
            probeState = .init(phase: .failure, message: "保存失败：" + notice, failure: .save)
            return
        }
        let checkedConfiguration = configuration
        let checkedToken = deviceToken
        let observationID = UUID()
        deviceObservationID = observationID // Supersede any older background status read.
        lastDeviceStatus = nil
        deviceStatusCheckedAt = nil
        observedDeviceURL = nil
        probeState = .init(phase: .checking, message: "正在通过 Wi-Fi 检查设备（最长15秒）…读取设备报告的 BLE 状态，不扫描蓝牙。")
        do {
            let request = Task { try await HardwareClient(configuration: checkedConfiguration).status() }
            deviceProbeTask = request
            let value = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: { request.cancel() }
            guard deviceProbeID == probeID else { return }
            guard deviceObservationID == observationID,
                  SharedStore.shared.stopGeneration == stopGeneration,
                  configuration.deviceURL == checkedConfiguration.deviceURL else {
                probeState = .init(phase: .failure, message: "检查期间配置或停止状态已变化，请重试。", failure: .cancelled)
                return
            }
            acceptDeviceStatus(value, from: checkedConfiguration)
            if deviceToken == checkedToken { deviceToken = "" }
            probeState = .init(phase: .success, message: deviceSummary)
            notice = deviceSummary
        } catch {
            guard deviceProbeID == probeID else { return }
            guard deviceObservationID == observationID,
                  SharedStore.shared.stopGeneration == stopGeneration,
                  configuration.deviceURL == checkedConfiguration.deviceURL else {
                probeState = .init(phase: .failure, message: "检查已被停止操作取消。", failure: .cancelled)
                return
            }
            let failure = DeviceProbeFailure.classify(error)
            deviceSummary = failure.localizedDescription
            probeState = .init(phase: .failure, message: deviceSummary, failure: failure)
            notice = deviceSummary
        }
    }
    func startPairing() async {
        guard pairingTask == nil else { return }
        guard !isSessionActive, !probing else {
            pairingState = .init(phase: .error, message: "请先结束当前检查或会话，再开始配对。")
            return
        }
        pairingState = .init(phase: .opening, message: "正在保存并请求设备打开配对窗口…")
        guard saveDeviceConnection() else {
            pairingState = .init(phase: .error, message: "保存失败：" + notice)
            return
        }
        controllingDevice = true
        pairingCancelRequested = false
        let operationID = UUID()
        deviceControlID = operationID
        deviceObservationID = UUID()
        let checked = configuration
        let generation = SharedStore.shared.stopGeneration
        let operation = Task { await self.runPairing(configuration: checked, operationID: operationID, stopGeneration: generation) }
        pairingTask = operation
        await operation.value
        pairingTask = nil
        controllingDevice = false
    }
    func cancelPairing() async {
        guard let operation = pairingTask else { return }
        pairingCancelRequested = true
        pairingState = .init(phase: .cancelled, message: "正在取消配对并确认窗口关闭…")
        // Drain a pending pair reply to learn its epoch before cleanup. Do not unlock a
        // new local control session while an older cancellation could still send STOP.
        await operation.value
    }
    private func runPairing(configuration checked: PilotConfiguration, operationID: UUID, stopGeneration: String?) async {
        let client = HardwareClient(configuration: checked)
        var receipt: DevicePairingReceipt?
        func ownsOperation() -> Bool {
            deviceControlID == operationID && SharedStore.shared.stopGeneration == stopGeneration && configuration.deviceURL == checked.deviceURL
        }
        do {
            let current = try await client.status()
            guard ownsOperation() else { pairingState = .init(phase: .cancelled, message: "设备或停止状态已变化，配对已取消。"); return }
            if pairingCancelRequested { pairingState = .init(phase: .cancelled, message: "配对已取消，尚未打开窗口。"); return }
            acceptDeviceStatus(current, from: checked)
            guard current.supportsSoftwareControl else { throw PilotError.message("此固件需要硬件按钮打开配对窗口。") }
            guard !current.armed else { throw PilotError.message("设备正在控制中，请先停止再配对。") }
            if current.hid_connected {
                acceptDeviceStatus(current, from: checked)
                pairingState = .init(phase: .connected, message: "设备已连接，可以返回聊天准备任务。")
                return
            }
            let openedAt = Date() // Conservative: the firmware timer starts before its reply arrives.
            receipt = try await client.beginPairing(expected: current)
            let deadline = openedAt.addingTimeInterval(pairingWindowDuration)
            while true {
                guard ownsOperation() else { pairingState = .init(phase: .cancelled, message: "停止或设备状态已变化，已结束配对检查。"); return }
                if pairingCancelRequested {
                    let closed = try await client.closePairingWindow(expected: receipt!, stillOwned: ownsOperation)
                    let message: String
                    switch closed {
                    case .closed: message = "配对已取消，设备窗口已关闭。"
                    case .unsupported: message = "配对检查已取消。此固件不支持单独关闭窗口，将在打开后30秒自动到期；不会停止其它控制会话。"
                    case .changed: message = "配对检查已取消；设备状态已变化，未干扰新会话。"
                    }
                    pairingState = .init(phase: .cancelled, message: message)
                    return
                }
                pairingState = .init(phase: .waiting, message: "配对窗口已打开，正在等待加密连接。请在系统设置→蓝牙选择 SightLatch，随后返回此处。", deadline: deadline)
                let observed = try await client.status()
                guard ownsOperation() else { pairingState = .init(phase: .cancelled, message: "配对检查已取消。"); return }
                if pairingCancelRequested { continue }
                guard observed.boot_id == receipt!.boot_id, observed.control_epoch == receipt!.control_epoch, !observed.armed else {
                    pairingState = .init(phase: .error, message: "设备已重启或控制状态已变化，已停止配对检查；不会干扰新会话。")
                    return
                }
                // Firmware defines hid_connected as connected && encrypted (16-byte key).
                if observed.hid_connected {
                    acceptDeviceStatus(observed, from: checked)
                    pairingState = .init(phase: .connected, message: "设备已连接，可以返回聊天准备任务。")
                    return
                }
                if observed.pairing_open == false {
                    pairingState = .init(phase: .expired, message: "设备配对窗口已关闭，尚未确认加密连接。可重试。")
                    return
                }
                guard Date() < deadline else {
                    pairingState = .init(phase: .expired, message: "本次30秒配对等待已结束，未确认连接。请检查系统蓝牙状态后重试。")
                    return
                }
                try await Task.sleep(nanoseconds: pairingPollNanoseconds)
            }
        } catch {
            guard ownsOperation() else { pairingState = .init(phase: .cancelled, message: "配对检查已被停止操作取消。"); return }
            let message = (error as? PilotError)?.localizedDescription ?? DeviceProbeFailure.classify(error).localizedDescription
            pairingState = .init(phase: pairingCancelRequested ? .cancelled : .error,
                message: message + (receipt == nil ? " 若请求已送达但回包丢失，设备窗口会在30秒内自动关闭。" : " 无法确认窗口已关闭；请等待30秒自动到期后重试。"))
        }
    }
    // Compatibility entry point: pairing is supported; task ARM requires a fresh plan permit.
    func requestDeviceControl(pairing: Bool) async {
        guard pairing else { notice = "请先在聊天发送目标，阅读计划并明确允许本次控制。"; return }
        await startPairing()
    }
    func prepare() async {
        guard !isSessionActive, !probing, save() else { return }
        guard taskFlow.consumePermission(goal: task.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            notice = "请先发送目标，阅读新计划并明确允许；旧授权不能再次使用。"; return
        }
        let preparedGoal = taskFlow.goal
        SharedStore.shared.remove("frame.json")
        SharedStore.shared.remove("lease.json")
        preparingRequestInFlight = true
        preparing = true
        deviceObservationID = UUID()
        let token = UUID()
        preparationID = token
        defer {
            preparingRequestInFlight = false
            if preparationID == token { preparing = false }
        }
        var createdSessionID: String?
        var requestedSoftwareArm = false
        let sessionClient = HardwareClient(configuration: configuration)
        let expectedStopGeneration = SharedStore.shared.stopGeneration
        do {
            try validateAutomaticCalibrationContext()
            guard configuration.uploadConsent, configuration.relativeModeConfirmed, !configuration.model.isEmpty,
                  !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PilotError.message("请填写任务、视觉模型，完成指针校准，并明确同意上传屏幕。")
            }
            if configuration.provider == "openai", configuration.gatewayVisionConfirmed != true {
                throw PilotError.message("请先确认兼容端点和所选模型支持图片输入，且你获准用于该自动操作场景。")
            }
            if configuration.provider == "chatgpt-plan" {
                guard configuration.chatGPTPlanConsent == true else { throw PilotError.message("请先在设置中同意本次屏幕任务使用 ChatGPT 套餐。") }
                _ = try await ChatGPTOAuth.shared.accessToken()
            } else {
                _ = try SecretStore.load(configuration.apiAccount)
            }
            var device = try await sessionClient.status()
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else { return }
            if let profile = configuration.automaticCalibrationProfile, profile.hardwareBootID != device.boot_id {
                configuration.relativeModeConfirmed = false
                throw PilotError.message("硬件已重启或更换，请重新测量指针校准。")
            }
            // prepare() consumes the explicit permission for this specific planned goal.
            // Never renew an existing authorization or arm from observation/resume.
            if device.supportsSoftwareControl, !device.armed {
                guard device.hid_connected else { throw PilotError.message("请先点开始蓝牙配对，并在 iPhone 系统设置完成配对。") }
                requestedSoftwareArm = true
                device = try await sessionClient.armSoftwareControl(expected: device)
                guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else {
                    try await sessionClient.stopAndVerify()
                    return
                }
            }
            guard device.control_lease_mode != "calibration" else {
                throw PilotError.message("请先结束短时校准并确认停止，再重新规划和允许任务控制。")
            }
            guard device.armed, device.hid_connected else { throw PilotError.message("请先在系统配对 BLE HID，再在 App 允许控制（软件模式）或按硬件 ARM。") }
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else { return }
            let command = SessionCommand(task: preparedGoal, running: true)
            try SharedStore.shared.startCommand(command, expectedStopGeneration: expectedStopGeneration)
            createdSessionID = command.id
            if configuration.continuedProcessingEnabled == true {
                do { try await ContinuedSession.shared.start(command: command, configuration: configuration) }
                catch {
                    try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                    throw error
                }
                guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else {
                    ContinuedSession.shared.cancel()
                    try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                    try await sessionClient.stopAndVerify()
                    return
                }
            }
            try SharedStore.shared.write(PilotStatus(phase: "待广播", detail: "会话已准备，请主动开始系统广播", steps: 0, sessionID: command.id), to: "status.json")
            status = SharedStore.shared.status
            try recordSession(command)
            acceptDeviceStatus(device, from: configuration)
            prepared = true
            notice = "会话已准备。请点系统广播按钮，选择 SightLatch Broadcast。广播会持续上传屏幕直到你停止。"
            await PilotActivityManager.shared.start(sessionID: command.id)
        } catch {
            var hardwareStopUnconfirmed = false
            deviceObservationID = UUID()
            lastDeviceStatus = nil; deviceStatusCheckedAt = nil
            deviceSummary = "本次接管未开始，设备状态需重新检查"
            if requestedSoftwareArm {
                do { try await sessionClient.stopAndVerify() }
                catch { hardwareStopUnconfirmed = true; notice = "开始接管失败，且未确认撤销设备授权。请立即拔掉 USB 电源并结束广播。" }
                deviceObservationID = UUID()
                lastDeviceStatus = nil; deviceStatusCheckedAt = nil
                deviceSummary = hardwareStopUnconfirmed ? "未确认停止，请拔掉 USB 电源" : "接管未开始；已请求撤销授权，请重新检查状态"
            }
            if let createdSessionID, let command = SharedStore.shared.command, command.id == createdSessionID {
                try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                ContinuedSession.shared.cancel()
                await HardwareClient(configuration: SharedStore.shared.configuration).stop()
            }
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else { return }
            prepared = SharedStore.shared.command?.running == true
            if !hardwareStopUnconfirmed { notice = error.localizedDescription }
        }
    }
    func stop() async {
        if automaticCalibration.isBusy { automaticCalibration.id = UUID(); automaticCalibration.phase = .error; automaticCalibration.detail = "校准已取消，未保存新的结果。" }
        if calibrationFlow.isBusy { await endPointerCalibration() }
        let onlyPlanning = !isSessionActive && [.planning, .awaitingPermission].contains(taskFlow.phase)
        planningTask?.cancel(); planningTask = nil; taskFlow.cancel()
        if onlyPlanning { notice = "已取消规划和待授权计划；未开始控制。"; return }
        guard !stopping else { return }
        stopping = true
        let hadControlRequestInFlight = preparingRequestInFlight || controllingDevice
        deviceControlID = UUID()
        deviceObservationID = UUID()
        lastDeviceStatus = nil
        deviceStatusCheckedAt = nil
        deviceSummary = "正在请求停止控制，尚未确认设备状态"
        defer { stopping = false }
        preparationID = UUID()
        preparing = false
        ContinuedSession.shared.cancel()
        let store = SharedStore.shared
        let sessionID = store.command?.id ?? status.sessionID
        var localError: String?
        do { try store.invalidatePendingStarts() }
        catch { localError = error.localizedDescription }
        if let command = store.command {
            do { try store.updateCommand(sessionID: command.id) { $0.running = false } }
            catch { localError = error.localizedDescription }
        }
        store.remove("lease.json")
        store.remove("frame.json")
        // Do not hide a failed local revocation even when the hardware STOP succeeds.
        var hardwareConfirmed = false
        do { try await HardwareClient(configuration: store.configuration).stopAndVerify(); hardwareConfirmed = true }
        catch { /* Final message below distinguishes uncertain delivery. */ }
        if hadControlRequestInFlight {
            // Send STOP immediately above, then drain older ARM/PAIR requests and
            // their compensating STOP before allowing a new Start or claiming success.
            hardwareConfirmed = false
            while preparingRequestInFlight || controllingDevice {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { break }
            }
            if !preparingRequestInFlight && !controllingDevice {
                do { try await HardwareClient(configuration: store.configuration).stopAndVerify(); hardwareConfirmed = true }
                catch { hardwareConfirmed = false }
            }
        }
        deviceSummary = hardwareConfirmed ? "设备已确认停止控制；后续操作前需重新授权" : "未确认设备停止；请按物理 STOP 或拔掉 USB 电源"
        prepared = store.command?.running == true
        if let localError {
            notice = "本地停止写入失败：\(localError)。请立即按物理 STOP 或拔掉 USB 电源，并结束系统广播。"
        } else {
            notice = hardwareConfirmed
                ? "硬件已确认解除ARM且无在途动作。本地会话已停止；请从系统结束广播。"
                : "本地会话已停止，但未确认硬件停止送达。请按物理 STOP 或拔掉 USB 电源，并从系统结束广播核实。"
            let stoppedStatus = PilotStatus(phase: "停止", detail: notice, steps: status.steps, sessionID: sessionID)
            do { try store.write(stoppedStatus, to: "status.json"); status = stoppedStatus }
            catch { notice += " 状态记录写入失败。" }
            syncTaskStatus()
        syncPlanningState()
        }
        await PilotActivityManager.shared.finish(sessionID: sessionID,
            phase: hardwareConfirmed && localError == nil ? "硬件已解除ARM" : "请核实硬件停止", steps: status.steps)
    }
    func recoverDamagedSettings() async {
        guard storageWarning != nil, !stopping else { return }
        await stop()
        guard SharedStore.shared.command?.running != true else { notice = "无法撤销旧会话，请先结束系统广播再重试恢复。"; return }
        do {
            let store = SharedStore.shared
            try store.preserveSettingsForRecovery()
            let cleanConfiguration = PilotConfiguration()
            let cleanWorkspace = WorkspaceState()
            try store.write(cleanConfiguration, to: "configuration.json")
            try store.write(cleanWorkspace, to: "workspace.json")
            configuration = cleanConfiguration; workspace = cleanWorkspace
            storageWarning = nil; selectedTaskID = nil; task = ""
            apiKey = ""; deviceToken = ""; lastDeviceStatus = nil
            initializeWorkspace()
            notice = "旧配置与任务文件已在本机保留恢复副本，当前工作区已重置。Keychain凭据未删除；请重新配置、校准与同意上传。"
        } catch { notice = "恢复失败，旧文件未主动删除：\(error.localizedDescription)" }
    }
    func stopAndRevokeConsent() async {
        var saved = SharedStore.shared.configuration
        saved.uploadConsent = false
        var consentError: String?
        do { try SharedStore.shared.write(saved, to: "configuration.json"); configuration = saved }
        catch { consentError = error.localizedDescription }
        await stop()
        if let consentError { notice += " 上传许可写入失败：\(consentError)。请立即结束系统广播。" }
        else { notice += " 已撤回截图上传许可。" }
    }
    func resumeAfterManual() {
        guard !stopping, configuration.continuedProcessingEnabled != true, status.phase == "暂停",
              let command = SharedStore.shared.command, command.running, command.id == status.sessionID else { notice = "请重新准备会话"; return }
        do {
            let updated = try SharedStore.shared.updateCommand(sessionID: command.id) { current in
                guard current.running, current.generation == command.generation else { throw PilotError.message("会话已停止或发生变化，请重新检查状态") }
                current.generation += 1
            }
            guard updated else { throw PilotError.message("会话已变化，请重新准备") }
            notice = "请先停止会话，再在 App 允许控制或按硬件 ARM，然后重新准备会话。旧动作已丢弃；系统只会根据之后的新帧重新规划。"
        } catch { notice = error.localizedDescription }
    }
    func manual(_ kind: ActionProposal.Kind, dx: Int? = nil, dy: Int? = nil, wheel: Int? = nil, key: String? = nil, text: String? = nil) async {
        guard kind == .move, let dx, let dy, wheel == nil, key == nil, text == nil else {
            notice = "校准仅允许显式的单轴微移，不允许点击、滚动、按键或输入。"; return
        }
        await moveCalibrationPointer(dx: dx, dy: dy)
    }
}
