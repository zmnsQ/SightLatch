import SwiftUI
import Combine
import ActivityKit

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
    @Published var storageWarning: String? = nil
    private var preparationID = UUID()
    var isSessionActive: Bool { preparing || stopping || sending || SharedStore.shared.command?.running == true }
    private var ticker: AnyCancellable?
    private var lastActivityUpdate = Date.distantPast
    private var activity: Activity<PilotActivityAttributes>?

    init() {
        storageWarning = SharedStore.shared.readFailure("workspace.json", as: WorkspaceState.self)
            ?? SharedStore.shared.readFailure("configuration.json", as: PilotConfiguration.self)
        initializeWorkspace()
        if let storageWarning { notice = storageWarning }
        prepared = SharedStore.shared.command?.running == true
        if let command = SharedStore.shared.command {
            activity = Activity<PilotActivityAttributes>.activities.first { $0.attributes.sessionID == command.id }
            if task.isEmpty { task = command.task }
        }
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        status = SharedStore.shared.status
        logs = SharedStore.shared.logs
        syncTaskStatus()
        if !preparing { prepared = SharedStore.shared.command?.running == true }
        if status.phase == "停止", let command = SharedStore.shared.command, command.id == status.sessionID, command.running {
            try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
            prepared = false
        }
        if ["停止", "暂停"].contains(status.phase), SharedStore.shared.command?.running != true, let ended = activity {
            activity = nil
            let finalState = PilotActivityAttributes.ContentState(phase: status.phase, steps: status.steps, updatedAt: status.updatedAt)
            Task { await ended.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .default) }
        }
        guard Date().timeIntervalSince(lastActivityUpdate) >= 5 else { return }
        lastActivityUpdate = Date()
        if let activity {
            let content = ActivityContent(state: PilotActivityAttributes.ContentState(phase: status.phase, steps: status.steps, updatedAt: status.updatedAt), staleDate: status.updatedAt.addingTimeInterval(15))
            Task { await activity.update(content) }
        }
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
    func probe() async {
        guard !probing, save() else { return }
        probing = true
        defer { probing = false }
        let checkedConfiguration = configuration
        do {
            let value = try await HardwareClient(configuration: checkedConfiguration).status()
            guard configuration.deviceURL == checkedConfiguration.deviceURL else { return }
            lastDeviceStatus = value
            deviceSummary = "局域网已响应 · BLE \(value.hid_connected ? "已连接" : "未连接") · \(value.armed ? "已 ARM" : "未 ARM（请按硬件按钮）")"
            notice = deviceSummary
        } catch { lastDeviceStatus = nil; deviceSummary = "检查失败，请查看恢复说明"; notice = error.localizedDescription }
    }
    func prepare() async {
        guard !isSessionActive, !probing, save() else { return }
        SharedStore.shared.remove("frame.json")
        SharedStore.shared.remove("lease.json")
        preparing = true
        let token = UUID()
        preparationID = token
        defer { if preparationID == token { preparing = false } }
        var createdSessionID: String?
        do {
            guard configuration.uploadConsent, configuration.relativeModeConfirmed, !configuration.model.isEmpty,
                  !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PilotError.message("请填写任务、视觉模型，完成指针校准，并明确同意上传屏幕。")
            }
            if configuration.provider == "openai", configuration.gatewayVisionConfirmed != true {
                throw PilotError.message("请先确认兼容端点和所选模型支持图片输入，且你获准用于该自动操作场景。")
            }
            _ = try SecretStore.load(configuration.apiAccount)
            let device = try await HardwareClient(configuration: configuration).status()
            guard device.armed, device.hid_connected else { throw PilotError.message("请先在系统配对 BLE HID 并按硬件 ARM。") }
            guard preparationID == token else { return }
            let command = SessionCommand(task: String(task.prefix(2000)), running: true)
            try SharedStore.shared.write(command, to: "command.json")
            createdSessionID = command.id
            if configuration.continuedProcessingEnabled == true {
                do { try await ContinuedSession.shared.start(command: command, configuration: configuration) }
                catch {
                    try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                    throw error
                }
                guard preparationID == token else { ContinuedSession.shared.cancel(); return }
            }
            try SharedStore.shared.write(PilotStatus(phase: "待广播", detail: "会话已准备，请主动开始系统广播", steps: 0, sessionID: command.id), to: "status.json")
            status = SharedStore.shared.status
            try recordSession(command)
            lastDeviceStatus = device
            prepared = true
            notice = "会话已准备。请点系统广播按钮，选择 HIDPilot Broadcast。广播会持续上传屏幕直到你停止。"
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                let initial = PilotActivityAttributes.ContentState(phase: "待广播", steps: 0, updatedAt: Date())
                activity = try? Activity.request(attributes: PilotActivityAttributes(sessionID: command.id), content: ActivityContent(state: initial, staleDate: Date().addingTimeInterval(15)), pushType: nil)
            }
        } catch {
            if let createdSessionID, let command = SharedStore.shared.command, command.id == createdSessionID {
                try? SharedStore.shared.updateCommand(sessionID: command.id) { $0.running = false }
                ContinuedSession.shared.cancel()
                await HardwareClient(configuration: SharedStore.shared.configuration).stop()
            }
            guard preparationID == token else { return }
            prepared = SharedStore.shared.command?.running == true
            notice = error.localizedDescription
        }
    }
    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        preparationID = UUID()
        preparing = false
        ContinuedSession.shared.cancel()
        let store = SharedStore.shared
        let sessionID = store.command?.id ?? status.sessionID
        var localError: String?
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
        prepared = store.command?.running == true
        if let localError {
            notice = "本地停止写入失败：\(localError)。请立即物理急停并结束系统广播。"
        } else {
            notice = hardwareConfirmed
                ? "硬件已确认解除ARM且无在途动作。本地会话已停止；请从系统结束广播。"
                : "本地会话已停止，但未确认硬件停止送达。请按物理急停并从系统结束广播核实。"
            let stoppedStatus = PilotStatus(phase: "停止", detail: notice, steps: status.steps, sessionID: sessionID)
            do { try store.write(stoppedStatus, to: "status.json"); status = stoppedStatus }
            catch { notice += " 状态记录写入失败。" }
            syncTaskStatus()
        }
        if let activity {
            await activity.end(ActivityContent(state: .init(phase: hardwareConfirmed ? "硬件已解除ARM" : "请核实硬件停止", steps: status.steps, updatedAt: Date()), staleDate: nil), dismissalPolicy: .default)
            self.activity = nil
        }
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
            notice = "请重新物理 ARM，返回目标 App。旧动作已丢弃；系统只会根据之后的新帧重新规划。"
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
