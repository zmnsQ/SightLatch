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
    @State private var confirmTextPlanning = false
    @State private var showExecution = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showsPlanningConversation {
                        planningConversation
                    } else if let command = SharedStore.shared.command {
                        HStack {
                            Spacer(minLength: 36)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text("你").font(.caption).foregroundStyle(.secondary)
                                Text(command.task).textSelection(.enabled)
                                    .padding(16).background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 26))
                            }
                        }
                        if model.status.sessionID == command.id {
                            assistantMessage
                        } else {
                            Text("尚无这条指令的执行结果，请查看下方状态提示。")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 18) {
                            Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 20 : 72)
                            Image("BrandMark").resizable().scaledToFit().frame(width: 48, height: 48).accessibilityHidden(true)
                            Text("想做什么，告诉我。")
                                .font(.title2.bold()).multilineTextAlignment(.center)
                            Text("从一个小目标开始。\n你来决定何时开始，随时停止。")
                                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Spacer(minLength: 48)
                        }.frame(maxWidth: .infinity)
                    }
                    if model.isSessionActive && !model.notice.isEmpty {
                        Label(model.notice, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { composerFocused = false } }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PilotPalette.canvas)
            .navigationTitle("SightLatch").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("任务", systemImage: "clock") { composerFocused = false; showWorkspace = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composerFocused = false; showSettings = true } label: {
                        Label("设置", systemImage: "gearshape")
                            .font(.subheadline).padding(.horizontal, 6).padding(.vertical, 5)
                    }.tint(.primary).accessibilityIdentifier("chat.settings")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .sheet(isPresented: $showDeviceSettings) { DeviceSettingsView() }
            .sheet(isPresented: $showWorkspace) { TaskLibraryView() }
            .sheet(isPresented: $showOnboarding) { OnboardingView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .onDisappear { composerFocused = false }
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
            .onChange(of: model.taskFlow.phase) { _, _ in receiveShortcut() }
            .confirmationDialog("允许所选 AI 规划任务文字？", isPresented: $confirmTextPlanning, titleVisibility: .visible) {
                Button("允许文本规划并发送") {
                    model.configuration.textPlanningConsent = true
                    Task { await model.submitGoal() }
                }
            } message: {
                Text("任务文字会发送给所选 AI 服务，可能受其数据保留和计费规则影响。此同意不包括截图上传或设备控制；可在 AI 账户设置撤回。")
            }
            .confirmationDialog("确认已在目标 App 人工完成或取消提案，并检查风险？", isPresented: $confirmResume, titleVisibility: .visible) {
                Button("已人工处理，重新观察新画面") { model.resumeAfterManual() }
            } message: {
                Text("不会执行旧动作，也不会自动授权设备。授权失效时先停止，再重新发送目标并确认新的计划。")
            }
        }
    }
    private var showsPlanningConversation: Bool {
        model.taskFlow.phase == .planning || model.taskFlow.phase == .awaitingPermission ||
        model.taskFlow.phase == .error || model.taskFlow.phase == .cancelled
    }
    private var planningConversation: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer(minLength: 36)
                Text(model.taskFlow.goal).textSelection(.enabled).padding(16)
                    .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 22))
            }
            Label("SightLatch", systemImage: "sparkles").font(.subheadline.bold())
            if model.taskFlow.phase == .planning {
                HStack(spacing: 10) { ProgressView(); Text("正在根据目标规划…").foregroundStyle(.secondary) }
            }
            if let plan = model.taskFlow.plan, !plan.isEmpty {
                Text(plan).textSelection(.enabled)
                Label("基于目标，尚未观察屏幕", systemImage: "text.bubble")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.taskFlow.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled)
            }
            if model.taskFlow.phase == .cancelled {
                Text("已取消当前任务请求。").foregroundStyle(.secondary)
                if model.status.phase == "停止" {
                    Text(model.status.detail).font(.callout).textSelection(.enabled)
                    Text("最近一次停止结果 · \(model.status.updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.taskFlow.phase == .awaitingPermission, let requestID = model.taskFlow.requestID {
                VStack(alignment: .leading, spacing: 12) {
                    Text("准备好让 SightLatch 看屏幕并操作了吗？").font(.headline)
                    Text("截图将发送到 \(model.configuration.provider == "chatgpt-plan" ? "OpenAI（ChatGPT 套餐）" : (URL(string: model.configuration.endpoint)?.host ?? "所选 AI 服务"))，设备控制最长 5 分钟。下一步仍需你手动确认系统屏幕广播；先离开敏感页面。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("允许屏幕上传与设备控制", systemImage: "hand.raised") {
                        Task { await model.allowPlannedTask(requestID: requestID) }
                    }.buttonStyle(.borderedProminent).tint(PilotPalette.accent)
                        .accessibilityIdentifier("chat.allowPlannedTask")
                        .disabled(model.isSessionActive)
                }.padding(18).background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 20))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 12) {
            if model.prepared {
                HStack(spacing: 12) {
                    BroadcastPicker().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开始屏幕广播").font(.subheadline.bold())
                        Text("点左侧按钮，在系统弹窗中确认。截图会发送给所选服务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField("描述你想完成的事…", text: $model.task, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5).padding(.leading, 16).padding(.vertical, 14)
                    .disabled(model.isSessionActive || showsPlanningConversation && model.taskFlow.phase != .error && model.taskFlow.phase != .cancelled)
                    .accessibilityLabel("任务消息")
                VoiceTaskComposer(text: $model.task).disabled(model.isSessionActive || model.taskFlow.phase == .planning || model.taskFlow.phase == .awaitingPermission)
                if #available(iOS 26.0, *), !reduceTransparency {
                    GlassEffectContainer(spacing: 8) { primaryAction.pilotGlass() }
                } else { primaryAction }
            }
            .padding(6)
            .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 28))
            if model.isSessionActive {
                Text("敏感页面前先结束系统广播。停止未确认时，请拔掉设备 USB 电源。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .background(PilotPalette.canvas)
    }
    // isSessionActive includes preparation, in-flight ARM and STOP fences, not only broadcasting.
    @ViewBuilder private var primaryAction: some View {
        if model.isSessionActive || model.taskFlow.phase == .planning || model.taskFlow.phase == .awaitingPermission {
            Button {
                Task {
                    if model.isSessionActive { await model.stop() }
                    else { await model.cancelPlannedTask() }
                }
            } label: {
                Image(systemName: "stop.fill").font(.body.bold()).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(Color.red, in: Circle())
            .accessibilityLabel(model.stopping ? "正在停止控制" : model.isSessionActive ? "停止控制并撤销设备授权" : "取消当前规划任务")
            .accessibilityIdentifier("chat.stop")
            .disabled(model.stopping)
        } else {
            Button {
                composerFocused = false
                if model.configuration.textPlanningConsent == true { Task { await model.submitGoal() } }
                else { confirmTextPlanning = true }
            } label: {
                Image(systemName: "arrow.up").font(.body.bold()).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(PilotPalette.accent, in: Circle())
            .accessibilityLabel("发送任务并生成计划")
            .accessibilityIdentifier("chat.send")
            .disabled(model.probing || model.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var currentSessionLogs: [LogEntry] {
        model.logs.filter { $0.sessionID == model.status.sessionID }
    }
    private func receiveShortcut() {
        guard !showOnboarding, !model.isSessionActive, model.taskFlow.phase != .planning,
              model.taskFlow.phase != .awaitingPermission, let request = shortcutRouter.consume() else { return }
        if let task = request.task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.task = task }
        if request.startVoice { shortcutRouter.activateVoiceRequest() }
        // Filling the composer never starts control or ReplayKit broadcasting.
    }
}

struct DeviceSettingsView: View {
    @State private var showCalibration = false
    @FocusState private var deviceField: DeviceField?
    private enum DeviceField: Hashable { case address, token }
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PilotConnectionIllustration().listRowBackground(Color.clear)
                }
                Section("局域网连接") {
                    Group {
                        TextField("http://hidbridge.local", text: $model.configuration.deviceURL)
                            .focused($deviceField, equals: .address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("设备 Bearer Token", text: $model.deviceToken)
                            .focused($deviceField, equals: .token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.disabled(model.isSessionActive || model.probing)
                    Text("仅在可信隔离 Wi-Fi 使用；HTTP 会明文传输设备 token 与控制命令。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { DeviceControlPanel(onRequest: { deviceField = nil }).buttonStyle(.bordered) }
                    .listRowBackground(PilotPalette.group)
                Section { Button("指针校准", systemImage: "scope") { deviceField = nil; showCalibration = true } }

                Section { Text("使用“保存并检查连接”保存本页更改。").font(.footnote).foregroundStyle(.secondary) }
            }
            .environment(\.defaultMinListRowHeight, 56)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background { PilotPalette.sheet.contentShape(Rectangle()).onTapGesture { deviceField = nil } }
            .onDisappear { deviceField = nil }
            .navigationTitle("设备设置").navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
            .presentationBackground(PilotPalette.sheet)
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("紧急停止", systemImage: "stop.circle", role: .destructive) { Task { await model.stop() } }
                        .disabled(model.stopping)
                }
                ToolbarItem(placement: .confirmationAction) {
                    PilotCloseButton { deviceField = nil; dismiss() }
                }
            }
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
    var onRequest: () -> Void = {}
    @EnvironmentObject private var model: PilotViewModel
    @State private var deviceSheet: DeviceSheet?
    private enum DeviceSheet: String, Identifiable {
        case probe, pairing
        var id: String { rawValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("设备连接与控制", systemImage: "network").font(.headline)
            Text(model.deviceStatusIsFresh && model.lastDeviceStatus?.hid_connected == true && !model.isSessionActive
                 ? "设备已连接，可发送任务" : model.deviceSummary).font(.caption)
            if let checkedAt = model.deviceStatusCheckedAt, model.deviceStatusIsFresh {
                Text("检查于 \(checkedAt.formatted(date: .omitted, time: .standard)) · 前台定期刷新，状态可能随时变化")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { onRequest(); deviceSheet = .probe; Task { await model.probe() } } label: {
                HStack(spacing: 8) {
                    if model.probing { ProgressView() }
                    Text(model.probing ? "正在检查连接…" : "保存并检查连接")
                }
            }.buttonStyle(.bordered)
                .disabled(model.isSessionActive || model.probing)
                .accessibilityIdentifier("device.probe")
            if !model.probeState.message.isEmpty {
                Text(model.probeState.message).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("device.probe.result")
            }
            if model.softwareControlAvailable {
                Button("开始蓝牙配对") { onRequest(); deviceSheet = .pairing; Task { await model.startPairing() } }
                    .disabled(model.isSessionActive || model.probing || model.lastDeviceStatus?.hid_connected == true)
                Text("配对后即可回到聊天发送任务。先查看 AI 计划，再明确允许截图与设备控制；不会自动开始操作。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.deviceStatusIsFresh {
                Text("此固件使用物理控制，或未声明软件控制能力。请按设备 ARM / STOP 操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("紧急停止控制", role: .destructive) { Task { await model.stop() } }.disabled(model.stopping)
            Text("USB 供电；App 经 Wi-Fi 发送命令，设备经 BLE HID 操作手机。软件停止若失败，请拔掉 USB 电源。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $deviceSheet, onDismiss: {
                model.cancelProbe()
                if model.pairingState.phase == .opening || model.pairingState.phase == .waiting {
                    Task { await model.cancelPairing() }
                }
            }) { destination in
                switch destination {
                case .probe: DeviceProbeResultView()
                case .pairing: DevicePairingResultView()
                }
            }
    }
}

/// A local result sheet. Dismissing invalidates in-flight probe work through cancelProbe.
struct DeviceProbeResultView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    private var succeeded: Bool { model.probeState.phase == .success }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotConnectionIllustration()
                    if model.probing { ProgressView().tint(PilotPalette.accent) }
                    Text(model.probing ? "正在连接设备" : succeeded ? "设备已响应" : "连接未完成")
                        .font(.title2.bold())
                    Text(model.probeState.message).font(.body).textSelection(.enabled)
                        .accessibilityIdentifier("device.probe.sheet.result")
                    if succeeded {
                        Label("接下来：返回设备页检查蓝牙配对，再校准指针。", systemImage: "arrow.right.circle")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("连接检查不会授权控制，也不会发送 HID 操作。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.probing {
                        Text("你可以随时取消。这只检查连接，不会开始接管。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(PilotPalette.sheet)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if model.probing { model.cancelProbe(); dismiss() }
                    else if succeeded { dismiss() }
                    else { Task { await model.probe() } }
                } label: {
                    Text(model.probing ? "取消检查" : succeeded ? "返回设备设置" : "重试连接")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(PilotPalette.accent).padding(24)
                    .background(PilotPalette.sheet)
            }
            .navigationTitle("连接检查").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PilotCloseButton { if model.probing { model.cancelProbe() }; dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("紧急停止", systemImage: "stop.circle", role: .destructive) { Task { await model.stop() } }
                        .disabled(model.stopping)
                }
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .presentationCornerRadius(32).presentationBackground(PilotPalette.sheet)
    }
}

struct DevicePairingResultView: View {
    @StateObject private var accessorySetup = SightLatchAccessorySetupAdapter()
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    private var waiting: Bool { model.pairingState.phase == .opening || model.pairingState.phase == .waiting }
    private var connected: Bool { model.pairingState.phase == .connected }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotConnectionIllustration()
                    if waiting { ProgressView().tint(PilotPalette.accent) }
                    Text(connected ? "设备已连接" : model.pairingState.phase == .opening ? "正在开启配对" : waiting ? "连接 SightLatch" : "配对未完成")
                        .font(.title2.bold())
                    Text(model.pairingState.message).textSelection(.enabled)
                    if waiting {
                        if #available(iOS 18.4, *),
                           model.pairingState.phase == .waiting,
                           model.lastDeviceStatus?.accessorySetupServiceUUID?.uppercased() == SightLatchAccessorySetupAdapter.serviceUUID {
                            Button("在 App 内确认配对（实验性）", systemImage: "rectangle.on.rectangle") {
                                accessorySetup.present(
                                    serviceUUID: model.lastDeviceStatus?.accessorySetupServiceUUID,
                                    pairingWindowIsOpen: model.pairingState.phase == .waiting,
                                    remainingSeconds: model.pairingState.remainingSeconds)
                            }.buttonStyle(.bordered)
                                .disabled(accessorySetup.state == .activating || accessorySetup.state == .presenting)
                        }
                        accessorySetupStatus
                        VStack(alignment: .leading, spacing: 16) {
                            Label("打开 iPhone 的“设置” → “蓝牙”", systemImage: "1.circle")
                            Label("选择设备 SightLatch", systemImage: "2.circle")
                            Label("回到这里查看实际连接结果", systemImage: "3.circle")
                        }.font(.callout)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if model.pairingState.deadline != nil {
                                Label("配对窗口剩余 \(model.pairingState.remainingSeconds) 秒", systemImage: "timer")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Text("打开配对窗口不等于配对成功。此页会读取设备的实际蓝牙状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if connected {
                        Text("设备已连接，可发送任务。板端已确认加密蓝牙连接；任务操作将在你确认 AI 计划后另行请求允许。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(PilotPalette.sheet)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if waiting || connected { dismiss() }
                    else { Task { await model.startPairing() } }
                } label: {
                    Text(waiting ? "取消配对" : connected ? "返回设备设置" : "重新开启配对")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(PilotPalette.accent).padding(24)
                    .background(PilotPalette.sheet)
                    .disabled(!waiting && !connected && model.isSessionActive)
            }
            .navigationTitle("蓝牙配对").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { PilotCloseButton { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("紧急停止", systemImage: "stop.circle", role: .destructive) { Task { await model.stop() } }
                        .disabled(model.stopping)
                }
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .presentationCornerRadius(32).presentationBackground(PilotPalette.sheet)
            .onDisappear { accessorySetup.cancel() }
            .onChange(of: model.pairingState.phase) { _, _ in
                if !waiting { accessorySetup.cancel() }
            }
    }
    @ViewBuilder private var accessorySetupStatus: some View {
        switch accessorySetup.state {
        case .activating, .presenting:
            Text("请在系统配件选择器中确认。完成后仍需核实板端连接。")
                .font(.caption).foregroundStyle(.secondary)
        case .selectedAwaitingVerification:
            Text("已完成系统选择，正在等待设备确认实际连接。")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable(let reason), .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .idle, .cancelled:
            EmptyView()
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

private struct PilotGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(PilotPalette.group, in: Capsule())
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

struct ConfigurationDetailView: View {
    let safety: Bool
    @FocusState private var aiField: AIField?
    private enum AIField: Hashable { case endpoint, model, key }
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false
    var body: some View {
        NavigationStack {
            Form {
                if !safety {
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
                    TextField("完整 HTTPS 请求 URL", text: $model.configuration.endpoint).focused($aiField, equals: .endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("支持视觉的模型 ID", text: $model.configuration.model).focused($aiField, equals: .model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key（空白保留已有值）", text: $model.apiKey).focused($aiField, equals: .key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("OpenAI: /v1/responses\n兼容网关: /v1/chat/completions\nAnthropic: https://api.anthropic.com/v1/messages\nGemini: https://generativelanguage.googleapis.com/v1beta/models/模型ID:generateContent\nGemini 模型以 URL 中的 ID 为准。模型是否支持截图、计费和数据保留由供应商决定。").font(.caption)
                    if model.configuration.provider == "openai" {
                        Toggle("确认此兼容端点与模型支持图片，且我获准用于此用途", isOn: Binding(get: { model.configuration.gatewayVisionConfirmed == true }, set: { model.configuration.gatewayVisionConfirmed = $0 }))
                    }
                    }
                    Toggle("允许所选 AI 规划任务文字", isOn: Binding(
                        get: { model.configuration.textPlanningConsent == true },
                        set: { model.configuration.textPlanningConsent = $0 }))
                    Text("发送目标只做文本规划；截图上传与设备控制需要另行允许。任务文字会发送给所选服务。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("同意将广播中的屏幕截图发给所选服务", isOn: $model.configuration.uploadConsent)
                    Text("会持续发送跨 App 截图；服务方可能保留图像。系统广播许可与此上传同意是两回事。撤回后请立即停止会话。ChatGPT 套餐与 API Key 是独立路径；不会静默切换到 API 计费。").font(.caption).foregroundStyle(.secondary)
                }
                }
                if safety {
                Section("可选后台协调 · iOS26") {
                    if #available(iOS 26.0, *) {
                        Toggle("启用有界后台会话并同意临时本地存帧", isOn: Binding(get: { model.configuration.continuedProcessingEnabled == true }, set: { model.configuration.continuedProcessingEnabled = $0 }))
                    }
                    Text("默认由广播扩展直接处理AI与硬件。可选模式通过系统BGContinuedProcessingTask在主App执行真实AI/动作调度，扩展每秒覆盖一份受保护的最新截图供读取，停止后删除。系统可能拒绝或终止，不保证永久保活或每步刷新；强退后租约失效会停止。需真机验收。").font(.caption).foregroundStyle(.secondary)
                }
                Section("系统权限") {
                    Button("打开系统权限设置", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("麦克风和语音识别仅用于听写草稿；屏幕广播仍需每次由系统确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("安全与节奏") {
                    Stepper("最大 \(model.configuration.maxSteps) 步", value: $model.configuration.maxSteps, in: 1...50)
                    Toggle("允许低风险导航点击和搜索框 ASCII 输入", isOn: $model.configuration.allowLowRiskNavigation)
                    Text("默认谨慎模式仅自动相对移动/滚动，点击和输入交给人工。开启后允许单步导航，不允许提交消息、购买、支付、删除、授权或密码。模型与关键词防线不是安全保证；截图可含误导信息。不能无人值守。").font(.caption).foregroundStyle(.secondary)
                    Text("单次会话上限5分钟；截图超过15秒禁止执行；只允许一个动作在途；失败即暂停；不自动重试动作。").font(.caption)
                }
                }
                Section {
                    if !safety { Button("删除已存密钥", role: .destructive) { showDelete = true } }
                    Text(model.notice).font(.footnote)
                }
            }.buttonStyle(.bordered).disabled(model.isSessionActive || model.probing)
                .environment(\.defaultMinListRowHeight, 56)
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background { PilotPalette.canvas.contentShape(Rectangle()).onTapGesture { aiField = nil } }
                .onDisappear { aiField = nil }
                .onChange(of: model.configuration.endpoint) { _, _ in model.configuration.uploadConsent = false; model.configuration.textPlanningConsent = false; model.configuration.gatewayVisionConfirmed = false }
                .onChange(of: model.configuration.provider) { _, _ in model.configuration.uploadConsent = false; model.configuration.textPlanningConsent = false; model.configuration.gatewayVisionConfirmed = false }
                .onChange(of: model.configuration.model) { _, _ in model.configuration.gatewayVisionConfirmed = false }
                .onChange(of: model.configuration.deviceURL) { _, _ in model.lastDeviceStatus = nil; model.deviceSummary = "设备地址已修改，请重新检查"; model.configuration.relativeModeConfirmed = false }
                .navigationTitle(safety ? "权限与安全" : "AI 账户").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.isSessionActive {
                            Button("停止并撤回上传", role: .destructive) { Task { await model.stopAndRevokeConsent() } }
                        } else { Button("返回") { aiField = nil; dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { aiField = nil; if model.save() { dismiss() } }.disabled(model.isSessionActive) }
                }
                .safeAreaInset(edge: .bottom) {
                    if model.isSessionActive { Text("会话运行中不能编辑；先停止再修改。顶部可立即请求停止并撤回上传。").font(.caption).padding().background(PilotPalette.canvas) }
                }
                .confirmationDialog("删除当前端点和设备的两项凭据？", isPresented: $showDelete) {
                    Button("删除密钥", role: .destructive) { model.deleteSecrets() }
                }
        }
    }
}

/// Guided calibration uses explicit finger markers on iPhone, never fabricated hover samples.
struct CalibrationView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private var needsMarkers: Bool { UIDevice.current.userInterfaceIdiom == .phone || model.automaticCalibration.usesManualMarkers }
    private var busy: Bool { model.automaticCalibration.isBusy }
    private var completed: Bool { model.automaticCalibration.phase == .completed }
    private var unavailable: Bool { model.automaticCalibration.phase == .unavailable }
    private var stage: Int { completed ? 2 : busy ? 1 : 0 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    progressSteps
                    Text(completed ? "指针已准备好" : unavailable ? "还需要检查一下" : model.automaticCalibration.isAwaitingMarker ? "点一下实际指针中心" : needsMarkers ? "点出指针，计算自动完成" : "让我检查一下指针")
                        .font(.title.bold())
                    Text(completed
                         ? (needsMarkers ? "已根据你标记的实际指针位置完成计算与独立验证，并结束校准控制。" : "已根据真实指针观测完成测试，并结束校准控制。")
                         : (needsMarkers ? "需要你点几次屏幕上实际鼠标指针的中心，计算与验证会自动完成。不需要填写参数。" : "留在安全画布上，SightLatch 会尝试读取真实指针位置并完成小范围测试。"))
                        .font(.callout).foregroundStyle(.secondary)
                    PointerCalibrationCanvas(model: model)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(model.automaticCalibration.isAwaitingMarker ? PilotPalette.accent : Color.primary.opacity(0.1), lineWidth: 1).allowsHitTesting(false))
                        .accessibilityLabel("安全指针测试画布")
                    if busy {
                        HStack(alignment: .top, spacing: 12) {
                            if model.automaticCalibration.isAwaitingMarker {
                                Image(systemName: "hand.tap").foregroundStyle(PilotPalette.accent)
                            } else { ProgressView().tint(PilotPalette.accent) }
                            Text(model.automaticCalibration.detail).font(.callout)
                        }
                    } else if !model.automaticCalibration.detail.isEmpty {
                        Label(model.automaticCalibration.detail,
                              systemImage: completed ? "checkmark.circle" : unavailable ? "exclamationmark.circle" : "info.circle")
                            .font(.callout).textSelection(.enabled)
                    }
                    if !completed {
                        Text("开始即允许最长 60 秒的微小指针移动。不会点击、输入文字或运行 AI 任务；只有明确提示你标记时，画布才接收手指位置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if unavailable {
                        Text("未完成测量就不会记录成功。请检查实际鼠标指针是否可见，再按上方具体提示处理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("停止未确认时，请按物理 STOP 或拔掉 USB 电源。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }.background(PilotPalette.canvas)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if busy { Task { await model.cancelAutomaticCalibration() } }
                    else if completed || unavailable { dismiss() }
                    else {
                        Task {
                            if needsMarkers { await model.startAssistedCalibration() }
                            else { await model.startAutomaticCalibration() }
                        }
                    }
                } label: {
                    Text(busy ? "停止校准" : completed ? "完成" : unavailable ? "返回设备设置" : needsMarkers ? "允许并开始辅助校准" : "允许并自动校准")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                    .tint(busy ? .red : PilotPalette.accent)
                    .disabled(!busy && !completed && !unavailable && model.isSessionActive)
                    .padding(24).background(PilotPalette.canvas)
            }
            .navigationTitle("指针校准").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { PilotCloseButton { dismiss() } } }
            .onDisappear { Task { await model.cancelAutomaticCalibration() } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await model.cancelAutomaticCalibration() } }
            }
        }
    }
    private var progressSteps: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { index in
                HStack(spacing: 7) {
                    Image(systemName: index < stage ? "checkmark.circle.fill" : "\(index + 1).circle")
                    Text(["准备", "测试", "完成"][index]).font(.subheadline)
                }.foregroundStyle(index == stage ? Color.primary : Color.secondary)
                if index < 2 { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
            }
        }.accessibilityElement(children: .combine)
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

/// Semantic surfaces follow the user's selected light/dark appearance.
enum PilotPalette {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .systemBackground
    })
    static let group = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 1) : .secondarySystemBackground
    })
    static let sheet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.105, alpha: 1) : .systemBackground
    })
    static let accent = Color.blue
}

struct PilotCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .background(PilotPalette.group, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("关闭")
    }
}

struct PilotConnectionIllustration: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if UIImage(named: "DeviceConnectionIllustration") != nil {
                Image("DeviceConnectionIllustration").resizable().scaledToFit()
                    .padding(8)
                    .background(colorScheme == .light ? Color(white: 0.14) : .clear, in: RoundedRectangle(cornerRadius: 24))
            } else {
                HStack(spacing: 30) {
                    Image(systemName: "iphone").font(.system(size: 76, weight: .ultraLight))
                    Image(systemName: "arrow.left.arrow.right").font(.title2.weight(.light)).foregroundStyle(PilotPalette.accent)
                    Image(systemName: "cpu").font(.system(size: 72, weight: .ultraLight))
                }.foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).frame(height: 148)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("iPhone 与 SightLatch 设备连接示意")
    }
}
