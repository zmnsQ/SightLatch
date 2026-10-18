import SwiftUI
import ReplayKit

struct HomeView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var shortcutRouter = PilotShortcutRouter.shared
    @State private var showSettings = false
    @State private var showDeviceSettings = false
    @State private var showCalibration = false
    @State private var showWorkspace = false
    @State private var showOnboarding = false
    @State private var confirmResume = false
    @State private var showExecution = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    deviceConnection
                    if let command = SharedStore.shared.command {
                        HStack {
                            Spacer(minLength: 36)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text("你").font(.caption).foregroundStyle(.secondary)
                                Text(command.task).textSelection(.enabled)
                                    .padding(16).background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                            }
                        }
                        if model.status.sessionID == command.id {
                            assistantMessage
                        } else {
                            Text("尚无这条指令的执行结果，请查看下方状态提示。")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Image("BrandMark").resizable().scaledToFit().frame(width: 52, height: 52).accessibilityHidden(true)
                            Text("今天想完成什么？").font(.largeTitle.bold())
                            Text("输入或说出目标。开始后，这里会显示观察、操作和结果，你可以随时停止。")
                                .foregroundStyle(.secondary)
                            Button("第一次使用：连接与校准", systemImage: "scope") { showOnboarding = true }
                                .buttonStyle(.bordered)
                        }.padding(.vertical, 36)
                    }
                    if !model.notice.isEmpty {
                        Label(model.notice, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("广播会将截图交给所选服务。敏感页面前先停止广播；软件停止未确认时，拔掉设备 USB 电源。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(Color(.systemBackground))
            .navigationTitle("SightLatch").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("工作区", systemImage: "sidebar.left") { showWorkspace = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("连接与模型", systemImage: "slider.horizontal.3") { showSettings = true }
                        Button("设备设置", systemImage: "antenna.radiowaves.left.and.right") { showDeviceSettings = true }
                        Button("指针校准", systemImage: "scope") { showCalibration = true }
                        Button("保存到待办队列", systemImage: "text.badge.plus") { model.saveTaskToQueue() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("设置与更多操作")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .sheet(isPresented: $showDeviceSettings) { DeviceSettingsView() }
            .sheet(isPresented: $showWorkspace) { WorkspaceHubView() }
            .sheet(isPresented: $showOnboarding) { OnboardingView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .onAppear {
                showOnboarding = !model.workspace.onboardingComplete
                receiveShortcut()
            }
            .onOpenURL { url in
                guard url.scheme == "sightlatch", url.host == "chat" else { return }
                showSettings = false; showDeviceSettings = false; showCalibration = false
                showWorkspace = false; showOnboarding = false
                // Deep links only reveal chat. They never send a task or grant control.
            }
            .onChange(of: shortcutRouter.pendingRequest?.id) { _, _ in receiveShortcut() }
            .onChange(of: showOnboarding) { _, shown in if !shown { receiveShortcut() } }
            .onChange(of: model.isSessionActive) { _, active in if !active { receiveShortcut() } }
            .confirmationDialog("确认已在目标 App 人工完成或取消提案，并检查风险？", isPresented: $confirmResume, titleVisibility: .visible) {
                Button("已人工处理，重新观察新画面") { model.resumeAfterManual() }
            } message: {
                Text("不会执行旧动作，也不会自动授权设备。授权已失效时，先停止，再点开始接管。")
            }
        }
    }
    private var deviceConnection: some View {
        Button { showDeviceSettings = true } label: {
            HStack(spacing: 8) {
                Image(systemName: model.deviceStatusIsFresh ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                Text(model.deviceSummary).font(.caption).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.bold())
            }.foregroundStyle(.secondary).padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityHint("打开设备连接与配对设置")
    }
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 26, height: 26).accessibilityHidden(true)
                Text("SightLatch").font(.subheadline.bold())
                Spacer()
                Text(model.status.phase).font(.caption).foregroundStyle(.secondary)
            }
            // Actual application state/result only; no invented assistant transcript.
            Text(model.status.detail).textSelection(.enabled)
            Text("第 \(model.status.steps) 步 · \(model.status.updatedAt.formatted(date: .omitted, time: .standard)) · 状态可能过期")
                .font(.caption).foregroundStyle(.secondary)
            if model.status.phase == "暂停" {
                Text(model.recovery.steps).font(.callout).foregroundStyle(.secondary)
                if model.configuration.continuedProcessingEnabled != true {
                    Button("我已手动处理，继续观察") { confirmResume = true }.buttonStyle(.bordered)
                }
            }
            DisclosureGroup("执行过程 · \(currentSessionLogs.count)", isExpanded: $showExecution) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("仅显示本次会话的观察、工具操作与结果摘要。")
                        .font(.caption).foregroundStyle(.secondary)
                    if currentSessionLogs.isEmpty { Text("尚无执行记录").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(currentSessionLogs.suffix(20))) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.message).font(.callout).textSelection(.enabled)
                            Text(item.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 12)
            }.font(.subheadline)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var composer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("给 SightLatch 一个目标…", text: $model.task, axis: .vertical)
                    .lineLimit(1...5).padding(.vertical, 12).disabled(model.isSessionActive)
                    .accessibilityLabel("任务消息")
                VoiceTaskComposer(text: $model.task).disabled(model.isSessionActive)
            }.padding(.horizontal, 16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
            if model.prepared {
                Text("点屏幕广播，并在系统提示中确认。开始后可返回目标 App。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if #available(iOS 26.0, *), !reduceTransparency {
                GlassEffectContainer(spacing: 12) { controlLayout }
            } else {
                controlLayout
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
    }
    @ViewBuilder private var controlLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) { controlButtons }
        } else {
            HStack(spacing: 12) { controlButtons }
        }
    }
    @ViewBuilder private var controlButtons: some View {
        Button { Task { await model.prepare() } } label: {
            Label(model.preparing ? "准备中" : "开始接管", systemImage: "arrow.up")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
        }.tint(.teal).pilotAction(prominent: true)
            .disabled(model.isSessionActive || model.probing || model.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if model.prepared {
            VStack(spacing: 2) {
                BroadcastPicker().frame(width: 44, height: 44)
                Text("屏幕广播").font(.caption2)
            }.accessibilityElement(children: .contain)
        }
        Button { Task { await model.stop() } } label: {
            Label(model.stopping ? "停止中" : "停止控制", systemImage: "stop.fill")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
        }.tint(.red).pilotAction(prominent: false)
            .accessibilityLabel("停止控制并撤销设备授权").disabled(model.stopping)
    }
    private var currentSessionLogs: [LogEntry] {
        model.logs.filter { $0.sessionID == model.status.sessionID }
    }
    private func receiveShortcut() {
        guard !showOnboarding, !model.isSessionActive, let request = shortcutRouter.consume() else { return }
        if let task = request.task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.task = task }
        if request.startVoice { shortcutRouter.activateVoiceRequest() }
        // Filling the composer never starts control or ReplayKit broadcasting.
    }
}

struct DeviceSettingsView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("局域网连接") {
                    Group {
                        TextField("http://hidbridge.local", text: $model.configuration.deviceURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("设备 Bearer Token", text: $model.deviceToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.disabled(model.isSessionActive || model.probing)
                    Text("仅在可信隔离 Wi-Fi 使用；HTTP 会明文传输设备 token 与控制命令。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { DeviceControlPanel().buttonStyle(.bordered) }
                Section { Text(model.notice).font(.footnote) }
            }
            .navigationTitle("设备设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: model.configuration.deviceURL) { _, _ in
                model.lastDeviceStatus = nil
                model.deviceStatusCheckedAt = nil
                model.deviceSummary = "设备地址已修改，请重新检查"
                model.configuration.relativeModeConfirmed = false
            }
        }
    }
}

// Shared device control surface. STOP stays available while ARM/PAIR is in flight.
struct DeviceControlPanel: View {
    @EnvironmentObject private var model: PilotViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("设备连接与控制", systemImage: "network").font(.headline)
            Text(model.deviceSummary).font(.caption)
            if let checkedAt = model.deviceStatusCheckedAt, model.deviceStatusIsFresh {
                Text("检查于 \(checkedAt.formatted(date: .omitted, time: .standard)) · 前台定期刷新，状态可能随时变化")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("检查设备状态") { Task { await model.probe() } }
                .disabled(model.isSessionActive || model.probing)
            if model.softwareControlAvailable {
                Button("开始蓝牙配对") { Task { await model.requestDeviceControl(pairing: true) } }
                    .disabled(model.isSessionActive || model.probing || model.lastDeviceStatus?.hid_connected == true)
                Button("允许控制5分钟（用于手动校准）") { Task { await model.requestDeviceControl(pairing: false) } }
                    .disabled(model.isSessionActive || model.probing || model.lastDeviceStatus?.hid_connected != true || model.lastDeviceStatus?.armed == true)
                Text("首次点配对后，在系统设置连接 SightLatch。平时点下方开始接管即可申请控制；已有授权不会续期。配对窗口30秒，授权最多5分钟，断连或重启后需重新主动开始。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.deviceStatusIsFresh {
                Text("此固件使用物理控制，或未声明软件控制能力。请按设备 ARM / STOP 操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("停止控制", role: .destructive) { Task { await model.stop() } }.disabled(model.stopping)
            Text("USB 供电；App 经 Wi-Fi 发送命令，设备经 BLE HID 操作手机。软件停止若失败，请拔掉 USB 电源。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".Broadcast" }
        picker.showsMicrophoneButton = false
        picker.accessibilityLabel = "系统屏幕广播按钮"
        picker.accessibilityHint = "选择SightLatch Broadcast后，由系统确认开始屏幕广播"
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

private struct PilotGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(.secondarySystemBackground), in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
private struct PilotActionStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}
extension View {
    func pilotGlass() -> some View { modifier(PilotGlassSurface()) }
    func pilotAction(prominent: Bool) -> some View { modifier(PilotActionStyle(prominent: prominent)) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false
    var body: some View {
        NavigationStack {
            Form {
                ChatGPTSettingsSection(model: model)
                Section("模型服务") {
                    Picker("协议", selection: $model.configuration.provider) {
                        Text("ChatGPT 套餐").tag("chatgpt-plan")
                        Text("OpenAI Responses").tag("responses")
                        Text("OpenAI 兼容 Chat Completions").tag("openai")
                        Text("Anthropic Messages").tag("anthropic")
                        Text("Google Gemini generateContent").tag("gemini")
                    }
                    if model.configuration.provider != "chatgpt-plan" {
                    TextField("完整 HTTPS 请求 URL", text: $model.configuration.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("支持视觉的模型 ID", text: $model.configuration.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key（空白保留已有值）", text: $model.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("OpenAI: /v1/responses\n兼容网关: /v1/chat/completions\nAnthropic: https://api.anthropic.com/v1/messages\nGemini: https://generativelanguage.googleapis.com/v1beta/models/模型ID:generateContent\nGemini 模型以 URL 中的 ID 为准。模型是否支持截图、计费和数据保留由供应商决定。").font(.caption)
                    if model.configuration.provider == "openai" {
                        Toggle("确认此兼容端点与模型支持图片，且我获准用于此用途", isOn: Binding(get: { model.configuration.gatewayVisionConfirmed == true }, set: { model.configuration.gatewayVisionConfirmed = $0 }))
                    }
                    }
                    Toggle("同意将广播中的屏幕截图发给所选服务", isOn: $model.configuration.uploadConsent)
                    Text("会持续发送跨 App 截图；服务方可能保留图像。系统广播许可与此上传同意是两回事。撤回后请立即停止会话。ChatGPT 套餐与 API Key 是独立路径；不会静默切换到 API 计费。").font(.caption).foregroundStyle(.secondary)
                }
                Section("ESP32 · 仅可信隔离局域网") {
                    TextField("http://hidbridge.local", text: $model.configuration.deviceURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("设备 Bearer Token", text: $model.deviceToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存并检查局域网 / BLE") { Task { await model.probe() } }
                    Text("HTTP 为明文，Token 和指令可被同网攻击者窃听。没有远程中转控制服务。Token 需与你的固件配置相同。").font(.caption).foregroundStyle(.secondary)
                }
                Section("可选后台协调 · iOS26") {
                    if #available(iOS 26.0, *) {
                        Toggle("启用有界后台会话并同意临时本地存帧", isOn: Binding(get: { model.configuration.continuedProcessingEnabled == true }, set: { model.configuration.continuedProcessingEnabled = $0 }))
                    }
                    Text("默认由广播扩展直接处理AI与硬件。可选模式通过系统BGContinuedProcessingTask在主App执行真实AI/动作调度，扩展每秒覆盖一份受保护的最新截图供读取，停止后删除。系统可能拒绝或终止，不保证永久保活或每步刷新；强退后租约失效会停止。需真机验收。").font(.caption).foregroundStyle(.secondary)
                }
                Section("安全与节奏") {
                    Stepper("最大 \(model.configuration.maxSteps) 步", value: $model.configuration.maxSteps, in: 1...50)
                    Toggle("允许低风险导航点击和搜索框 ASCII 输入", isOn: $model.configuration.allowLowRiskNavigation)
                    Text("默认谨慎模式仅自动相对移动/滚动，点击和输入交给人工。开启后允许单步导航，不允许提交消息、购买、支付、删除、授权或密码。模型与关键词防线不是安全保证；截图可含误导信息。不能无人值守。").font(.caption).foregroundStyle(.secondary)
                    Text("单次会话上限5分钟；截图超过15秒禁止执行；只允许一个动作在途；失败即暂停；不自动重试动作。").font(.caption)
                }
                Section {
                    Button("删除已存密钥", role: .destructive) { showDelete = true }
                    Text(model.notice).font(.footnote)
                }
            }.disabled(model.isSessionActive || model.probing)
                .onChange(of: model.configuration.endpoint) { _, _ in model.configuration.uploadConsent = false; model.configuration.gatewayVisionConfirmed = false }
                .onChange(of: model.configuration.provider) { _, _ in model.configuration.uploadConsent = false; model.configuration.gatewayVisionConfirmed = false }
                .onChange(of: model.configuration.model) { _, _ in model.configuration.gatewayVisionConfirmed = false }
                .onChange(of: model.configuration.deviceURL) { _, _ in model.lastDeviceStatus = nil; model.deviceSummary = "设备地址已修改，请重新检查"; model.configuration.relativeModeConfirmed = false }
                .navigationTitle("连接与安全").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("停止并撤回上传", role: .destructive) { Task { await model.stopAndRevokeConsent() } }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if model.save() { dismiss() } }.disabled(model.isSessionActive) }
                }
                .safeAreaInset(edge: .bottom) {
                    if model.isSessionActive { Text("会话运行中不能编辑；先停止再修改。顶部可立即请求停止并撤回上传。").font(.caption).padding().background(.regularMaterial) }
                }
                .confirmationDialog("删除当前端点和设备的两项凭据？", isPresented: $showDelete) {
                    Button("删除密钥", role: .destructive) { model.deleteSecrets() }
                }
        }
    }
}

struct CalibrationView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualText = ""
    @State private var calibrationStep = 100
    @State private var targetHits = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("人工相对指针校准").font(.title2.bold())
                    Text("停止自动会话，先将 ESP32 作为蓝牙鼠标配对。必要时在辅助功能中开启辅助触控。在主页允许控制（软件模式）或按硬件 ARM 后，用下方按钮观察实际指针移动。此面板会真实控制当前 iPhone，请停留在安全页面。")
                    Picker("相对步长", selection: $calibrationStep) { Text("10 · 微调").tag(10); Text("50").tag(50); Text("100 · 标定").tag(100) }.pickerStyle(.segmented)
                    Button {
                        targetHits += 1
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "target").font(.system(size: 48))
                            Text("安全测试靶心 · 已收到\(targetHits)次点击").font(.caption)
                        }.frame(maxWidth: .infinity).padding(20).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain).accessibilityLabel("安全测试靶心，点击只增加本地计数")
                    Text("用方向按钮把系统指针移到靶心，再用下方左键测试。触屏点靶心也会计数，因此计数本身不能证明HID成功；请观察真实指针。").font(.caption)
                    VStack(spacing: 14) {
                        Button("↑ \(calibrationStep)") { Task { await model.manual(.move, dx: 0, dy: -calibrationStep) } }
                        HStack(spacing: 28) {
                            Button("← \(calibrationStep)") { Task { await model.manual(.move, dx: -calibrationStep, dy: 0) } }
                            Image(systemName: "scope").font(.largeTitle)
                            Button("\(calibrationStep) →") { Task { await model.manual(.move, dx: calibrationStep, dy: 0) } }
                        }
                        Button("↓ \(calibrationStep)") { Task { await model.manual(.move, dx: 0, dy: calibrationStep) } }
                    }.frame(maxWidth: .infinity).buttonStyle(.bordered).disabled(model.sending)
                    HStack {
                        Button("左键点击") { Task { await model.manual(.click) } }
                        Button("滚动 +1") { Task { await model.manual(.scroll, wheel: 1) } }
                        Button("Esc") { Task { await model.manual(.key, key: "ESC") } }
                    }.buttonStyle(.bordered).disabled(model.sending)
                    TextField("可选：ASCII 输入到当前焦点（先确认安全）", text: $manualText).textFieldStyle(.roundedBorder)
                    Button("发送上述 ASCII 文本") { Task { await model.manual(.text, text: manualText) } }.disabled(model.sending || manualText.isEmpty)
                    Text("不支持中文HID直输。系统拼音键盘下可由用户手动试ASCII拼音，再观察并选择候选；这取决于系统输入法、焦点与HID布局，未保证可用。不会自动切换输入法、粘贴或发送外部消息。不要在密码框使用。").font(.caption).foregroundStyle(.secondary)
                    Group {
                        TextField("100 X 单位约移动多少屏幕像素", value: $model.configuration.calibrationX, format: .number).keyboardType(.decimalPad)
                        TextField("100 Y 单位约移动多少屏幕像素", value: $model.configuration.calibrationY, format: .number).keyboardType(.decimalPad)
                        Picker("方向", selection: $model.configuration.orientation) { Text("竖屏").tag("portrait"); Text("横屏").tag("landscape") }
                        Toggle("已确认当前指针位置和相对移动行为", isOn: $model.configuration.relativeModeConfirmed)
                            .onChange(of: model.configuration.relativeModeConfirmed) { _, value in model.configuration.calibratedAt = value ? Date() : nil }
                    }
                    Text("加速度、方向、系统设置会影响结果。这些只是人工估计，不用于可靠绝对坐标换算。ReplayKit 不保证包含鼠标指针；若 AI 看不到指针，移动/点击将暂停。").font(.caption).foregroundStyle(.secondary)
                    Text(model.notice).font(.footnote)
                }.padding(24)
            }.disabled(model.isSessionActive).navigationTitle("指针实验台").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { if model.save() { dismiss() } } } }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: PilotViewModel
    var body: some View {
        NavigationStack {
            List(model.logs.reversed()) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.message)
                    Text(item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("最近动作").overlay { if model.logs.isEmpty { ContentUnavailableView("还没有动作", systemImage: "list.bullet") } }
        }
    }
}
