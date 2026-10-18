import SwiftUI
import Combine
import ActivityKit
import UIKit

@MainActor
final class PilotViewModel: ObservableObject {
    @Published var configuration = SharedStore.shared.configuration
    @Published var task = ""
    @Published var workspace = SharedStore.shared.read("workspace.json", as: WorkspaceState.self) ?? WorkspaceState()
    @Published var selectedTaskID: String?
    @Published var lastDeviceStatus: DeviceStatus?
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
    @Published var controllingDevice = false
    @Published var deviceStatusCheckedAt: Date?
    private var preparingRequestInFlight = false
    private var refreshingDeviceStatus = false
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
    var isSessionActive: Bool { preparingRequestInFlight || preparing || stopping || sending || controllingDevice || SharedStore.shared.command?.running == true }
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
        observedDeviceURL = checkedConfiguration.deviceURL
        deviceStatusCheckedAt = Date()
        lastDeviceStatus = value
        let authorization = value.armed ? "已允许控制（最多5分钟）" : (value.supportsSoftwareControl ? "尚未允许控制" : "未 ARM（请按硬件按钮）")
        deviceSummary = "局域网已响应 · BLE \(value.hid_connected ? "已连接" : "未连接") · \(authorization)"
    }
    func refreshDeviceStatus() async {
        guard !refreshingDeviceStatus, !controllingDevice, !stopping, !preparingRequestInFlight, !sending else { return }
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
    func probe() async {
        guard !probing, !refreshingDeviceStatus, save() else { return }
        probing = true
        defer { probing = false }
        observedDeviceURL = configuration.deviceURL
        await refreshDeviceStatus()
        notice = deviceSummary
    }
    // Only the user's explicit device buttons call this. Polling and resume never ARM.
    func requestDeviceControl(pairing: Bool) async {
        guard !isSessionActive, !probing, save() else { return }
        controllingDevice = true
        let operationID = UUID()
        deviceControlID = operationID
        deviceObservationID = UUID()
        let checkedConfiguration = configuration
        let expectedStopGeneration = SharedStore.shared.stopGeneration
        let client = HardwareClient(configuration: checkedConfiguration)
        var didSendControlRequest = false
        defer { controllingDevice = false }
        do {
            let current = try await client.status()
            guard deviceControlID == operationID, SharedStore.shared.stopGeneration == expectedStopGeneration else { return }
            acceptDeviceStatus(current, from: checkedConfiguration)
            guard current.supportsSoftwareControl else {
                throw PilotError.message("此固件不支持 App 配对 / 授权；请使用硬件 ARM / STOP 按钮。")
            }
            if pairing {
                guard !current.hid_connected, !current.armed else { throw PilotError.message("设备已连接或已授权；无需重新打开配对窗口。") }
                didSendControlRequest = true
                try await client.beginPairing(expected: current)
                guard deviceControlID == operationID, SharedStore.shared.stopGeneration == expectedStopGeneration else {
                    try await client.stopAndVerify()
                    return
                }
                notice = "配对窗口已打开30秒。请在 iPhone 系统设置中配对 SightLatch；这尚未允许控制。"
            } else {
                guard current.hid_connected else { throw PilotError.message("请先在 iPhone 系统设置完成加密 BLE 配对。") }
                guard !current.armed else { notice = "设备已经获得授权；不会续期。需要新授权时先停止控制。"; return }
                didSendControlRequest = true
                let armed = try await client.armSoftwareControl(expected: current)
                guard deviceControlID == operationID, SharedStore.shared.stopGeneration == expectedStopGeneration else {
                    try await client.stopAndVerify()
                    return
                }
                acceptDeviceStatus(armed, from: checkedConfiguration)
                notice = "设备已允许控制，最多5分钟。断连或停止会撤销，不自动续期；请留在安全测试页面。"
            }
        } catch {
            // A lost HTTP reply may hide a successful ARM. Fail closed by issuing STOP.
            if didSendControlRequest {
                do { try await client.stopAndVerify() }
                catch { notice = "控制请求结果不确定，且未确认停止。请立即拔掉设备 USB 电源。"; lastDeviceStatus = nil; deviceStatusCheckedAt = nil; deviceSummary = "设备控制状态未知；未确认停止，请拔掉 USB 电源"; return }
            }
            lastDeviceStatus = nil; deviceStatusCheckedAt = nil
            deviceSummary = "设备状态尚未重新确认，请检查连接；不会自动重试控制请求"
            notice = "\(error.localizedDescription) 请重新检查设备状态；控制请求不会自动重试。"
        }
    }
    func prepare() async {
        guard !isSessionActive, !probing, save() else { return }
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
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration else { return }
            // prepare() is invoked only by the explicit Start Control button.
            // Never renew an existing authorization or arm from observation/resume.
            if device.supportsSoftwareControl, !device.armed {
                guard device.hid_connected else { throw PilotError.message("请先点开始蓝牙配对，并在 iPhone 系统设置完成配对。") }
                requestedSoftwareArm = true
                device = try await sessionClient.armSoftwareControl(expected: device)
                guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration else {
                    try await sessionClient.stopAndVerify()
                    return
                }
            }
            guard device.armed, device.hid_connected else { throw PilotError.message("请先在系统配对 BLE HID，再在 App 允许控制（软件模式）或按硬件 ARM。") }
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration else { return }
            let command = SessionCommand(task: String(task.prefix(2000)), running: true)
            try SharedStore.shared.startCommand(command, expectedStopGeneration: expectedStopGeneration)
            createdSessionID = command.id
            if configuration.continuedProcessingEnabled == true {
                do { try await ContinuedSession.shared.start(command: command, configuration: configuration) }
                catch {
                    try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                    throw error
                }
                guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration else { ContinuedSession.shared.cancel(); return }
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
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration else { return }
            prepared = SharedStore.shared.command?.running == true
            if !hardwareStopUnconfirmed { notice = error.localizedDescription }
        }
    }
    func stop() async {
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
        guard !sending else { return }
        guard !isSessionActive, !probing else { notice = "手动校准前请停止自动会话，避免竞争。"; return }
        if let text, !text.utf8.allSatisfy({ (32...126).contains($0) }) || text.count > 64 {
            notice = "键盘原型仅支持最多64字符可打印 US ASCII，不支持中文。"; return
        }
        guard save() else { return }
        sending = true
        defer { sending = false }
        do {
            let client = HardwareClient(configuration: configuration)
            let device = try await client.status()
            let proposal = ActionProposal(type: kind, dx: dx, dy: dy, wheel: wheel, button: "left", key: key, text: text,
                purpose: "navigation", risk: "low", requiresConfirmation: false, reason: "用户手动校准", pointerVisible: true, highRisk: false, confidence: 1)
            try await client.send(proposal, expectedSession: device.session_id)
            notice = "手动动作已由硬件确认完成。请观察手机实际效果。"
        } catch { notice = error.localizedDescription; await HardwareClient(configuration: configuration).stop() }
    }
}
