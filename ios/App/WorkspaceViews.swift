import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WorkspaceHubView: View {
    @EnvironmentObject private var model: PilotViewModel
    @State private var showOnboarding = false
    @State private var showProfiles = false
    @State private var showTasks = false
    @State private var showTransfer = false
    @State private var confirmRecovery = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("模型档案 · \(model.selectedProfileName)", systemImage: "square.stack.3d.up") { showProfiles = true }
                    Button("设置迁移与脱敏诊断", systemImage: "square.and.arrow.up") { showTransfer = true }
                }
                Section("恢复建议") {
                    Text(model.recovery.title).font(.headline)
                    Text(model.recovery.steps).font(.callout)
                    Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let warning = model.storageWarning {
                    Section("本地数据恢复") {
                        Text(warning).foregroundStyle(.orange)
                        Button("保留旧文件副本并重置工作区", role: .destructive) { confirmRecovery = true }.disabled(model.stopping)
                    }
                }
                Section("构建状态") {
                    Text("功能源码正在完善。Linux可做的检查与iPhone实际验证不同；此界面不代表已通过iOS编译或真机验收。").font(.caption)
                }
            }.navigationTitle("高级与数据")
                .sheet(isPresented: $showOnboarding) { OnboardingView() }
                .sheet(isPresented: $showProfiles) { ProfilesView() }
                .sheet(isPresented: $showTasks) { TaskLibraryView() }
                .sheet(isPresented: $showTransfer) { TransferView() }
                .confirmationDialog("停止会话并重置配置与任务库？", isPresented: $confirmRecovery, titleVisibility: .visible) {
                    Button("保留旧文件副本并重置", role: .destructive) { Task { await model.recoverDamagedSettings() } }
                } message: { Text("旧文件会保留在本机App Group恢复副本中。当前任务库和配置恢复默认，密钥不删除。请先结束系统广播并核实硬件停止。") }
        }
    }
}

/// Four focused pages. Completing the introduction grants no device or upload permission.
struct OnboardingView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var showDevice = false
    @State private var showAI = false
    @State private var showCalibration = false
    private let titles = ["把目标交给 SightLatch", "先连接你的设备", "选择你的 AI", "开始之前，留好退路"]
    private let symbols = ["bubble.left.and.text.bubble.right", "antenna.radiowaves.left.and.right", "sparkles", "hand.raised"]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("第 \(step + 1) 步，共 4 步").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(0..<4) { index in
                            Capsule().fill(index <= step ? Color.primary : Color(.tertiarySystemFill)).frame(height: 3)
                        }
                    }.accessibilityHidden(true)
                    if step == 1 {
                        PilotConnectionIllustration().padding(.top, 8)
                    } else {
                        Image(systemName: symbols[step]).font(.system(size: 44, weight: .light)).accessibilityHidden(true)
                            .padding(.top, 20)
                    }
                    Text(titles[step]).font(.largeTitle.bold())
                    pageContent
                }.frame(maxWidth: 540, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
            .background(PilotPalette.canvas)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if step < 3 { step += 1 }
                    else {
                        model.workspace.onboardingComplete = true
                        if model.persistWorkspace() { dismiss() }
                    }
                } label: {
                    Text(step == 3 ? "我已了解，进入聊天" : "继续")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(PilotPalette.accent)
                    .padding(24).background(PilotPalette.canvas)
            }
            .navigationTitle("开始使用").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 { Button("返回") { step -= 1 } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("稍后设置") { dismiss() } }
            }
            .sheet(isPresented: $showDevice) { DeviceSettingsView() }
            .sheet(isPresented: $showAI) { ConfigurationDetailView(safety: false) }
            .sheet(isPresented: $showCalibration) { CalibrationView() }
        }
    }
    @ViewBuilder private var pageContent: some View {
        switch step {
        case 0:
            Text("先描述目标，AI 会给出简短计划。你明确允许后，才申请屏幕广播与设备控制。")
                .font(.title3)
            Text("SightLatch 通过你主动开启的系统广播观察屏幕，再通过 ESP32 蓝牙鼠标操作 iPhone。默认不自动点击；模型不能替你保证安全。")
                .foregroundStyle(.secondary)
        case 1:
            Text("ESP32 需要 USB 供电，并和 iPhone 连接同一可信 Wi-Fi。")
                .font(.title3)
            Text("在设备设置填地址与 Token，检查连接，再按提示在系统蓝牙中配对。局域网权限由真实连接请求触发；App 不会替你确认系统权限。HTTP 会明文传输 Token 与指令，请使用可信隔离网络。")
                .foregroundStyle(.secondary)
            Button("打开设备设置", systemImage: "network") { showDevice = true }.buttonStyle(.bordered)
        case 2:
            Text("连接 AI 账户，确认屏幕截图交给谁。")
                .font(.title3)
            Text("广播会持续发送跨 App 截图，服务方可能保留图像。上传同意需要你在 AI 账户页主动开启，系统广播还需单独确认。ChatGPT 套餐和 API 计费是独立路径。")
                .foregroundStyle(.secondary)
            Button("设置 AI 与上传同意", systemImage: "sparkles") { showAI = true }.buttonStyle(.bordered)
        default:
            Text("先校准指针，再从安全页面尝试一个小任务。")
                .font(.title3)
            Button("打开指针校准", systemImage: "scope") { showCalibration = true }.buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 16) {
                Label("运行时，发送按钮会变为停止。设备设置始终有紧急停止。", systemImage: "stop.circle")
                Label("密码、付款、医疗等敏感页面前，先结束系统广播。", systemImage: "rectangle.slash")
                Label("软件停止未确认时，按物理 STOP 或拔掉 USB 电源。不要无人值守。", systemImage: "powerplug")
            }.font(.callout)
            Text("完成介绍只进入聊天，不会自动授予权限、开始广播或控制设备。未完成的准备会在开始任务时检查。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A small settings map, with one authoritative location for each setting.
struct SettingsView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Destination?
    private enum Destination: String, Identifiable {
        case device, ai, safety, workspace, onboarding
        var id: String { rawValue }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("设置").font(.largeTitle.bold()).padding(.top, 12)
                    VStack(spacing: 0) {
                        settingsRow("设备", subtitle: "连接与配对", symbol: "computermouse", destination: .device)
                        Divider().padding(.leading, 62)
                        settingsRow("AI 账户", subtitle: "模型与任务文字", symbol: "person.crop.circle", destination: .ai)
                        Divider().padding(.leading, 62)
                        settingsRow("权限与安全", subtitle: "屏幕上传与操作范围", symbol: "hand.raised", destination: .safety)
                    }.background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 28))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("通用").font(.subheadline).foregroundStyle(.secondary).padding(.leading, 4)
                        VStack(spacing: 0) {
                            HStack(spacing: 16) {
                                Image(systemName: "circle.lefthalf.filled").font(.title3).frame(width: 28)
                                Picker("外观", selection: $model.workspace.theme) {
                                    Text("跟随系统").tag("system")
                                    Text("浅色").tag("light")
                                    Text("深色").tag("dark")
                                }.onChange(of: model.workspace.theme) { _, _ in model.persistWorkspace() }
                            }.padding(20)
                            Divider().padding(.leading, 62)
                            settingsRow("高级与数据", symbol: "archivebox", destination: .workspace)
                            Divider().padding(.leading, 62)
                            settingsRow("使用指南", symbol: "book.closed", destination: .onboarding)
                        }.background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 28))
                    }
                    Text("广播截图会交给你选择的 AI 服务。进入敏感页面前，先结束系统广播。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(PilotPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { PilotCloseButton { dismiss() } } }
            .sheet(item: $destination) { destination in
                switch destination {
                case .device: DeviceSettingsView()
                case .ai: ConfigurationDetailView(safety: false)
                case .safety: ConfigurationDetailView(safety: true)
                case .workspace: WorkspaceHubView()
                case .onboarding: OnboardingView()
                }
            }
        }
    }
    private func settingsRow(_ title: String, subtitle: String? = nil, symbol: String, destination target: Destination) -> some View {
        Button { destination = target } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 38).padding(20).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ProfilesView: View {
    @EnvironmentObject private var model: PilotViewModel
    @State private var name = ""
    @State private var deleting: ModelProfile?
    @State private var showGateway = false
    @State private var showSettings = false
    var body: some View {
        NavigationStack {
            List {
                Section("已保存的模型") {
                    ForEach(model.workspace.profiles) { profile in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(profile.name).font(.headline)
                                if profile.id == model.workspace.selectedProfileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal).accessibilityLabel("当前档案") }
                            }
                            Text("\(profile.configuration.provider) · \(profile.configuration.model.isEmpty ? "尚未设置模型" : profile.configuration.model)").font(.caption).foregroundStyle(.secondary)
                            Text(URL(string: profile.configuration.endpoint)?.host ?? "无效端点").font(.caption).textSelection(.enabled)
                            HStack {
                                Button("切换并重新确认上传") { model.selectProfile(profile) }.disabled(model.isSessionActive)
                                Spacer()
                                Button("移除", role: .destructive) { deleting = profile }.disabled(model.isSessionActive)
                            }.font(.caption).buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
                Section { Button("配置自管兼容网关", systemImage: "point.3.connected.trianglepath.dotted") { showGateway = true }.disabled(model.isSessionActive) }
                Section("保存当前配置") {
                    TextField("档案名称", text: $name)
                    Button("更新当前档案") { model.saveCurrentProfile(name: name) }
                    Button("另存为新档案") { model.saveCurrentProfile(name: name, asNew: true) }
                    Button("编辑当前模型与密钥") { showSettings = true }
                }.disabled(model.isSessionActive)
                Section("兼容网关与凭据") {
                    Text("自管网关使用OpenAI兼容协议，填写完整HTTPS chat/completions URL。上游订阅授权、图片支持和条款由网关负责；本App没有假冒的ChatGPT/Codex OAuth入口。")
                    Text("每个provider+端点共享一项Keychain凭据；不同模型使用同一端点时也共用该密钥。移除档案不会自动删除可能被其他档案使用的密钥。")
                    Text(model.notice).foregroundStyle(.secondary)
                }.font(.caption)
            }.navigationTitle("模型档案")
                .sheet(isPresented: $showGateway) { GatewaySetupView() }
                .sheet(isPresented: $showSettings) { ConfigurationDetailView(safety: false) }
                .confirmationDialog("移除这个配置档案？Keychain凭据会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("移除档案", role: .destructive) { if let deleting { model.removeProfile(deleting) }; deleting = nil }
                }
        }
    }
}

struct TaskLibraryView: View {
    @EnvironmentObject private var model: PilotViewModel
    @State private var filter = "待办"
    @State private var deleting: SavedTask?
    private var records: [SavedTask] {
        model.workspace.tasks.filter { filter == "全部" || (filter == "待办" ? $0.state == "待办" : $0.state != "待办") }
            .sorted { filter == "待办" ? $0.createdAt < $1.createdAt : $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("显示", selection: $filter) { Text("待办队列").tag("待办"); Text("历史").tag("历史"); Text("全部").tag("全部") }.pickerStyle(.segmented)
                    Text("队列按创建时间排列。每项都需要你手动载入、确认和启动；应用重开、暂停或上项结束不会自动执行下一项。").font(.caption).foregroundStyle(.secondary)
                    Button("把主页当前任务加入待办", systemImage: "plus") { model.saveTaskToQueue() }
                }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.text).lineLimit(4).textSelection(.enabled)
                        Text("\(record.state) · \(record.steps)步 · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("载入") { model.loadTask(record) }.disabled(model.isSessionActive)
                            Menu("管理") {
                                Button("我已确认实际完成") { model.markTask(record.id, completed: true) }
                                Button("移回待办（不执行）") { model.markTask(record.id, completed: false) }
                                Button("删除记录", role: .destructive) { deleting = record }
                            }.disabled(record.state == "运行中")
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
                if records.isEmpty { ContentUnavailableView("暂无记录", systemImage: "tray", description: Text("在主页写下任务，然后加入待办。")) }
                Section { Text(model.notice).font(.caption) }
            }.navigationTitle("任务库")
                .confirmationDialog("删除这条任务和历史？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除", role: .destructive) { if let deleting { model.removeTask(deleting.id) }; deleting = nil }
                }
        }
    }
}

struct TransferView: View {
    @EnvironmentObject private var model: PilotViewModel
    @State private var document = JSONDocument()
    @State private var exporting = false
    @State private var importing = false
    @State private var filename = "SightLatch-settings"
    @State private var exportError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("设置文件") {
                    Text("仅导出模型档案与非秘密配置。包含端点和局域网主机地址；不包含API Key、设备Token、任务或截图。上传同意、自动点击与校准确认在文件中重置。").font(.caption)
                    Button("导出非秘密设置", systemImage: "square.and.arrow.up") {
                        do { document = JSONDocument(data: try model.exportSettings()); filename = "SightLatch-settings"; exporting = true }
                        catch { exportError = error.localizedDescription }
                    }.disabled(model.isSessionActive)
                    Button("导入设置（不会自动激活）", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.isSessionActive)
                }
                Section("脱敏诊断") {
                    Text("包含系统版本、协议类别、阶段/步数、凭据是否存在、最近BLE/ARM状态；不含密钥、端点、模型名、任务、原始日志或截图。不会自动上传，请先查看再自行分享。").font(.caption)
                    Button("导出脱敏诊断 JSON", systemImage: "doc.text.magnifyingglass") {
                        do { document = JSONDocument(data: try model.exportDiagnostics()); filename = "SightLatch-diagnostics"; exporting = true }
                        catch { exportError = error.localizedDescription }
                    }
                }
                if let exportError { Section("提示") { Text(exportError).textSelection(.enabled) } }
                Section { Text(model.notice).font(.caption) }
            }.navigationTitle("迁移与诊断")
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: filename) { result in
                    switch result {
                    case .success: model.notice = "文件已交给系统保存；未发送到任何外部服务。"
                    case .failure(let error): exportError = error.localizedDescription
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url): model.importSettings(url)
                    case .failure(let error): exportError = error.localizedDescription
                    }
                }
        }
    }
}

struct GatewaySetupView: View {
    @EnvironmentObject private var model: PilotViewModel
    @State private var name = "我的兼容网关"
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var visionConfirmed = false
    var body: some View {
        NavigationStack {
            Form {
                Section("自管OpenAI兼容网关") {
                    Text("填写你自己部署或明确信任的网关。CLIProxyAPI等项目存在订阅认证适配，但这不是本App内置的官方登录；本App不读取浏览器Cookie、不复制订阅令牌，也不代你登录。").font(.caption)
                    TextField("档案名称", text: $name)
                    TextField("完整HTTPS chat/completions URL", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("网关暴露的视觉模型ID", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("网关API Key（不是浏览器Cookie）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("我已确认图片输入能力和此用途的授权/条款", isOn: $visionConfirmed)
                }
                Section("数据与费用") {
                    Text("屏幕图像先到网关，再可能转发至上游模型。确认网关运营者、数据保留、订阅/API使用限制和费用后再开启上传。仅配置不会联网或发送截图。HTTP公网、自签名证书绕过和自动订阅登录均未提供。").font(.caption)
                    Button("保存为独立网关档案") {
                        model.configureGateway(name: name, endpoint: endpoint, modelID: modelID, key: key, visionConfirmed: visionConfirmed)
                        key = ""
                    }.disabled(model.isSessionActive || endpoint.isEmpty || modelID.isEmpty || !visionConfirmed)
                    Text(model.notice).font(.caption).textSelection(.enabled)
                }
            }.navigationTitle("兼容网关")
        }
    }
}
