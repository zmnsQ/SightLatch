import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WorkspaceHubView: View {
    var embedded = false
    @EnvironmentObject private var model: PilotViewModel
    @State private var confirmRecovery = false
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(spacing: 24) {
                    PilotSettingsHero(kind: .data, title: "你的设置，妥善收好",
                        subtitle: "查看本机信息，备份常用配置。")
                    PilotSettingsCard {
                        NavigationLink { DeviceEnvironmentView() } label: {
                            WorkspaceNavigationLabel(title: "本机与屏幕", subtitle: "显示与辅助功能信息", symbol: "iphone")
                        }
                        Divider()
                        NavigationLink { TransferView(embedded: true) } label: {
                            WorkspaceNavigationLabel(title: "迁移与诊断", subtitle: "备份设置，导出诊断文件", symbol: "square.and.arrow.up")
                        }
                    }.buttonStyle(WorkspaceRowPressStyle())
                    PilotSettingsCard {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(model.recovery.title).font(.headline)
                                Text(model.recovery.steps).font(.callout)
                                PilotSettingsNotice(message: model.notice)
                            }.padding(.top, 8)
                        } label: {
                            PilotSettingsRowLabel(title: "帮助与操作详情", symbol: "questionmark.circle")
                        }
                    }
                    if let warning = model.storageWarning {
                        PilotSettingsCard {
                            Label("本地数据需要恢复", systemImage: "exclamationmark.triangle")
                                .font(.headline).foregroundStyle(.orange)
                            Text(warning).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Button("备份并重置工作区", role: .destructive) { confirmRecovery = true }
                                .frame(minHeight: 44).disabled(model.stopping)
                        }
                    }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.navigationTitle("高级与数据")
                .modifier(PilotSettingsPageStyle(showsCloseButton: !embedded, appliesHorizontalMargins: false))
                .confirmationDialog("停止会话并重置配置与任务库？", isPresented: $confirmRecovery, titleVisibility: .visible) {
                    Button("保留旧文件副本并重置", role: .destructive) { Task { await model.recoverDamagedSettings() } }
                } message: { Text("旧文件会备份在本机。任务库与设置将恢复默认，已保存的密钥保留。请先结束屏幕共享并停止设备。") }
        }
    }
}

/// Public API values are sampled locally. No identity, clipboard or network inventory is read.
private struct DeviceEnvironmentSnapshot {
    struct SectionData: Identifiable {
        var id: String
        var symbol: String
        var rows: [Row]
    }
    struct Row: Identifiable {
        var id: String
        var value: String
    }
    var capturedAt = Date()
    var sections: [SectionData]

    @MainActor static func capture() -> Self {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow }
        let screen = scene?.screen
        let traits = window?.traitCollection
        func enabled(_ value: Bool) -> String { value ? "已开启" : "未开启" }
        func size(_ value: CGSize?) -> String {
            guard let value else { return "暂不可用" }
            return "\(Int(value.width)) × \(Int(value.height))"
        }
        let orientation: String
        switch scene?.interfaceOrientation {
        case .portrait: orientation = "竖屏"
        case .portraitUpsideDown: orientation = "倒置竖屏"
        case .landscapeLeft: orientation = "横屏 · 左"
        case .landscapeRight: orientation = "横屏 · 右"
        default: orientation = "暂不可用"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "轻微升温"
        case .serious: thermal = "温度较高"
        case .critical: thermal = "温度过高"
        @unknown default: thermal = "未知"
        }
        let guided = UIAccessibility.isGuidedAccessEnabled
        // UIKit documents false outside Guided Access even when AssistiveTouch is enabled.
        let assistiveTouch = guided ? enabled(UIAccessibility.isAssistiveTouchRunning) : "系统接口不可确认"
        let insets = window?.safeAreaInsets
        let safeArea = insets.map { "上 \(Int($0.top)) · 下 \(Int($0.bottom)) · 左 \(Int($0.left)) · 右 \(Int($0.right)) pt" } ?? "暂不可用"
        return Self(sections: [
            SectionData(id: "屏幕能力", symbol: "display", rows: [
                Row(id: "原生像素（固定竖向）", value: size(screen?.nativeBounds.size)),
                Row(id: "逻辑尺寸 · pt", value: size(screen?.bounds.size)),
                Row(id: "绘制倍率", value: screen.map { String(format: "%.2f×", $0.scale) } ?? "暂不可用"),
                Row(id: "原生倍率", value: screen.map { String(format: "%.2f×", $0.nativeScale) } ?? "暂不可用"),
                Row(id: "最高刷新率", value: screen.map { "\($0.maximumFramesPerSecond) Hz" } ?? "暂不可用")
            ]),
            SectionData(id: "SightLatch 当前窗口", symbol: "rectangle.inset.filled", rows: [
                Row(id: "界面方向", value: orientation),
                Row(id: "安全区域", value: safeArea),
                Row(id: "文字大小", value: traits?.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: "") ?? "暂不可用"),
                Row(id: "外观", value: traits.map { $0.userInterfaceStyle == .dark ? "深色" : "浅色" } ?? "暂不可用")
            ]),
            SectionData(id: "辅助功能", symbol: "accessibility", rows: [
                Row(id: "旁白", value: enabled(UIAccessibility.isVoiceOverRunning)),
                Row(id: "切换控制", value: enabled(UIAccessibility.isSwitchControlRunning)),
                Row(id: "引导式访问", value: enabled(guided)),
                Row(id: "辅助触控", value: assistiveTouch),
                Row(id: "减少动态效果", value: enabled(UIAccessibility.isReduceMotionEnabled)),
                Row(id: "降低透明度", value: enabled(UIAccessibility.isReduceTransparencyEnabled))
            ]),
            SectionData(id: "运行环境", symbol: "cpu", rows: [
                Row(id: "系统版本", value: UIDevice.current.systemVersion),
                Row(id: "低电量模式", value: enabled(ProcessInfo.processInfo.isLowPowerModeEnabled)),
                Row(id: "温度状态", value: thermal)
            ])
        ])
    }
}

private struct DeviceEnvironmentView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var snapshot: DeviceEnvironmentSnapshot?
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                PilotSettingsHero(kind: .device, title: "这台 iPhone",
                    subtitle: "屏幕、显示与辅助功能，集中查看。")
                if let snapshot {
                    ForEach(snapshot.sections) { section in
                        PilotSettingsCard {
                            Label(section.id, systemImage: section.symbol).font(.headline)
                            ForEach(section.rows) { row in
                                infoRow(row.id, value: row.value)
                                if row.id != section.rows.last?.id { Divider() }
                            }
                        }
                    }
                }
                PilotSettingsCard {
                    PilotSettingsRowLabel(title: "屏幕共享画面", symbol: "rectangle.on.rectangle")
                    if let observation = model.captureObservation,
                       observation.sessionID == SharedStore.shared.command?.id,
                       SharedStore.shared.command?.running == true {
                        infoRow("状态", value: observation.hasFreshFrame ? "正在收到画面" : observation.state == "stopped" ? "已结束" : observation.state == "paused" ? "已暂停" : observation.state == "waiting" ? "等待第一帧" : "画面更新已中断")
                        if let width = observation.sourceWidth, let height = observation.sourceHeight {
                            infoRow("最近一帧 · px", value: "\(width) × \(height)")
                        }
                        infoRow("方向附件", value: observation.exifOrientation.map { "EXIF \($0)" } ?? "系统未提供")
                        if let date = observation.receivedAt {
                            infoRow("最近收到", value: date.formatted(date: .omitted, time: .standard))
                        }
                    } else {
                        Text("尚未收到本次任务的画面").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let snapshot {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("更新于 \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup {
                            Text("来自 iOS 公共接口。窗口信息属于 SightLatch；其他 App 仍以共享画面为准。最高刷新率是屏幕能力，不代表广播帧率。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } label: {
                            Text("数据说明").font(.footnote).frame(minHeight: 44)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .navigationTitle("本机与屏幕").navigationBarTitleDisplayMode(.inline)
        .modifier(PilotSettingsPageStyle(showsCloseButton: false, appliesHorizontalMargins: false))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") { snapshot = .capture() }
            }
        }
        .onAppear { snapshot = .capture() }
    }
    @ViewBuilder private func infoRow(_ title: String, value: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }.font(.callout).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            LabeledContent(title, value: value)
                .font(.callout).textSelection(.enabled).frame(minHeight: 44)
        }
    }
}

/// Browsing a page never marks its setup complete or grants any permission.
struct OnboardingView: View {
    var embedded = false
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step = 0
    @State private var showDevice = false
    @State private var showAI = false
    @State private var showSafety = false
    @State private var showCalibration = false
    @State private var aiConfigured = false
    private let titles = ["看见屏幕，帮你行动", "让设备连接起来", "选择你的 AI", "让每次点击都准确"]
    private let subtitles = ["说出目标，共享屏幕，SightLatch 会边看边做。", "接上电源，让设备和 iPhone 连上同一 Wi-Fi。", "任务与截图，会交给你选择的 AI 服务。", "完成屏幕坐标校准，就能开始第一个小任务。"]
    private var deviceReady: Bool { model.deviceStatusIsFresh && model.lastDeviceStatus?.hid_connected == true }
    private var aiReady: Bool {
        aiConfigured && model.configuration.uploadConsent &&
            (model.configuration.provider != "chatgpt-plan" || model.configuration.chatGPTPlanConsent == true)
    }
    private var calibrationReady: Bool { model.configuration.hasVerifiedPointerCalibration }
    private var currentStepReady: Bool {
        switch step {
        case 1: return deviceReady
        case 2: return aiReady
        case 3: return calibrationReady
        default: return true
        }
    }
    private var actionTitle: String {
        switch step {
        case 0: return "开始设置"
        case 1: return deviceReady ? "下一步" : "连接设备"
        case 2:
            if aiReady { return "下一步" }
            return aiConfigured && (model.configuration.provider != "chatgpt-plan" || model.configuration.chatGPTPlanConsent == true)
                ? "设置截图权限" : "连接 AI 账户"
        default: return calibrationReady ? "进入聊天" : "校准屏幕坐标"
        }
    }
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 0)
                        WorkspaceOnboardingStage(step: step, height: stageHeight(geometry.size.height))
                            .id(step).transition(reduceMotion ? .identity : .opacity)
                        VStack(spacing: 14) {
                            Text(titles[step]).font(.largeTitle.bold()).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(subtitles[step]).font(.title3).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.id("copy-\(step)").transition(reduceMotion ? .identity : .opacity)
                        if step > 0 { setupStatus }
                        pageDetails
                        Spacer(minLength: 16)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: step)
                    .frame(maxWidth: 600).frame(minHeight: geometry.size.height)
                    .padding(.horizontal, 28).frame(maxWidth: .infinity)
                }.scrollIndicators(.hidden)
            }
            .background(PilotPalette.canvas)
            .safeAreaInset(edge: .bottom) { pageActions }
            .navigationTitle(step == 0 ? "SightLatch" : "开始使用").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(embedded && step > 0)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 {
                        if embedded {
                            Button("上一页", systemImage: "chevron.left") { step -= 1 }
                                .labelStyle(.iconOnly)
                        } else {
                            Button("返回") { step -= 1 }
                        }
                    }
                }
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) { Button("稍后设置") { dismiss() } }
                }
            }
            .sheet(isPresented: $showDevice) { DeviceSettingsView().modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showAI) { ConfigurationDetailView(safety: false).modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showSafety) { ConfigurationDetailView(safety: true).modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showCalibration) { CalibrationView().modifier(PilotAppearanceStyle()) }
            .onAppear { refreshSetupStatus() }
            .onChange(of: showDevice) { _, visible in if !visible { refreshSetupStatus() } }
            .onChange(of: showAI) { _, visible in if !visible { refreshSetupStatus() } }
            .onChange(of: showSafety) { _, visible in if !visible { refreshSetupStatus() } }
            .onChange(of: showCalibration) { _, visible in if !visible { refreshSetupStatus() } }
        }.modifier(PilotAppearanceStyle())
    }
    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<4) { index in
                Capsule().fill(index == step ? PilotPalette.accent : Color.primary.opacity(0.12))
                    .frame(width: index == step ? 24 : 7, height: 5)
            }
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .ignore).accessibilityLabel("介绍第 \(step + 1) 页，共 4 页")
    }
    @ViewBuilder private var setupStatus: some View {
        switch step {
        case 1:
            WorkspaceSetupStatus(title: deviceReady ? "设备已连接" : "等待检查设备连接", complete: deviceReady)
        case 2:
            WorkspaceSetupStatus(title: aiReady ? "AI 与截图权限已设置" : aiConfigured ? "AI 已配置，权限待设置" : "等待选择 AI 服务", complete: aiReady)
        case 3:
            WorkspaceSetupStatus(title: calibrationReady ? "屏幕坐标已校准" : "等待完成屏幕校准", complete: calibrationReady)
        default: EmptyView()
        }
    }
    @ViewBuilder private var pageDetails: some View {
        if step > 0 {
            DisclosureGroup {
                Group {
                    if step == 1 {
                        Text("填入设备地址与控制口令，检查连接后完成蓝牙配对。使用 HTTP 时，口令与指令以明文传输，请使用可信 Wi-Fi。")
                    } else if step == 2 {
                        Text("截图上传由你单独开启，共享画面会发送至所选服务，服务方可能保留图像。ChatGPT 套餐与 API 分开计费。这里的已配置表示账户与模型设置可用，不代表服务连通性已测试。")
                    } else {
                        Text("校准只在全屏画布测量落点。任务中可随时停止；进入密码、付款等敏感页面前，请结束共享。若停止未确认，请按设备停止键或断开电源。")
                    }
                }.font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } label: {
                Text(step == 1 ? "连接说明" : step == 2 ? "数据与权限" : "校准与停止")
                    .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44)
            }
            .frame(maxWidth: 420)
        }
    }
    private var pageActions: some View {
        VStack(spacing: 8) {
            pageIndicator.padding(.bottom, 8)
            Button(action: performPrimaryAction) {
                Text(actionTitle).font(.headline).frame(maxWidth: .infinity)
            }
            .modifier(WorkspacePrimaryAction()).controlSize(.large).frame(minHeight: 44)
            if step > 0 && !currentStepReady {
                Button(step == 3 ? "稍后校准，先进入聊天" : "跳过这一步") { advance() }
                    .font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .background(PilotPalette.canvas)
    }
    private func stageHeight(_ available: CGFloat) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 170 : max(240, min(420, available * (step == 0 ? 0.60 : 0.52)))
    }
    private func refreshSetupStatus() {
        aiConfigured = model.readiness().first(where: { $0.id == "model" })?.passed == true
    }
    private func performPrimaryAction() {
        switch step {
        case 1 where !deviceReady: showDevice = true
        case 2 where !aiReady:
            if aiConfigured && (model.configuration.provider != "chatgpt-plan" || model.configuration.chatGPTPlanConsent == true) { showSafety = true }
            else { showAI = true }
        case 3 where !calibrationReady: showCalibration = true
        default: advance()
        }
    }
    private func advance() {
        if step < 3 { step += 1 }
        else {
            model.workspace.onboardingComplete = true
            if model.persistWorkspace() { dismiss() }
        }
    }
}

/// A small settings map, with one authoritative location for each setting.
struct SettingsView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [Destination] = []
    private enum Destination: String, Hashable {
        case device, ai, safety, duration, voice, workspace, onboarding
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        WorkspaceSymbolTile(symbol: "slider.horizontal.3", size: 52)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("设置").font(.largeTitle.bold())
                            Text("让设备与 AI 随时就绪。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    VStack(spacing: 0) {
                        settingsRow("设备", subtitle: "连接与配对", symbol: "computermouse", destination: .device)
                        Divider().padding(.leading, 68)
                        settingsRow("AI 账户", subtitle: "服务、模型与登录", symbol: "person.crop.circle", destination: .ai)
                        Divider().padding(.leading, 68)
                        settingsRow("权限与安全", subtitle: "屏幕上传与操作范围", symbol: "hand.raised", destination: .safety)
                    }.background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("通用").font(.subheadline).foregroundStyle(.secondary).padding(.leading, 4)
                        VStack(spacing: 0) {
                            HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                                settingsIcon("circle.lefthalf.filled")
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("外观").font(.body)
                                        appearancePicker
                                    }
                                    Spacer(minLength: 0)
                                } else {
                                    Text("外观").font(.body)
                                    Spacer(minLength: 8)
                                    appearancePicker
                                }
                            }.padding(.horizontal, 20).padding(.vertical, 12)
                            Divider().padding(.leading, 68)
                            settingsRow("运行时长", subtitle: model.configuration.unlimitedRun == true
                                ? "不限时 · 每次确认" : "\(model.configuration.selectedRunDurationSeconds / 60) 分钟",
                                symbol: "clock", destination: .duration)
                            Divider().padding(.leading, 68)
                            settingsRow("语音与播报", subtitle: "播报开关与中文音色", symbol: "speaker.wave.2", destination: .voice)
                            Divider().padding(.leading, 68)
                            settingsRow("高级与数据", symbol: "archivebox", destination: .workspace)
                            Divider().padding(.leading, 68)
                            settingsRow("使用指南", symbol: "book.closed", destination: .onboarding)
                        }.background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 24))
                    }
                    DisclosureGroup {
                        Text("任务与截图会发送给所选 AI 服务。你可以在权限与安全中管理上传；进入敏感页面前请结束屏幕共享。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } label: {
                        Label("数据与隐私", systemImage: "hand.raised")
                            .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.padding(.horizontal, 4)
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(PilotPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // This belongs to the root page; pushing a destination supplies its own toolbar.
                ToolbarItem(id: "settings.close", placement: .topBarTrailing) { PilotCloseButton { dismiss() } }
            }
            .navigationDestination(for: Destination.self) { destination in
                Group {
                    switch destination {
                    case .device: DeviceSettingsView(embedded: true)
                    case .ai: ConfigurationDetailView(safety: false, embedded: true)
                    case .safety: ConfigurationDetailView(safety: true, embedded: true)
                    case .duration: RunDurationSettingsView(embedded: true)
                    case .voice: VoiceFeedbackSettingsPage()
                    case .workspace: WorkspaceHubView(embedded: true)
                    case .onboarding: OnboardingView(embedded: true)
                    }
                }.modifier(PilotAppearanceStyle())
            }
        }.modifier(PilotAppearanceStyle())
    }
    private func settingsRow(_ title: String, subtitle: String? = nil, symbol: String, destination target: Destination) -> some View {
        Button { path.append(target) } label: {
            HStack(spacing: 12) {
                settingsIcon(symbol)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 44).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(WorkspaceRowPressStyle())
    }
    private func settingsIcon(_ symbol: String) -> some View {
        WorkspaceSymbolTile(symbol: symbol, size: 36)
    }
    private var appearancePicker: some View {
        Picker("外观", selection: $model.workspace.theme) {
            Text("跟随系统").tag("system")
            Text("浅色").tag("light")
            Text("深色").tag("dark")
        }.labelsHidden().pickerStyle(.menu)
            .frame(minHeight: 44)
            .onChange(of: model.workspace.theme) { _, _ in model.persistWorkspace() }
    }
}

private struct VoiceFeedbackSettingsPage: View {
    var body: some View {
        ScrollView {
            VoiceFeedbackSettingsView()
                .padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .background(PilotPalette.canvas)
        .navigationTitle("语音与播报").navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings destinations share their parent's stack; standalone entry points retain their own.
struct PilotSettingsNavigation<Content: View>: View {
    let embedded: Bool
    let content: Content

    init(embedded: Bool, @ViewBuilder content: () -> Content) {
        self.embedded = embedded
        self.content = content()
    }
    var body: some View {
        if embedded { content }
        else { NavigationStack { content } }
    }
}

struct ProfilesView: View {
    var embedded = false
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var name = ""
    @State private var deleting: ModelProfile?
    @State private var feedback: String?
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotSettingsHero(kind: .models, title: "常用模型，随时切换",
                        subtitle: "把熟悉的连接设置保存为档案。")
                    if !model.workspace.profiles.isEmpty {
                        Text("切换档案后，需要重新确认屏幕上传。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(model.workspace.profiles) { profile in
                            profileCard(profile)
                        }
                    }
                    PilotSettingsCard {
                        PilotSettingsRowLabel(title: "保存当前配置", subtitle: "模型与密钥可在 AI 账户中修改。", symbol: "square.and.arrow.down")
                        TextField("档案名称", text: $name).frame(minHeight: 44)
                        Button {
                            _ = model.saveCurrentProfile(name: name)
                            feedback = model.notice
                        } label: {
                            Text("保存当前档案").frame(maxWidth: .infinity, minHeight: 48)
                        }.modifier(WorkspacePrimaryAction())
                        Button("另存为新档案") {
                            _ = model.saveCurrentProfile(name: name, asNew: true)
                            feedback = model.notice
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(model.isSessionActive)
                    PilotSettingsCard {
                        NavigationLink { GatewaySetupView(embedded: true) } label: {
                            WorkspaceNavigationLabel(title: "兼容网关", subtitle: "连接你信任的 AI 网关", symbol: "point.3.connected.trianglepath.dotted")
                        }.disabled(model.isSessionActive)
                    }.buttonStyle(WorkspaceRowPressStyle())
                    if let feedback { PilotSettingsNotice(message: feedback) }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("密钥按服务与端点保存在本机 Keychain。同一端点的不同模型共用该密钥；移除档案不会删除密钥。")
                            Text("自管网关使用 OpenAI 兼容协议。上游授权与图片能力由网关提供；ChatGPT 套餐登录请在 AI 账户中选择。")
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    } label: {
                        Label("档案与密钥", systemImage: "key").font(.footnote).frame(minHeight: 44)
                    }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.navigationTitle("模型档案")
                .modifier(PilotSettingsPageStyle(showsCloseButton: !embedded, appliesHorizontalMargins: false))
                .confirmationDialog("移除这个配置档案？密钥会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("移除档案", role: .destructive) {
                        if let deleting { model.removeProfile(deleting); feedback = model.notice }
                        deleting = nil
                    }
                }
        }
    }
    private func profileCard(_ profile: ModelProfile) -> some View {
        PilotSettingsCard {
            HStack(alignment: .top, spacing: 12) {
                WorkspaceSymbolTile(symbol: "square.stack.3d.up", size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("\(providerName(profile.configuration.provider)) · \(profile.configuration.model.isEmpty ? "尚未设置模型" : profile.configuration.model)")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if profile.id == model.workspace.selectedProfileID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PilotPalette.accent)
                        .accessibilityLabel("当前档案")
                }
            }
            Text(URL(string: profile.configuration.endpoint)?.host ?? "无效端点")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button {
                    model.selectProfile(profile)
                    feedback = model.notice
                } label: {
                    Label("使用此档案", systemImage: "arrow.left.arrow.right")
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }.accessibilityHint("切换后需要重新确认屏幕上传")
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button("移除", role: .destructive) { deleting = profile }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            }.font(.subheadline).buttonStyle(.borderless).disabled(model.isSessionActive)
        }
    }
    private func providerName(_ provider: String) -> String {
        switch provider {
        case "chatgpt-plan": return "ChatGPT"
        case "responses": return "OpenAI"
        case "openai": return "兼容服务"
        case "anthropic": return "Anthropic"
        case "gemini": return "Gemini"
        default: return provider
        }
    }
}

struct TaskLibraryView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filter = "待办"
    @State private var deleting: SavedTask?
    private var records: [SavedTask] {
        model.workspace.tasks.filter { filter == "全部" || (filter == "待办" ? $0.state == "待办" : $0.state != "待办") }
            .sorted { filter == "待办" ? $0.createdAt < $1.createdAt : $0.updatedAt > $1.updatedAt }
    }
    private var pendingCount: Int { model.workspace.tasks.filter { $0.state == "待办" }.count }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    WorkspaceFeatureHeader(symbol: "tray.2", title: "留住每个目标",
                        subtitle: model.workspace.tasks.isEmpty ? "常用任务，随时再出发。" : "\(pendingCount) 个待办 · \(model.workspace.tasks.count - pendingCount) 条历史")
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    Picker("显示", selection: $filter) { Text("待办").tag("待办"); Text("历史").tag("历史"); Text("全部").tag("全部") }.pickerStyle(.segmented)
                    Button("保存当前任务", systemImage: "plus") { model.saveTaskToQueue() }
                        .frame(minHeight: 44)
                }.listRowBackground(PilotPalette.group)
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            WorkspaceSymbolTile(symbol: taskSymbol(record), size: 36)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(record.text).font(.body.weight(.medium))
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4).textSelection(.enabled)
                                Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        taskActions(record)
                    }.padding(.vertical, 8)
                }.listRowBackground(PilotPalette.group)
                if records.isEmpty {
                    ContentUnavailableView(filter == "待办" ? "还没有待办" : "暂无记录", systemImage: "tray",
                        description: Text("在聊天里写下目标，保存后就会出现在这里。"))
                        .listRowBackground(Color.clear)
                }
                Section {
                    DisclosureGroup("关于任务库") {
                        Text("待办按创建时间排列。载入后由你开始共享，完成一项不会自动启动下一项。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !model.notice.isEmpty {
                        DisclosureGroup("最近操作详情") { PilotSettingsNotice(message: model.notice) }
                    }
                }.listRowBackground(PilotPalette.group)
            }.navigationTitle("任务库")
                .modifier(PilotSettingsPageStyle())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: filter)
                .confirmationDialog("删除这条任务和历史？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除", role: .destructive) { if let deleting { model.removeTask(deleting.id) }; deleting = nil }
                }
        }
    }
    private func taskActions(_ record: SavedTask) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 8) {
                Text(record.state == "已人工确认完成" ? "已确认完成" : record.state)
                    .font(.caption.weight(.medium)).foregroundStyle(PilotPalette.accent)
                if record.steps > 0 {
                    Text("\(record.steps) 步").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 8) {
                Button("载入", systemImage: "arrow.turn.up.left") { model.loadTask(record) }
                    .frame(minWidth: 44, minHeight: 44).disabled(model.isSessionActive)
                Menu {
                    Button("我已确认实际完成") { model.markTask(record.id, completed: true) }
                    Button("移回待办（不执行）") { model.markTask(record.id, completed: false) }
                    Button("删除记录", role: .destructive) { deleting = record }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("管理任务").disabled(record.state == "运行中")
            }
        }.font(.subheadline).buttonStyle(.borderless)
    }
    private func taskSymbol(_ record: SavedTask) -> String {
        if record.state == "运行中" { return "play.circle" }
        if record.state == "已人工确认完成" { return "checkmark.circle" }
        return record.state == "待办" ? "text.bubble" : "clock.arrow.circlepath"
    }
}

struct TransferView: View {
    var embedded = false
    @EnvironmentObject private var model: PilotViewModel
    @State private var document = JSONDocument()
    @State private var exporting = false
    @State private var importing = false
    @State private var filename = "SightLatch-settings"
    @State private var exportError: String?
    @State private var feedback: String?
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(spacing: 24) {
                    PilotSettingsHero(kind: .data, title: "备份设置，轻松迁移",
                        subtitle: "换设备时，带上熟悉的配置。")
                    PilotSettingsCard {
                        PilotSettingsRowLabel(title: "设置备份", subtitle: "包含服务地址，不含密钥、任务或截图。", symbol: "externaldrive")
                        Button {
                            exportError = nil; feedback = nil
                            do { document = JSONDocument(data: try model.exportSettings()); filename = "SightLatch-settings"; exporting = true }
                            catch { exportError = error.localizedDescription }
                        } label: {
                            Label("导出设置", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }.modifier(WorkspacePrimaryAction()).disabled(model.isSessionActive)
                        Button {
                            exportError = nil; feedback = nil; importing = true
                        } label: {
                            Label("导入设置", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.disabled(model.isSessionActive)
                        Text("导入后不会自动启用，还需重新确认权限与校准。")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup {
                            Text("仅导出模型档案与非秘密配置，包含端点和局域网主机地址；不含 API Key、设备令牌、任务或截图。屏幕上传、自动操作和校准确认会在文件中重置。")
                                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                        } label: { Text("文件包含什么").font(.footnote).frame(minHeight: 44) }
                    }
                    PilotSettingsCard {
                        PilotSettingsRowLabel(title: "诊断文件", subtitle: "设备与运行状态摘要，方便排查问题。", symbol: "doc.text.magnifyingglass")
                        Text("不含密钥、地址、任务或截图。保存后请先查看，再自行分享。")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button {
                            exportError = nil; feedback = nil
                            do { document = JSONDocument(data: try model.exportDiagnostics()); filename = "SightLatch-diagnostics"; exporting = true }
                            catch { exportError = error.localizedDescription }
                        } label: {
                            Label("导出诊断", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                        DisclosureGroup {
                            Text("包含系统版本、协议类别、阶段与步数、凭据是否存在、最近蓝牙与设备控制状态；不含密钥、端点、模型名、任务、原始日志或截图。文件不会自动上传。")
                                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                        } label: { Text("诊断范围").font(.footnote).frame(minHeight: 44) }
                    }
                    if let exportError { PilotSettingsNotice(message: exportError, isError: true) }
                    if let feedback { PilotSettingsNotice(message: feedback) }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.navigationTitle("迁移与诊断")
                .modifier(PilotSettingsPageStyle(showsCloseButton: !embedded, appliesHorizontalMargins: false))
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: filename) { result in
                    switch result {
                    case .success:
                        model.notice = "文件已交给系统保存；未发送到任何外部服务。"
                        feedback = model.notice
                    case .failure(let error): exportError = error.localizedDescription
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url): model.importSettings(url); feedback = model.notice
                    case .failure(let error): exportError = error.localizedDescription
                    }
                }
        }
    }
}

struct GatewaySetupView: View {
    var embedded = false
    @EnvironmentObject private var model: PilotViewModel
    @State private var name = "我的兼容网关"
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var visionConfirmed = false
    @State private var feedback: String?
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(spacing: 24) {
                    PilotSettingsHero(kind: .gateway, title: "连接你信任的网关",
                        subtitle: "使用兼容服务与支持图片的模型。")
                    PilotSettingsCard {
                        field("档案名称") { TextField("例如：我的视觉模型", text: $name) }
                        Divider()
                        field("服务地址") {
                            TextField("https://…/chat/completions", text: $endpoint)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Divider()
                        field("视觉模型") {
                            TextField("网关提供的模型 ID", text: $modelID)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Divider()
                        field("API Key") {
                            SecureField("网关密钥", text: $key)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    PilotSettingsCard {
                        PilotSettingsRowLabel(title: "数据去向", subtitle: "此 iPhone → 兼容网关 → AI 服务", symbol: "arrow.triangle.branch")
                        Text("任务与截图先到网关，再可能转交上游服务。请核对运营者、数据保留与费用。")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Toggle("已确认图片能力与使用授权", isOn: $visionConfirmed)
                            .tint(PilotPalette.accent).frame(minHeight: 44)
                    }
                    Button {
                        model.configureGateway(name: name, endpoint: endpoint, modelID: modelID, key: key, visionConfirmed: visionConfirmed)
                        key = ""
                        feedback = model.notice
                    } label: {
                        Text("保存网关档案").frame(maxWidth: .infinity, minHeight: 50)
                    }.modifier(WorkspacePrimaryAction())
                        .disabled(model.isSessionActive || endpoint.isEmpty || modelID.isEmpty || !visionConfirmed)
                    if let feedback { PilotSettingsNotice(message: feedback) }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("填写完整的 HTTPS chat/completions 地址。仅保存配置不会联网或发送截图；屏幕上传仍需单独确认。")
                            Text("自管网关使用 OpenAI 兼容协议。CLIProxyAPI 等项目提供的订阅适配并非本 App 的官方登录；请自行确认上游授权、使用条款与图片能力。")
                            Text("密钥应由网关提供，不要填写浏览器 Cookie 或订阅令牌。App 不读取这些浏览器数据，也不代为登录；不提供公网 HTTP、自签名证书绕过或自动订阅登录。")
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    } label: {
                        Label("网关说明", systemImage: "info.circle").font(.footnote).frame(minHeight: 44)
                    }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.navigationTitle("兼容网关")
                .modifier(PilotSettingsPageStyle(showsCloseButton: !embedded, appliesHorizontalMargins: false))
        }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().frame(minHeight: 44)
        }
    }
}

private struct WorkspaceNavigationLabel: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            PilotSettingsRowLabel(title: title, subtitle: subtitle, symbol: symbol)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct WorkspaceSymbolTile: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(PilotPalette.accent)
            .frame(width: size, height: size)
            .background(PilotPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

private struct WorkspaceFeatureHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            WorkspaceSymbolTile(symbol: symbol, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 6)
    }
}

/// Decorative stage artwork never stands in for a setup status or measured pointer.
private struct WorkspaceOnboardingStage: View {
    let step: Int
    let height: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [PilotPalette.accent.opacity(0.11), .clear],
                center: .center, startRadius: 20, endRadius: height * 0.52))
                .frame(width: height * 1.1, height: height * 1.1)
            switch step {
            case 1:
                if UIImage(named: "OnboardingHero") != nil {
                    Image("OnboardingHero").resizable().scaledToFit()
                        .frame(maxHeight: height)
                } else {
                    PilotConnectionIllustration().scaleEffect(1.15)
                }
            case 2:
                PilotPresenceMark(size: height * 0.72, active: true)
                Image(systemName: "sparkles").font(.system(size: 30, weight: .light))
                    .foregroundStyle(PilotPalette.accent).offset(x: height * 0.34, y: -height * 0.22)
            case 3:
                Image(systemName: "viewfinder").font(.system(size: height * 0.60, weight: .ultraLight))
                    .foregroundStyle(PilotPalette.accent.opacity(0.7))
                Image(systemName: "scope").font(.system(size: height * 0.24, weight: .ultraLight))
                    .foregroundStyle(PilotPalette.accent)
            default:
                if UIImage(named: "OnboardingHero") != nil {
                    Image("OnboardingHero").resizable().scaledToFit()
                        .frame(maxHeight: height)
                } else {
                    PilotPresenceMark(size: height * 0.82, active: true)
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct WorkspaceSetupStatus: View {
    let title: String
    let complete: Bool
    var body: some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle.dashed")
            .font(.footnote.weight(.medium))
            .foregroundStyle(complete ? PilotPalette.accent : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(title)，\(complete ? "已设置" : "待设置")")
    }
}

private struct WorkspacePrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glassProminent).tint(PilotPalette.accent)
        } else {
            content.buttonStyle(.borderedProminent).tint(PilotPalette.accent)
        }
    }
}

private struct WorkspaceRowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Shared secondary-page chrome; never disables the navigation or emergency actions.
struct PilotSettingsPageStyle: ViewModifier {
    var showsCloseButton = true
    var appliesHorizontalMargins = true
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .modifier(PilotAppearanceStyle())
            .environment(\.defaultMinListRowHeight, 56)
            .contentMargins(.horizontal, appliesHorizontalMargins ? 20 : 0, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(PilotPalette.canvas)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        PilotCloseButton { dismiss() }
                    }
                }
            }
    }
}

struct PilotSettingsNotice: View {
    let message: String
    var isError = false

    var body: some View {
        if !message.isEmpty {
            Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
