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
    @Published var checkingTaskPrerequisites = false
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
    @Published var captureObservation: CaptureObservation?
    @Published var logs = SharedStore.shared.logs
    @Published var notice = "开发源码版本：iOS实际构建与真机行为仍需验证"
    @Published var prepared = false
    @Published var sending = false
    @Published var preparing = false
    @Published var stopping = false
    @Published var probing = false
    @Published var probeState = DeviceProbeState.idle
    @Published var pairingState = DevicePairingState.idle
    @Published private(set) var pairingUsesSystemMouse = false
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
    private var continuedStartupTask: Task<Void, Never>?
    private var continuedStartupID = UUID()
    var isSessionActive: Bool { calibrationFlow.isBusy || continuedStartupTask != nil || preparingRequestInFlight || preparing || stopping || sending || controllingDevice || SharedStore.shared.command?.running == true }
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
    func answerClarification(questionID: String, optionID: String) async {
        guard let command = SharedStore.shared.command, command.running, !stopping else { return }
        do {
            _ = try SharedStore.shared.resolveClarification(sessionID: command.id,
                questionID: questionID, optionID: optionID)
            notice = ""
            refresh()
            await PilotActivityPublisher.shared.publish(SharedStore.shared.status)
        } catch { notice = error.localizedDescription }
    }

    func refresh() {
        if configuration.automaticCalibrationProfile != nil,
           configuration.hasVerifiedPointerCalibration || SharedStore.shared.command?.running == true {
            do { try validateAutomaticCalibrationContext() }
            catch {
                let reason = error.localizedDescription
                notice = reason
                if !invalidateActiveCalibrationContext(reason), isSessionActive, !stopping {
                    Task { await stop(); notice = reason + " 已停止当前会话。" }
                }
            }
        }
        // Poll only an explicitly checked device, in the foreground. This never arms it.
        if !deviceStatusIsFresh, lastDeviceStatus != nil {
            lastDeviceStatus = nil
            deviceSummary = "设备状态已过期，请重新检查；不能据此确认 BLE 或控制授权。"
        }
        if UIApplication.shared.applicationState == .active, observedDeviceURL == configuration.deviceURL,
           !probing, !refreshingDeviceStatus, !controllingDevice, !stopping, !preparing, !sending,
           !calibrationFlow.isBusy, !calibrationRequestInFlight, !automaticCalibration.isBusy,
           !checkingTaskPrerequisites, Date().timeIntervalSince(lastDevicePoll) >= 3 {
            lastDevicePoll = Date()
            Task { await refreshDeviceStatus() }
        }
        status = SharedStore.shared.status
        if let command = SharedStore.shared.command, command.running,
           status.sessionID == command.id, let question = command.pendingClarification {
            status.phase = "等待用户"
            status.detail = question.question
            status.userMessage = question.question
        }
        if let command = SharedStore.shared.command, command.running,
           taskFlow.sessionID == command.id, command.task != task {
            task = command.task
        }
        captureObservation = SharedStore.shared.read("capture-status.json", as: CaptureObservation.self)
        preparePendingMessageClipboard()
        startContinuedSessionAfterFirstFrameIfNeeded()
        launchMessageAppIfNeeded()
        logs = SharedStore.shared.logs
        syncTaskStatus()
        syncPlanningState()
        if !preparing { prepared = SharedStore.shared.command?.running == true }
        if status.phase == "停止", let command = SharedStore.shared.command, command.id == status.sessionID, command.running {
            try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
            prepared = false
        }
        PilotActivityManager.shared.publish(status, running: SharedStore.shared.command?.running == true)
        SessionVoiceController.shared.update(status: status, command: SharedStore.shared.command)
    }
    private func startContinuedSessionAfterFirstFrameIfNeeded() {
        let store = SharedStore.shared
        guard continuedStartupTask == nil, !stopping, !preparing, hasForegroundWindowScene(),
              store.configuration.continuedProcessingEnabled == true, store.configuration.uploadConsent,
              let command = store.command, command.running, taskFlow.sessionID == command.id else { return }
        guard let execution = command.continuedExecution else {
            notice = "旧会话缺少后台启动状态，请停止后重新发送当前目标。"
            return
        }
        guard command.authorizationIsCurrent(requireActive: true),
              execution.phase == .awaitingFirstFrame, store.stopGeneration == execution.stopGeneration,
              let firstFrame = captureObservation, firstFrame.sessionID == command.id,
              firstFrame.generation == command.generation, firstFrame.hasFreshFrame,
              let receivedAt = firstFrame.receivedAt, receivedAt >= command.createdAt, receivedAt <= Date() else { return }
        let token = UUID()
        continuedStartupID = token
        let savedConfiguration = store.configuration
        let expectedStopGeneration = execution.stopGeneration
        continuedStartupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.continuedStartupID == token { self.continuedStartupTask = nil }
            }
            do {
                try await ContinuedSession.shared.startAfterFirstFrame(command: command, configuration: savedConfiguration,
                    firstFrame: firstFrame, expectedStopGeneration: expectedStopGeneration)
                guard self.continuedStartupID == token, !self.stopping,
                      let current = store.command, current.id == command.id, current.running,
                      current.generation == command.generation, store.stopGeneration == expectedStopGeneration,
                      self.isContinuedExecutionReady(for: current) else { return }
                self.captureObservation = store.read("capture-status.json", as: CaptureObservation.self)
                self.launchMessageAppIfNeeded()
            } catch {
                // A late startup result must not overwrite a newer goal or cancellation.
                guard self.continuedStartupID == token, !self.stopping,
                      let current = store.command, current.id == command.id,
                      current.generation == command.generation, store.stopGeneration == expectedStopGeneration else { return }
                // Cover coordinator rejection before its atomic startup claim as well.
                // Revocation makes the live broadcast's control poll STOP this session.
                let failed = (try? store.failContinuedStart(sessionID: command.id, generation: command.generation,
                    expectedStopGeneration: expectedStopGeneration, reason: error.localizedDescription)) == true
                if !failed, let latest = store.command, latest.running {
                    // Another atomic claimant owns starting/active; its success is not our error.
                    if latest.continuedExecution?.phase == .awaitingFirstFrame {
                        self.notice = "后台启动未成功且停止状态未能写入。请立即断开设备电源并结束广播。"
                    }
                    return
                }
                self.notice = error.localizedDescription
                self.status = store.status
                self.prepared = store.command?.running == true
                self.syncPlanningState()
            }
        }
    }
    private func launchMessageAppIfNeeded() {
        let store = SharedStore.shared
        // A system broadcast panel can make a visible scene inactive. This is
        // still a foreground handoff; background or disconnected scenes cannot open it.
        guard hasForegroundWindowScene(), !stopping,
              store.configuration.uploadConsent, let command = store.command, command.authorizationIsCurrent(requireActive: true),
              isContinuedExecutionReady(for: command),
              let scope = command.messageScope, scope.launch.phase == .pending,
              scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
              store.stopGeneration == scope.stopGeneration, let firstFrame = captureObservation,
              firstFrame.sessionID == command.id, firstFrame.generation == command.generation,
              firstFrame.hasFreshFrame else { return }
        let context = MessageDispatchContext(sessionID: command.id, generation: command.generation,
            frameID: "foreground-launch", scopeID: scope.id)
        do { try store.beginMessageLaunch(context: context, expectedStopGeneration: scope.stopGeneration, firstFrame: firstFrame) }
        catch { return } // Cancelled/stale claims cannot open another app or replace the newer status.
        func stillOwned() -> Bool {
            guard !stopping, hasForegroundWindowScene(),
                  let current = store.command, current.running, current.id == command.id,
                  current.generation == command.generation, current.messageScope?.id == scope.id,
                  isContinuedExecutionReady(for: current),
                  current.messageScope?.launch.phase == .opening,
                  current.messageScope?.matches(sessionID: current.id, generation: current.generation, task: current.task) == true else { return false }
            return store.configuration.uploadConsent && store.stopGeneration == scope.stopGeneration
        }
        guard stillOwned() else {
            try? store.releaseMessageLaunchClaim(context: context, expectedStopGeneration: scope.stopGeneration)
            return
        }
        let url = URL(string: "weixin://")! // Only launch the app; no recipient, body or send URL parameters.
        guard UIApplication.shared.canOpenURL(url) else {
            completeMessageLaunch(context: context, stopGeneration: scope.stopGeneration, opened: false,
                failure: "未检测到可用的微信系统入口。请检查微信是否已安装；本轮未发送输入，原计划已保留。")
            return
        }
        guard stillOwned() else {
            try? store.releaseMessageLaunchClaim(context: context, expectedStopGeneration: scope.stopGeneration)
            return
        }
        do { try store.markMessageLaunchDispatched(context: context, expectedStopGeneration: scope.stopGeneration) }
        catch {
            try? store.releaseMessageLaunchClaim(context: context, expectedStopGeneration: scope.stopGeneration)
            return
        }
        notice = "正在打开微信；AI会读取画面并处理本次系统打开确认。"
        // UIKit calls this completion on the main queue/MainActor. Persist its
        // result in that callback before background suspension, without another
        // queued Task. Acceptance is not proof that a particular chat is visible.
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            self?.completeMessageLaunch(context: context, stopGeneration: scope.stopGeneration,
                opened: opened, failure: nil)
        }
    }
    private func completeMessageLaunch(context: MessageDispatchContext, stopGeneration: String?, opened: Bool, failure: String?) {
        guard SharedStore.shared.configuration.uploadConsent else { return }
        do {
            let accepted = try SharedStore.shared.finishMessageLaunch(context: context, expectedStopGeneration: stopGeneration,
                opened: opened, failure: failure)
            guard accepted else { return } // A late callback cannot undo visual confirmation or the task UI.
            if !opened {
                let reason = failure ?? "系统未接受微信打开请求，本轮已停止；原计划已保留，可重新检查并继续。"
                taskFlow.recoverLaunchFailure(sessionID: context.sessionID, detail: reason)
                notice = reason
            }
        } catch { /* STOP, a changed session or generation invalidates late acknowledgments. */ }
    }
    private func hasForegroundWindowScene() -> Bool {
        let app = UIApplication.shared
        guard app.applicationState != .background else { return false }
        return app.connectedScenes.contains { scene in
            guard scene is UIWindowScene else { return false }
            return scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        }
    }
    private func isContinuedExecutionReady(for command: SessionCommand) -> Bool {
        let store = SharedStore.shared
        guard store.configuration.continuedProcessingEnabled == true else { return true }
        guard let execution = command.continuedExecution, execution.phase == .active,
              store.stopGeneration == execution.stopGeneration,
              let lease = store.read("lease.json", as: ExecutionLease.self),
              lease.sessionID == command.id, lease.expiresAt > Date() else { return false }
        return true
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
        guard !probing, !refreshingDeviceStatus, !controllingDevice, !stopping, !preparingRequestInFlight, !sending,
              !calibrationFlow.isBusy, !calibrationRequestInFlight, !automaticCalibration.isBusy,
              !checkingTaskPrerequisites else { return }
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
            if changedDevice { saved.invalidatePointerCalibration() }
            // Only explicitly entered tokens are saved, bound to this exact validated endpoint.
            // No automatic credential migration or copying to a different host.
            if !deviceToken.isEmpty { try SecretStore.save(deviceToken, account: saved.deviceAccount) }
            try SharedStore.shared.write(saved, to: "configuration.json")
            if let index = workspace.profiles.firstIndex(where: { $0.id == workspace.selectedProfileID }) {
                if workspace.profiles[index].configuration.deviceURL != address {
                    workspace.profiles[index].configuration.invalidatePointerCalibration()
                }
                workspace.profiles[index].configuration.deviceURL = address
                guard persistWorkspace() else { return false }
            }
            configuration.deviceURL = address
            if changedDevice { configuration.invalidatePointerCalibration() }
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
    func startPairing(usingSystemMouse: Bool = false) async {
        guard pairingTask == nil else { return }
        guard !isSessionActive, !probing else {
            pairingState = .init(phase: .error, message: "请先结束当前检查或会话，再开始配对。")
            return
        }
        pairingUsesSystemMouse = usingSystemMouse
        pairingState = .init(phase: .opening, message: usingSystemMouse ? "正在释放 App 蓝牙连接，准备系统鼠标配对…" : "正在保存并请求设备打开配对窗口…")
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
        if usingSystemMouse { SightLatchAccessorySetupAdapter.releaseConnectionsForSystemPairing() }
        let operation = Task { await self.runPairing(configuration: checked, operationID: operationID, stopGeneration: generation, usingSystemMouse: usingSystemMouse) }
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
    private func runPairing(configuration checked: PilotConfiguration, operationID: UUID, stopGeneration: String?, usingSystemMouse: Bool) async {
        let client = HardwareClient(configuration: checked)
        var receipt: DevicePairingReceipt?
        func ownsOperation() -> Bool {
            deviceControlID == operationID && SharedStore.shared.stopGeneration == stopGeneration && configuration.deviceURL == checked.deviceURL
        }
        do {
            var current = try await client.status()
            guard ownsOperation() else { pairingState = .init(phase: .cancelled, message: "设备或停止状态已变化，配对已取消。"); return }
            if pairingCancelRequested { pairingState = .init(phase: .cancelled, message: "配对已取消，尚未打开窗口。"); return }
            acceptDeviceStatus(current, from: checked)
            guard current.supportsSoftwareControl else { throw PilotError.message("此固件需要硬件按钮打开配对窗口。") }
            guard !current.armed else { throw PilotError.message("设备正在控制中，请先停止再配对。") }
            if usingSystemMouse {
                // cancelPeripheralConnection is asynchronous. Do not mistake the old
                // transport for a fresh system connection or open a window over it.
                let disconnectDeadline = Date().addingTimeInterval(2)
                while current.hid_connected && Date() < disconnectDeadline {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard ownsOperation(), !pairingCancelRequested else {
                        pairingState = .init(phase: .cancelled, message: "系统鼠标配对已取消，尚未打开窗口。")
                        return
                    }
                    current = try await client.status()
                    guard !current.armed else { throw PilotError.message("设备正在控制中，请先停止再配对。") }
                }
                guard ownsOperation(), !pairingCancelRequested else { return }
                guard !current.hid_connected else {
                    throw PilotError.message("系统仍持有设备连接。请先在系统蓝牙设置断开 SightLatch，再重新开启系统鼠标配对。")
                }
            }
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
                pairingState = .init(phase: .waiting, message: usingSystemMouse ? "30 秒窗口已打开。请在系统辅助触控的蓝牙设备中选择 SightLatch，返回后检查连接。" : "配对窗口已打开，正在等待加密连接。", deadline: deadline)
                let observed = try await client.status()
                guard ownsOperation() else { pairingState = .init(phase: .cancelled, message: "配对检查已取消。"); return }
                if pairingCancelRequested { continue }
                guard observed.boot_id == receipt!.boot_id, observed.control_epoch == receipt!.control_epoch, !observed.armed else {
                    pairingState = .init(phase: .error, message: "设备已重启或控制状态已变化，已停止配对检查；不会干扰新会话。")
                    return
                }
                // Keep capability and freshness current while the system picker is open.
                // A response from another boot/epoch must never refresh this attempt.
                acceptDeviceStatus(observed, from: checked)
                // Firmware defines hid_connected as connected && encrypted (16-byte key).
                if observed.hid_connected {
                    pairingState = .init(phase: .connected, message: "板端已确认加密蓝牙连接。请在指针校准中确认系统指针确实可移动。")
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
    /// Returning from Settings only reads status; it never reopens a window or connects.
    func checkSystemMousePairing() async {
        guard pairingUsesSystemMouse, pairingTask == nil, !isSessionActive, !probing else { return }
        controllingDevice = true
        defer { controllingDevice = false }
        let operationID = UUID()
        deviceControlID = operationID
        let checked = configuration
        let generation = SharedStore.shared.stopGeneration
        do {
            let value = try await HardwareClient(configuration: checked).status()
            guard deviceControlID == operationID, SharedStore.shared.stopGeneration == generation,
                  configuration.deviceURL == checked.deviceURL, pairingUsesSystemMouse else { return }
            acceptDeviceStatus(value, from: checked)
            pairingState = .init(phase: value.hid_connected ? .connected : .expired,
                message: value.hid_connected ? "板端已确认加密蓝牙连接。仍需通过指针校准确认鼠标可用。" : "尚未确认加密连接。可重新开启 30 秒窗口，再到系统辅助触控中选择设备。")
        } catch {
            guard deviceControlID == operationID, SharedStore.shared.stopGeneration == generation,
                  configuration.deviceURL == checked.deviceURL, pairingUsesSystemMouse else { return }
            pairingState = .init(phase: .error, message: DeviceProbeFailure.classify(error).localizedDescription)
        }
    }
    func enableSessionVoice() async {
        guard let command = SharedStore.shared.command, command.running else { return }
        let voice = SessionVoiceController.shared
        voice.onCommand = { [weak self] text in self?.receiveVoiceInstruction(text) }
        _ = await voice.start(sessionID: command.id)
    }

    private func receiveVoiceInstruction(_ text: String) {
        let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 2000,
              let command = SharedStore.shared.command, command.running,
              SharedStore.shared.configuration.uploadConsent else { return }
        if ["停止", "停下", "停一下", "暂停", "取消任务", "别发", "不要发", "stop", "cancel"].contains(where: { goal.lowercased().hasPrefix($0) }) {
            Task { await stop() }
            return
        }
        do {
            try SharedStore.shared.enqueueGoalInstruction(SessionGoalInstruction(sessionID: command.id,
                generation: command.generation, expectedStopGeneration: SharedStore.shared.stopGeneration, goal: goal))
            notice = "已收到追加命令，将在当前动作结束后读取新画面。"
            SessionVoiceController.shared.announce("收到，当前动作结束后继续。", key: "instruction-\(UUID().uuidString)")
        } catch {
            notice = error.localizedDescription
            SessionVoiceController.shared.announce("当前会话已变化，请重新开始。", key: "instruction-rejected")
        }
    }

    private func clipboardOptions(for command: SessionCommand) -> [UIPasteboard.OptionsKey: Any] {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        // Clipboard retention is separate from total runtime. Re-prepare the exact
        // still-authorized body in the foreground if this finite local copy expires.
        let clipboardEnd = Date().addingTimeInterval(600)
        let sessionEnd = command.execution?.phase == .active ? command.authorizationExpiresAt :
            (command.isUnlimited ? nil : command.preparationExpiresAt.addingTimeInterval(SessionExecution.hardwareStartupTimeout + (command.execution?.boundedDuration ?? 300)))
        options[.expirationDate] = sessionEnd.map { min($0, clipboardEnd) } ?? clipboardEnd
        return options
    }

    private func preparePendingMessageClipboard() {
        let store = SharedStore.shared
        guard let command = store.command, command.running,
              let scope = command.messageScope, !scope.clipboardIsReady, !scope.pasteAttempted, !scope.sendAttempted, !scope.verified,
              command.authorizationIsCurrent(), scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
              store.configuration.uploadConsent, store.stopGeneration == scope.stopGeneration else { return }
        guard UIApplication.shared.applicationState == .active else {
            SessionVoiceController.shared.announce("新的消息需要准备正文，请回到 SightLatch 一次。", key: "clipboard-\(scope.id)")
            return
        }
        let clipboardOptions = clipboardOptions(for: command)
        UIPasteboard.general.setItems([["public.utf8-plain-text": scope.intent.body]], options: clipboardOptions)
        let context = MessageDispatchContext(sessionID: command.id, generation: command.generation,
            frameID: "clipboard-preparation", scopeID: scope.id)
        do { try store.markMessageClipboardPrepared(context: context, expectedStopGeneration: scope.stopGeneration, expiresAt: clipboardOptions[.expirationDate] as? Date) }
        catch { notice = error.localizedDescription }
    }

    // Compatibility entry point: pairing is supported; task ARM requires a fresh goal permit.
    func requestDeviceControl(pairing: Bool) async {
        guard pairing else { notice = "请先在聊天发送目标，阅读计划并明确允许本次控制。"; return }
        await startPairing()
    }
    func prepare(unlimitedConfirmed: Bool = false) async {
        guard !isSessionActive, !probing else { return }
        let requestedUnlimited = configuration.unlimitedRun == true
        let requestedDuration = configuration.selectedRunDurationSeconds
        let durationIdentity = planningConfigurationID()
        guard !requestedUnlimited || unlimitedConfirmed else {
            notice = "不限时运行需要为本次任务再次确认。"; return
        }
        guard requestedUnlimited || (60...86400).contains(requestedDuration) else {
            notice = "单次运行时长应为 1 分钟至 24 小时。"; return
        }
        var missing = taskPreparationIssues()
        if MessageIntent.parse(task.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
           !configuration.allowLowRiskNavigation {
            let navigationIssue = TaskPrerequisite(kind: .settings, title: "本次微信任务需要导航权限",
                detail: "请在设置的“权限与安全”开启“允许低风险导航点击和搜索框 ASCII 输入”，再点“继续此任务”。当前目标和已有校准会保留。",
                actionTitle: "检查权限与安全")
            if let index = missing.firstIndex(where: { $0.kind == .settings }) {
                missing[index].detail += "\n" + navigationIssue.detail
            } else { missing.append(navigationIssue) }
        }
        guard missing.isEmpty else { taskFlow.require(missing); notice = missing[0].detail; return }
        guard save() else {
            taskFlow.require([.init(kind: .settings, title: "设置未能保存", detail: notice, actionTitle: "检查设置")]); return
        }
        guard taskFlow.consumePermission(goal: task.trimmingCharacters(in: .whitespacesAndNewlines), configurationID: planningConfigurationID()) else {
            notice = taskFlow.prerequisites.first?.detail ?? taskFlow.errorMessage ?? "请从当前计划明确开始；旧授权不能再次使用。"; return
        }
        let preparedGoal = taskFlow.goal
        SharedStore.shared.remove("frame.json")
        SharedStore.shared.remove("capture-status.json")
        captureObservation = nil
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
        var preparationStage: TaskPrerequisite.Kind = .calibration
        let sessionClient = HardwareClient(configuration: configuration)
        let expectedStopGeneration = SharedStore.shared.stopGeneration
        do {
            try validateAutomaticCalibrationContext()
            guard configuration.uploadConsent else {
                throw TaskPrerequisite(kind: .retry, title: "本次执行尚未获准", detail: "请从当前计划的开始按钮继续；尚未上传屏幕或控制设备。", actionTitle: "重新检查")
            }
            if configuration.provider == "openai", configuration.gatewayVisionConfirmed != true {
                throw TaskPrerequisite(kind: .aiConnection, title: "需要确认图片输入能力", detail: "请在 AI 账户确认当前模型支持图片输入。", actionTitle: "检查 AI 账户")
            }
            preparationStage = .aiConnection
            if configuration.provider == "chatgpt-plan" {
                guard configuration.chatGPTPlanConsent == true else { throw PilotError.message("请先在设置中同意本次屏幕任务使用 ChatGPT 套餐。") }
                _ = try await ChatGPTOAuth.shared.accessToken()
            } else {
                _ = try SecretStore.load(configuration.apiAccount)
            }
            preparationStage = .deviceConnection
            let device = try await sessionClient.status()
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else { return }
            guard device.hid_connected else {
                throw TaskPrerequisite(kind: .bluetoothPairing, title: "蓝牙尚未连接",
                    detail: "请在设备设置恢复蓝牙连接，再继续当前目标。", actionTitle: "连接设备")
            }
            guard device.hasVerifiedPointerCalibration(configuration: configuration) else {
                configuration.invalidatePointerCalibration()
                throw TaskPrerequisite(kind: .calibration, title: "当前设备需要坐标校准",
                    detail: "设备能力、蓝牙连接代际或已保存的坐标映射不再匹配。请重新校准；当前目标会保留。", actionTitle: "重新校准")
            }
            // Preparation binds the future first-frame start. It does not spend
            // the hardware lease while the user is in the system broadcast UI.
            preparationStage = .deviceControl
            let hardwareAuthorization = try device.preparedHardwareAuthorization(configuration: configuration)
            let requiresRenewal = requestedUnlimited || requestedDuration > 300
            guard durationIdentity == planningConfigurationID() else { throw PilotError.message("执行设置已变化，请重新确认本次任务。") }
            guard !requiresRenewal || (hardwareAuthorization.softwareControl && device.session_renewal_supported == true) else {
                throw PilotError.message("超过 5 分钟或不限时运行需要支持会话续租的新固件和软件控制模式；请升级设备后重试。")
            }
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else { return }
            preparationStage = .retry
            var command = SessionCommand(task: preparedGoal, running: true)
            command.execution = SessionExecution(stopGeneration: expectedStopGeneration, hardware: hardwareAuthorization,
                durationSeconds: requestedUnlimited ? nil : requestedDuration, unlimitedConfirmed: requestedUnlimited,
                renewableHardwareLease: requiresRenewal)
            if configuration.continuedProcessingEnabled == true {
                command.continuedExecution = .init(phase: .awaitingFirstFrame, stopGeneration: expectedStopGeneration)
            }
            if let intent = MessageIntent.parse(preparedGoal) {
                guard UIApplication.shared.applicationState == .active else {
                    throw TaskPrerequisite(kind: .retry, title: "请回到 SightLatch 继续", detail: "需要在前台准备本次消息正文；尚未开始控制。", actionTitle: "重新检查")
                }
                let expiry = command.preparationExpiresAt
                // Write only the authorized body. Never read, back up or synchronize the user's clipboard.
                let clipboardOptions = clipboardOptions(for: command)
                UIPasteboard.general.setItems([["public.utf8-plain-text": intent.body]], options: clipboardOptions)
                command.messageScope = MessageScope(intent: intent, sessionID: command.id,
                    generation: command.generation, expiresAt: expiry, stopGeneration: expectedStopGeneration)
                command.messageScope?.clipboardPrepared = true
                command.messageScope?.clipboardExpiresAt = clipboardOptions[.expirationDate] as? Date
            }
            try SharedStore.shared.startCommand(command, expectedStopGeneration: expectedStopGeneration)
            createdSessionID = command.id
            try SharedStore.shared.write(PilotStatus(phase: "待广播", detail: "会话已准备，请主动开始系统广播", steps: 0, sessionID: command.id), to: "status.json")
            status = SharedStore.shared.status
            try recordSession(command)
            acceptDeviceStatus(device, from: configuration)
            notice = "会话已准备。请点系统广播按钮，选择 SightLatch Broadcast。广播会持续上传屏幕直到你停止。"
            let activityIssue = await PilotActivityManager.shared.start(sessionID: command.id,
                expectedStopGeneration: expectedStopGeneration)
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  SharedStore.shared.command?.id == command.id, SharedStore.shared.command?.running == true else { return }
            prepared = true
            if let activityIssue { notice += " " + activityIssue }
        } catch {
            deviceObservationID = UUID()
            lastDeviceStatus = nil; deviceStatusCheckedAt = nil
            deviceSummary = "本次接管未开始，设备状态需重新检查"
            if let createdSessionID, let command = SharedStore.shared.command, command.id == createdSessionID {
                try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                ContinuedSession.shared.cancel()
                try? await HardwareClient(configuration: SharedStore.shared.configuration).stopAndVerify(expectedSessionID: createdSessionID)
            }
            guard preparationID == token, SharedStore.shared.stopGeneration == expectedStopGeneration,
                  task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal else { return }
            prepared = SharedStore.shared.command?.running == true
            do {
                let issue: TaskPrerequisite
                if let known = error as? TaskPrerequisite { issue = known }
                else if preparationStage == .deviceConnection { issue = devicePreparationIssue(error) }
                else {
                    issue = .init(kind: preparationStage,
                        title: preparationStage == .aiConnection ? "AI 连接需要检查" : preparationStage == .calibration ? "需要重新校准" : "会话尚未准备完成",
                        detail: error.localizedDescription,
                        actionTitle: preparationStage == .aiConnection ? "检查 AI 账户" : preparationStage == .calibration ? "重新校准" : "重新检查")
                }
                taskFlow.require([issue]); notice = issue.detail
            }
        }
    }
    func stop() async {
        guard !stopping else { return }
        let onlyPlanning = !isSessionActive && [.planning, .prerequisites, .awaitingPermission].contains(taskFlow.phase)
        let pendingContinuedStartup = continuedStartupTask
        continuedStartupID = UUID()
        pendingContinuedStartup?.cancel()
        stopping = true
        defer { continuedStartupTask = nil; stopping = false }
        SessionVoiceController.shared.stop()
        if automaticCalibration.isBusy {
            let scene: CalibrationCancellationScene
            switch UIApplication.shared.applicationState {
            case .active: scene = .active
            case .inactive: scene = .inactive
            case .background: scene = .background
            @unknown default: scene = .unknown
            }
            recordCalibrationCancellation(source: .globalStop, scene: scene)
        }
        if calibrationFlow.isBusy { await endPointerCalibration() }
        planningTask?.cancel(); planningTask = nil; taskFlow.cancel()
        if onlyPlanning { notice = "已取消规划和待授权计划；未开始控制。"; return }
        let hadControlRequestInFlight = preparingRequestInFlight || controllingDevice
        deviceControlID = UUID()
        deviceObservationID = UUID()
        lastDeviceStatus = nil
        deviceStatusCheckedAt = nil
        deviceSummary = "正在请求停止控制，尚未确认设备状态"
        preparationID = UUID()
        preparing = false
        ContinuedSession.shared.cancel()
        let store = SharedStore.shared
        let stopCommandID = store.command?.id
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
        // Drain the startup owner's bounded cleanup before a new ARM can be prepared.
        if let pendingContinuedStartup { await pendingContinuedStartup.value }
        continuedStartupTask = nil
        // Do not hide a failed local revocation even when the hardware STOP succeeds.
        var hardwareConfirmed = false
        do { try await HardwareClient(configuration: store.configuration).stopAndVerify(expectedSessionID: stopCommandID); hardwareConfirmed = true }
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
                do { try await HardwareClient(configuration: store.configuration).stopAndVerify(expectedSessionID: stopCommandID); hardwareConfirmed = true }
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
            let stoppedStatus = PilotStatus(phase: hardwareConfirmed ? "停止" : "请核实硬件停止",
                detail: notice, steps: status.steps, sessionID: sessionID)
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
    /// Ending a paused attempt preserves its budget and one-shot message ledger.
    /// A new user Send is a new task; this action never re-arms or replays the old one.
    func endPausedSession() async {
        let store = SharedStore.shared
        guard !stopping, status.phase == "暂停", let command = store.command,
              command.running, command.id == status.sessionID else { return }
        let pausedDetail = status.detail
        await stop()
        guard let current = store.command, current.id == command.id, !current.running,
              status.sessionID == command.id else { return }
        let messageReminder = command.messageScope?.sendAttempted == true
            ? "本轮已尝试发送，请先在微信核对实际结果，避免重复发送。"
            : command.messageScope?.pasteAttempted == true ? "本轮已尝试粘贴，请先核对微信输入框，避免重复粘贴。" : ""
        notice = "本轮暂停原因：\(pausedDetail)\n\(notice)" + (messageReminder.isEmpty ? "" : "\n\(messageReminder)")
        var endedStatus = status
        endedStatus.detail = notice
        do { try store.write(endedStatus, to: "status.json"); status = endedStatus }
        catch { notice += " 暂停原因未能写入状态记录。" }
    }
    func manual(_ kind: ActionProposal.Kind, dx: Int? = nil, dy: Int? = nil, wheel: Int? = nil, key: String? = nil, text: String? = nil) async {
        guard kind == .move, let dx, let dy, wheel == nil, key == nil, text == nil else {
            notice = "校准仅允许显式的单轴微移，不允许点击、滚动、按键或输入。"; return
        }
        await moveCalibrationPointer(dx: dx, dy: dy)
    }
}
