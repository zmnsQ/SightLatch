import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ModelProfile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var configuration: PilotConfiguration
}
struct SavedTask: Codable, Identifiable {
    var id = UUID().uuidString
    var text: String
    var state = "待办"
    var createdAt = Date()
    var updatedAt = Date()
    var sessionID: String?
    var steps = 0
}
struct WorkspaceState: Codable {
    var onboardingComplete = false
    var theme = "system"
    var profiles: [ModelProfile] = []
    var selectedProfileID: String?
    var tasks: [SavedTask] = []
}
struct SettingsArchive: Codable {
    var format = "HIDPilot-settings"
    var version = 1
    var profiles: [ModelProfile]
}
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PilotError.message("无法读取文件") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct ReadinessItem: Identifiable {
    let id: String
    let title: String
    let passed: Bool
    let detail: String
}

struct RecoveryAdvice {
    let title: String
    let steps: String
    static func classify(_ value: String) -> RecoveryAdvice {
        let s = value.lowercased()
        if s.contains("401") || s.contains("403") || s.contains("凭据") || s.contains("keychain") {
            return .init(title: "凭据或权限不可用", steps: "停止会话，检查当前档案对应的密钥和端点。Keychain错误需确认App与扩展签名共享组；不要把密钥发到诊断日志。")
        }
        if s.contains("429") { return .init(title: "服务限流或额度不足", steps: "停止会话，在供应商控制台检查额度和限流。稍后由你手动重新开始；不自动重复请求。") }
        if s.contains("http") || s.contains("网络") || s.contains("network") || s.contains("offline") || s.contains("timed out") {
            return .init(title: "连接失败", steps: "先检查前台局域网访问与ESP32状态，再检查互联网和模型端点。App设置可重开系统权限页。不要全局关闭ATS或跳过证书验证。")
        }
        if s.contains("arm") || s.contains("硬件") || s.contains("ble") {
            return .init(title: "硬件需要人工确认", steps: "检查BLE配对、物理急停和Wi-Fi。确认目标页面安全，再按硬件ARM。会话或boot变化后重新开始，不重试旧动作。")
        }
        if s.contains("指针") || s.contains("画面") || s.contains("截图") {
            return .init(title: "画面与指针不可靠", steps: "回到安全目标页面，确认方向和系统指针。完成校准后重新开始。若广播截图不包含指针，当前设备无法可靠自动点选。")
        }
        if s.contains("json") || s.contains("decode") || s.contains("格式") || s.contains("data couldn") {
            return .init(title: "模型响应不兼容", steps: "核对原生协议、完整端点、支持视觉的模型ID。兼容网关必须返回所选协议的图片和JSON结构；无效响应不会执行。")
        }
        return .init(title: "需要你检查后继续", steps: "先查看当前状态与动作记录。确认目标App和硬件安全后人工处理，重新观察新画面。无法确认时停止，不自动恢复。")
    }
}

extension PilotViewModel {
    var selectedProfileName: String { workspace.profiles.first { $0.id == workspace.selectedProfileID }?.name ?? "当前配置" }
    var colorScheme: ColorScheme? { workspace.theme == "dark" ? .dark : workspace.theme == "light" ? .light : nil }
    var recovery: RecoveryAdvice { RecoveryAdvice.classify(status.phase == "暂停" ? status.detail : notice) }
    @discardableResult
    func persistWorkspace() -> Bool {
        guard storageWarning == nil else { notice = storageWarning!; return false }
        do {
            try SharedStore.shared.write(workspace, to: "workspace.json")
            return true
        } catch {
            // Roll UI back to the last durable state instead of displaying an unsaved success.
            if let saved = SharedStore.shared.read("workspace.json", as: WorkspaceState.self) { workspace = saved }
            notice = "保存工作区失败：\(error.localizedDescription)"
            return false
        }
    }
    func initializeWorkspace() {
        guard storageWarning == nil else { return }
        let store = SharedStore.shared
        let lease = store.read("lease.json", as: ExecutionLease.self)
        let current = store.command
        let hasValidLease = lease?.sessionID == current?.id && (lease?.expiresAt ?? .distantPast) > Date()
        if !hasValidLease {
            store.remove("frame.json"); store.remove("lease.json")
            if store.configuration.continuedProcessingEnabled == true, var command = current, command.running {
                try? store.updateCommand(sessionID: command.id) { $0.running = false }
            }
        }
        if workspace.profiles.isEmpty {
            let profile = ModelProfile(name: "我的默认模型", configuration: configuration)
            workspace.profiles = [profile]
            workspace.selectedProfileID = profile.id
            persistWorkspace()
        }
        // Reopening never resumes task side effects. Existing broadcast control remains explicit.
        for index in workspace.tasks.indices where workspace.tasks[index].state == "运行中" {
            workspace.tasks[index].state = "待确认"
        }
        persistWorkspace()
    }
    @discardableResult
    func saveCurrentProfile(name: String? = nil, asNew: Bool = false) -> Bool {
        if asNew && workspace.profiles.count >= 12 { notice = "最多保存12个模型档案"; return false }
        let previousSelection = workspace.selectedProfileID
        if asNew { workspace.selectedProfileID = nil }
        guard save() else { workspace.selectedProfileID = previousSelection; return false }
        if !asNew, let index = workspace.profiles.firstIndex(where: { $0.id == workspace.selectedProfileID }) {
            workspace.profiles[index].configuration = configuration
            if let name, !name.isEmpty { workspace.profiles[index].name = String(name.prefix(60)) }
        } else {
            guard workspace.profiles.count < 12 else { notice = "最多保存12个模型档案"; return false }
            let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = ModelProfile(name: String((trimmed.isEmpty ? "新模型档案" : trimmed).prefix(60)), configuration: configuration)
            workspace.profiles.append(profile); workspace.selectedProfileID = profile.id
        }
        guard persistWorkspace() else { return false }
        notice = "档案已保存；密钥仍只保留在Keychain。"
        return true
    }
    func configureGateway(name: String, endpoint: String, modelID: String, key: String, visionConfirmed: Bool) {
        guard !isSessionActive, visionConfirmed, !modelID.isEmpty else { notice = "请填写视觉模型并确认网关图片能力，运行中不能切换。"; return }
        do { _ = try AddressPolicy.ai(endpoint) } catch { notice = error.localizedDescription; return }
        guard workspace.profiles.count < 12 else { notice = "模型档案已达12个"; return }
        configuration.provider = "openai"; configuration.endpoint = endpoint
        configuration.model = modelID; configuration.gatewayVisionConfirmed = true
        configuration.uploadConsent = false; configuration.allowLowRiskNavigation = false
        apiKey = key
        guard saveCurrentProfile(name: name, asNew: true) else { return }
        notice = "网关档案已配置，未发起网络连接。核对网关的数据去向后，再单独同意屏幕上传。"
    }
    func selectProfile(_ profile: ModelProfile) {
        guard !isSessionActive else { notice = "请先停止会话再切换模型"; return }
        var candidate = profile.configuration
        // Upload consent is fresh for each endpoint switch, even when a profile previously had consent.
        candidate.uploadConsent = false
        configuration = candidate
        lastDeviceStatus = nil; deviceSummary = "档案已切换，请重新检查设备"
        apiKey = ""; deviceToken = ""
        workspace.selectedProfileID = profile.id
        if save() { notice = "已切换到\(profile.name)。请核对端点并重新同意截图上传。" }
    }
    func removeProfile(_ profile: ModelProfile) {
        guard !isSessionActive else { return }
        workspace.profiles.removeAll { $0.id == profile.id }
        if workspace.selectedProfileID == profile.id { workspace.selectedProfileID = nil }
        guard persistWorkspace() else { return }
        notice = "已移除档案；按端点存储的Keychain凭据未删除。需要时先选中该端点再删除密钥。"
    }
    func saveTaskToQueue() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { notice = "先写下任务"; return }
        guard workspace.tasks.count < 100 else { notice = "任务库已达100条，请先删除不需要的记录"; return }
        workspace.tasks.append(SavedTask(text: String(text.prefix(2000))))
        guard persistWorkspace() else { return }
        notice = "已加入待办。下一项需要你手动准备和开始广播。"
    }
    func loadTask(_ record: SavedTask) {
        guard !isSessionActive else { notice = "请先停止当前会话"; return }
        task = record.text
        selectedTaskID = record.id
        notice = "已载入任务。未恢复任何旧动作；需重新ARM并开始新会话。"
    }
    func removeTask(_ id: String) {
        guard workspace.tasks.first(where: { $0.id == id })?.sessionID != SharedStore.shared.command?.id || !isSessionActive else { return }
        workspace.tasks.removeAll { $0.id == id }
        if persistWorkspace(), selectedTaskID == id { selectedTaskID = nil }
    }
    func markTask(_ id: String, completed: Bool) {
        guard let index = workspace.tasks.firstIndex(where: { $0.id == id }), !(isSessionActive && workspace.tasks[index].sessionID == SharedStore.shared.command?.id) else { notice = "当前会话仍在运行，请先停止"; return }
        workspace.tasks[index].state = completed ? "已人工确认完成" : "待办"
        if !completed { workspace.tasks[index].sessionID = nil }
        workspace.tasks[index].updatedAt = Date(); persistWorkspace()
    }
    func recordSession(_ command: SessionCommand) throws {
        if let id = selectedTaskID, let index = workspace.tasks.firstIndex(where: { $0.id == id }) {
            workspace.tasks[index].text = command.task; workspace.tasks[index].state = "运行中"
            workspace.tasks[index].sessionID = command.id; workspace.tasks[index].updatedAt = Date()
        } else {
            var record = SavedTask(text: command.task)
            record.state = "运行中"; record.sessionID = command.id
            workspace.tasks.append(record); selectedTaskID = record.id
            if workspace.tasks.count > 100 { workspace.tasks.removeFirst() }
        }
        guard persistWorkspace() else { throw PilotError.message(notice) }
    }
    func syncTaskStatus() {
        guard let index = workspace.tasks.firstIndex(where: { $0.sessionID == status.sessionID }) else { return }
        guard workspace.tasks[index].state != "待办" else { return }
        let state = SharedStore.shared.command?.running != true ? "待确认" : status.phase == "暂停" ? "待人工处理" : status.phase == "停止" ? "待确认" : "运行中"
        guard workspace.tasks[index].state != "已人工确认完成", workspace.tasks[index].state != state || workspace.tasks[index].steps != status.steps else { return }
        workspace.tasks[index].state = state; workspace.tasks[index].steps = status.steps
        workspace.tasks[index].updatedAt = Date(); persistWorkspace()
    }
    func readiness() -> [ReadinessItem] {
        let keyAvailable = (try? SecretStore.load(configuration.apiAccount)) != nil
        let deviceKeyAvailable = (try? SecretStore.load(configuration.deviceAccount)) != nil
        return [
            .init(id: "group", title: "共享存储与签名", passed: SharedStore.shared.available, detail: "App Group可访问；扩展是否能访问仍需广播验收。"),
            .init(id: "model", title: "视觉模型与API凭据", passed: !configuration.model.isEmpty && keyAvailable, detail: "只检查本地配置与Keychain可读性，不宣称API已验证。"),
            .init(id: "device", title: "设备Token", passed: deviceKeyAvailable, detail: "与固件Token一致，存于Keychain。"),
            .init(id: "network", title: "局域网与BLE", passed: lastDeviceStatus?.hid_connected == true, detail: deviceSummary),
            .init(id: "arm", title: "物理ARM", passed: lastDeviceStatus?.armed == true, detail: "状态是最近一次检查快照，随时可能失效。"),
            .init(id: "pointer", title: "相对指针校准", passed: configuration.relativeModeConfirmed, detail: "必须人工观察方向与当前指针，截图可见性尚需真机检查。"),
            .init(id: "consent", title: "屏幕上传同意", passed: configuration.uploadConsent, detail: "将发给当前端点；进入敏感页面前停止广播。")]
    }
    func exportSettings() throws -> Data {
        guard !isSessionActive else { throw PilotError.message("请先停止会话再导出设置") }
        var profiles = workspace.profiles
        if let index = profiles.firstIndex(where: { $0.id == workspace.selectedProfileID }) { profiles[index].configuration = configuration }
        for i in profiles.indices {
            profiles[i].configuration.uploadConsent = false
            profiles[i].configuration.relativeModeConfirmed = false
            profiles[i].configuration.allowLowRiskNavigation = false
            profiles[i].configuration.gatewayVisionConfirmed = false
            profiles[i].configuration.continuedProcessingEnabled = false
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SettingsArchive(profiles: profiles))
    }
    func importSettings(_ url: URL) {
        guard !isSessionActive else { notice = "请先停止会话再导入"; return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 100_000 else { throw PilotError.message("设置文件超过100KB") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 100_000 else { throw PilotError.message("设置文件过大") }
            let archive = try JSONDecoder().decode(SettingsArchive.self, from: data)
            guard archive.format == "HIDPilot-settings", archive.version == 1, !archive.profiles.isEmpty,
                  archive.profiles.count + workspace.profiles.count <= 12 else { throw PilotError.message("格式/版本不支持，或导入后超过12个档案") }
            var sanitized: [ModelProfile] = []
            for var profile in archive.profiles {
                _ = try AddressPolicy.ai(profile.configuration.endpoint)
                _ = try AddressPolicy.device(profile.configuration.deviceURL)
                guard ["responses", "openai", "anthropic", "gemini"].contains(profile.configuration.provider),
                      profile.name.count <= 60, profile.configuration.model.count <= 200,
                      profile.configuration.calibrationX.isFinite, profile.configuration.calibrationY.isFinite,
                      profile.configuration.frameInterval.isFinite, profile.configuration.maxFrameAge.isFinite else { throw PilotError.message("导入配置包含无效参数") }
                profile.id = UUID().uuidString
                profile.configuration.uploadConsent = false; profile.configuration.relativeModeConfirmed = false
                profile.configuration.allowLowRiskNavigation = false
                profile.configuration.gatewayVisionConfirmed = false
                profile.configuration.continuedProcessingEnabled = false
                try profile.configuration.validate()
                profile.configuration.maxSteps = min(50, max(1, profile.configuration.maxSteps))
                profile.configuration.frameInterval = min(30, max(2, profile.configuration.frameInterval))
                profile.configuration.maxFrameAge = min(20, max(3, profile.configuration.maxFrameAge))
                sanitized.append(profile)
            }
            workspace.profiles.append(contentsOf: sanitized)
            guard persistWorkspace() else { return }
            notice = "导入完成，未激活档案或授权截图。请选择档案，核对端点，重新配置密钥/校准/同意。"
        } catch { notice = "导入失败：\(error.localizedDescription)" }
    }
    func exportDiagnostics() throws -> Data {
        // Deliberately exclude tasks, API keys, tokens, URLs, hostnames, model names, and raw log text.
        let report: [String: Any] = ["format": "HIDPilot-redacted-diagnostics", "version": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "phase": status.phase, "steps": status.steps, "status_age_seconds": max(0, Int(Date().timeIntervalSince(status.updatedAt))),
            "app_group_accessible": SharedStore.shared.available, "provider_protocol": configuration.provider,
            "has_api_credential": (try? SecretStore.load(configuration.apiAccount)) != nil,
            "has_device_credential": (try? SecretStore.load(configuration.deviceAccount)) != nil,
            "upload_consent": configuration.uploadConsent, "relative_calibrated": configuration.relativeModeConfirmed,
            "automatic_navigation": configuration.allowLowRiskNavigation,
            "last_observed_ble_connected": lastDeviceStatus?.hid_connected ?? false,
            "last_observed_armed": lastDeviceStatus?.armed ?? false,
            "recovery_category": recovery.title,
            "build_test_status": "iOS application build/runtime not verified; consult packaged Linux verification report"]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }
}
