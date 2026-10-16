import SwiftUI
import ReplayKit

struct HomeView: View {
    @EnvironmentObject private var model: PilotViewModel
    @State private var showSettings = false
    @State private var showCalibration = false
    @State private var showLogs = false
    @State private var confirmResume = false
    @State private var showWorkspace = false
    @State private var showOnboarding = false
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 10) {
                            Circle().fill(model.status.phase == "暂停" ? .orange : .mint).frame(width: 8, height: 8)
                            Text(model.status.phase).font(.subheadline.bold())
                            Spacer()
                            Text("\(model.status.steps) 步").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Image("BrandMark").resizable().scaledToFit().frame(width: 56, height: 56).accessibilityHidden(true)
                            Text("你想完成什么？").font(.largeTitle.bold())
                            Text("把目标交给 AI，让真实的屏幕与指针一步步协作。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.top, 28)
                        TextField("例如：在浏览器中查找一篇文章", text: $model.task, axis: .vertical)
                            .disabled(model.isSessionActive).lineLimit(3...7).padding(20).background(.background, in: RoundedRectangle(cornerRadius: 24))
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.status.detail, systemImage: "sparkle").font(.callout)
                            Text("更新于 \(model.status.updatedAt.formatted(date: .omitted, time: .standard)) · 状态可能过期")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.status.phase == "暂停" {
                                if model.configuration.continuedProcessingEnabled == true {
                                    Text("后台协调会话已结束。请人工处理后重新ARM、准备会话并重新开始系统广播。").font(.caption)
                                } else {
                                    Button("我已手动处理，继续观察") { confirmResume = true }.buttonStyle(.bordered)
                                }
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 20))
                        Label(model.notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                        Label(model.selectedProfileName + " · " + model.deviceSummary, systemImage: "network").font(.caption).foregroundStyle(.secondary)
                        Button("保存到待办队列", systemImage: "text.badge.plus") { model.saveTaskToQueue() }
                        if model.status.phase == "暂停" {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.recovery.title).font(.headline)
                                Text(model.recovery.steps).font(.caption)
                            }.padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        }
                        HStack {
                            Button("指针校准", systemImage: "scope") { showCalibration = true }
                            Spacer()
                            Button("动作记录", systemImage: "list.bullet.rectangle") { showLogs = true }
                        }.font(.subheadline)
                        Text("屏幕内容会交给所选 AI 服务。请勿在密码、支付、医疗或其他敏感页面开启广播。物理急停优先于任何软件停止。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(24)
                }
            }
            .navigationTitle("SightLatch").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("工作区", systemImage: "square.grid.2x2") { showWorkspace = true } }; ToolbarItem(placement: .topBarTrailing) { Button("设置", systemImage: "slider.horizontal.3") { showSettings = true } } }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 18) {
                    Button { Task { await model.prepare() } } label: {
                        Label("准备会话", systemImage: "sparkles").font(.subheadline.bold())
                    }.disabled(model.isSessionActive || model.probing)
                    Spacer()
                    BroadcastPicker().frame(width: 44, height: 44).disabled(!model.prepared)
                    Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                        .accessibilityLabel("停止会话并解除硬件 ARM").disabled(model.stopping)
                }.padding(.horizontal, 24).padding(.vertical, 12).pilotGlass().padding(.horizontal, 20).padding(.bottom, 8)
            }
            .sheet(isPresented: $showWorkspace) { WorkspaceHubView() }
            .sheet(isPresented: $showOnboarding) { OnboardingView() }
            .onAppear { showOnboarding = !model.workspace.onboardingComplete }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .sheet(isPresented: $showLogs) { LogsView() }
            .confirmationDialog("确认你已在目标 App 人工完成或取消提案，并已检查风险？", isPresented: $confirmResume, titleVisibility: .visible) {
                Button("已人工处理，重新观察新画面") { model.resumeAfterManual() }
            } message: { Text("这不会批准执行旧动作。先物理 ARM，返回目标 App；AI 会重新规划，仍可能暂停。") }
        }
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

extension View {
    @ViewBuilder func pilotGlass() -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular, in: .capsule) }
        else { self.background(.ultraThinMaterial, in: Capsule()) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section("模型服务") {
                    Picker("协议", selection: $model.configuration.provider) {
                        Text("OpenAI Responses").tag("responses")
                        Text("OpenAI 兼容 Chat Completions").tag("openai")
                        Text("Anthropic Messages").tag("anthropic")
                        Text("Google Gemini generateContent").tag("gemini")
                    }
                    TextField("完整 HTTPS 请求 URL", text: $model.configuration.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("支持视觉的模型 ID", text: $model.configuration.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key（空白保留已有值）", text: $model.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("OpenAI: /v1/responses\n兼容网关: /v1/chat/completions\nAnthropic: https://api.anthropic.com/v1/messages\nGemini: https://generativelanguage.googleapis.com/v1beta/models/模型ID:generateContent\nGemini 模型以 URL 中的 ID 为准。模型是否支持截图、计费和数据保留由供应商决定。").font(.caption)
                    if model.configuration.provider == "openai" {
                        Toggle("确认此兼容端点与模型支持图片，且我获准用于此用途", isOn: Binding(get: { model.configuration.gatewayVisionConfirmed == true }, set: { model.configuration.gatewayVisionConfirmed = $0 }))
                    }
                    Toggle("同意将广播中的屏幕截图发给上述端点", isOn: $model.configuration.uploadConsent)
                    Text("会持续发送跨 App 截图；服务方可能保留图像。系统广播许可与此上传同意是两回事。撤回后请立即停止会话。App 订阅不等于 API 额度；无 ChatGPT/Codex 或第三方订阅登录功能。").font(.caption).foregroundStyle(.secondary)
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
                    Text("停止自动会话，先将 ESP32 作为蓝牙鼠标配对。必要时在辅助功能中开启辅助触控。按硬件 ARM 后，用下方按钮观察实际指针移动。此面板会真实控制当前 iPhone，请停留在安全页面。")
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
