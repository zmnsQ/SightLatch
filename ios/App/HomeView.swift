import SwiftUI
import ReplayKit

struct HomeView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var shortcutRouter = PilotShortcutRouter.shared
    @ObservedObject private var sessionVoice = SessionVoiceController.shared
    @ObservedObject private var voiceFeedback = VoiceFeedbackPreferences.shared
    @ObservedObject private var liveActivity = PilotActivityManager.shared
    @State private var showSettings = false
    @State private var showDeviceSettings = false
    @State private var showAISettings = false
    @State private var showCalibration = false
    @State private var showWorkspace = false
    @State private var showOnboarding = false
    @State private var showExecution = false
    @State private var showSessionNotes = false
    @State private var showRunDuration = false
    @State private var confirmUnlimitedRun = false
    @State private var pendingUnlimitedRequestID: UUID?
    @State private var followsLatest = true
    @State private var userScrolling = false
    @State private var hasUnreadUpdate = false
    @FocusState private var composerFocused: Bool
    @AccessibilityFocusState private var broadcastFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showsPlanningConversation {
                        planningConversation
                    } else if let command = SharedStore.shared.command {
                        HStack {
                            Spacer(minLength: 36)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(command.task).textSelection(.enabled)
                                    .padding(16).background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 26))
                            }
                        }
                        if model.status.sessionID == command.id {
                            assistantMessage
                        } else {
                            Text("准备好后，就可以开始。")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        welcomeState
                    }
                    if needsStopAttention {
                        Label("设备停止待确认，请断开设备电源并结束屏幕共享。", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                    } else if model.isSessionActive,
                        let notice = HomeNoticePresentation.visibleNotice(model.notice, command: SharedStore.shared.command, status: model.status) {
                        DisclosureGroup("会话提示", isExpanded: $showSessionNotes) {
                            Text(notice).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("latest-state")
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: model.status.phase)
                .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: model.taskFlow.phase)
                .padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { composerFocused = false } }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 60
            } action: { _, atBottom in
                if atBottom { followsLatest = true; hasUnreadUpdate = false }
                else if userScrolling { followsLatest = false }
            }
            .onChange(of: conversationUpdate) { _, _ in
                if followsLatest {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo("latest-state", anchor: .bottom) }
                } else { hasUnreadUpdate = true }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasUnreadUpdate {
                    Button("查看最新状态", systemImage: "arrow.down") {
                        followsLatest = true; hasUnreadUpdate = false
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo("latest-state", anchor: .bottom) }
                    }.font(.caption).pilotAction(prominent: false).padding(16)
                }
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
                            .font(.subheadline)
                    }.tint(.primary).accessibilityIdentifier("chat.settings")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .sheet(isPresented: $showDeviceSettings) { DeviceSettingsView().modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showAISettings) { ConfigurationDetailView(safety: false).modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showWorkspace) { TaskLibraryView().modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showOnboarding) { OnboardingView().modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showSettings) { SettingsView().modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showRunDuration) { RunDurationSettingsView().modifier(PilotAppearanceStyle()) }
            .sheet(isPresented: $showCalibration) { CalibrationView(returnsToTask: true).modifier(PilotAppearanceStyle()) }
            .alert("本次任务不限时？", isPresented: $confirmUnlimitedRun) {
                Button("取消", role: .cancel) { pendingUnlimitedRequestID = nil }
                Button("确认开始") { submitConfirmedUnlimitedRun() }
            } message: {
                Text("任务完成后自动结束。你可以随时停止；系统中断或设备断线时会暂停。")
            }
            .onDisappear { composerFocused = false }
            .onAppear {
                showOnboarding = !model.workspace.onboardingComplete
                receiveShortcut()
            }
            .onOpenURL { url in
                guard url.scheme == "sightlatch", url.host == "chat" else { return }
                showSettings = false; showDeviceSettings = false; showAISettings = false; showCalibration = false
                showWorkspace = false; showOnboarding = false
                // Deep links only reveal chat. They never send a task or grant control.
            }
            .onChange(of: shortcutRouter.pendingRequest?.id) { _, _ in receiveShortcut() }
            .onChange(of: showOnboarding) { _, shown in if !shown { receiveShortcut() } }
            .onChange(of: model.isSessionActive) { _, active in if !active { receiveShortcut() } }
            .onChange(of: model.prepared) { _, prepared in
                if prepared { composerFocused = false; broadcastFocused = true }
            }
            .onChange(of: model.taskFlow.phase) { _, _ in receiveShortcut() }
            }
        }
    }
    private var needsStopAttention: Bool {
        PilotTaskResultPresentation.needsStopAttention(phase: model.status.phase, detail: model.status.detail) ||
        PilotTaskResultPresentation.needsStopAttention(phase: "", detail: model.notice)
    }
    private var welcomeState: some View {
        VStack(spacing: 22) {
            Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 8 : 38)
            PilotPresenceMark(size: 148, active: false)
            VStack(spacing: 10) {
                Text("想做什么，告诉我。")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                Text("一句话，让想法变成行动。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    Label("看见屏幕", systemImage: "viewfinder")
                    Label("帮你操作", systemImage: "cursorarrow.rays")
                }
                VStack(spacing: 10) {
                    Label("看见屏幕", systemImage: "viewfinder")
                    Label("帮你操作", systemImage: "cursorarrow.rays")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            Spacer(minLength: 24)
        }.frame(maxWidth: .infinity)
    }
    private var conversationUpdate: String {
        "\(model.taskFlow.phase)|\(model.taskFlow.plan ?? "")|\(model.taskFlow.errorMessage ?? "")|\(model.taskFlow.prerequisites.map { "\($0.id):\($0.detail)" }.joined(separator: "|"))|\(model.status.sessionID)|\(model.status.phase)|\(model.status.detail)|\(currentSessionLogs.last?.id ?? "")"
    }
    private var showsPlanningConversation: Bool {
        model.taskFlow.phase == .planning || model.taskFlow.phase == .prerequisites || model.taskFlow.phase == .awaitingPermission ||
        model.taskFlow.phase == .error || model.taskFlow.phase == .cancelled ||
        (model.taskFlow.phase == .ready && !model.prepared)
    }
    private var planningConversation: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer(minLength: 36)
                Text(model.taskFlow.goal).textSelection(.enabled).padding(16)
                    .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 22))
            }
            HStack(spacing: 10) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 24, height: 24).accessibilityHidden(true)
                Text("SightLatch").font(.subheadline.weight(.semibold))
            }
            if model.checkingTaskPrerequisites || model.taskFlow.phase == .planning || model.taskFlow.phase == .ready {
                PilotThinkingIndicator(title: "正在准备")
                Text("准备好后，开始共享屏幕。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.taskFlow.phase != .prerequisites, let error = model.taskFlow.errorMessage, !error.isEmpty {
                Label("暂时无法开始", systemImage: "exclamationmark.circle").font(.headline)
                DisclosureGroup("查看原因") {
                    Text(error).font(.callout).textSelection(.enabled)
                }.font(.subheadline)
                HStack(spacing: 20) {
                    Button("编辑任务", systemImage: "pencil") { composerFocused = true }
                    Button("检查 AI 账户", systemImage: "person.crop.circle") { composerFocused = false; showAISettings = true }
                }.font(.subheadline).buttonStyle(.borderless)
            }
            if model.taskFlow.phase == .prerequisites {
                prerequisitesCard
            }
            if model.taskFlow.phase == .cancelled {
                Text(model.stopping ? "正在停止…" : needsStopAttention ? "设备停止待确认" : "已结束")
                    .font(.headline)
                if let caution = resultPresentation.caution {
                    Label(caution, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                }
                if let sessionID = model.taskFlow.sessionID, model.status.sessionID == sessionID,
                   !model.status.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("查看详情") {
                        Text(model.presentedStatusDetail(model.status.detail)).font(.callout).textSelection(.enabled)
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var prerequisitesCard: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 12) { prerequisitesContent }
        } else {
            prerequisitesContent
        }
    }
    private var prerequisitesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            prerequisiteRows
            if !model.taskFlow.prerequisites.allSatisfy({ $0.kind == .retry }) {
                Button {
                    resumePrerequisites()
                } label: {
                    HStack(spacing: 8) {
                        if model.checkingTaskPrerequisites { ProgressView() }
                        Text(model.checkingTaskPrerequisites ? "正在准备…" : "继续此任务")
                    }
                }.pilotAction(prominent: true, fullWidth: true)
                    .disabled(cannotResumePrerequisites)
                    .accessibilityIdentifier("chat.resumePrerequisites")
            }
        }.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("chat.prerequisites")
    }
    private var prerequisiteRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.taskFlow.prerequisites) { prerequisite in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: prerequisiteSymbol(prerequisite.kind))
                            .foregroundStyle(PilotPalette.accent)
                        Text(prerequisite.title)
                    }.font(.headline)
                    Text(prerequisiteSummary(prerequisite.kind)).font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("详情") {
                        Text(prerequisite.detail).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(.secondary)
                    Button {
                        composerFocused = false
                        switch prerequisite.kind {
                        case .calibration:
                            showCalibration = true
                        case .model, .aiConnection:
                            showAISettings = true
                        case .deviceConnection, .bluetoothPairing, .deviceControl:
                            showDeviceSettings = true
                        case .settings:
                            showSettings = true
                        case .retry:
                            resumePrerequisites()
                        }
                    } label: {
                        Label(prerequisite.actionTitle, systemImage: prerequisiteSymbol(prerequisite.kind))
                    }.pilotAction(prominent: false)
                        .disabled(cannotResumePrerequisites)
                        .accessibilityIdentifier("chat.prerequisite.\(prerequisite.id)")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func prerequisiteSummary(_ kind: TaskPrerequisite.Kind) -> String {
        switch kind {
        case .calibration: return "校准一次，让点击更准确。"
        case .model, .aiConnection: return "连接一个可用的 AI 服务。"
        case .deviceConnection: return "让手机和设备连接同一 Wi-Fi。"
        case .bluetoothPairing: return "连接 SightLatch 的蓝牙。"
        case .deviceControl: return "检查设备是否已准备好。"
        case .settings: return "完成设置后即可继续。"
        case .retry: return "检查连接后再试一次。"
        }
    }
    private func prerequisiteSymbol(_ kind: TaskPrerequisite.Kind) -> String {
        switch kind {
        case .calibration: return "scope"
        case .model, .aiConnection: return "sparkles"
        case .deviceConnection: return "wifi"
        case .bluetoothPairing: return "antenna.radiowaves.left.and.right"
        case .deviceControl: return "computermouse"
        case .settings: return "gearshape"
        case .retry: return "arrow.clockwise"
        }
    }
    private var cannotResumePrerequisites: Bool {
        model.checkingTaskPrerequisites || model.isSessionActive || model.probing || model.automaticCalibration.isBusy
    }
    private func resumePrerequisites() {
        guard !cannotResumePrerequisites, let requestID = model.taskFlow.requestID else { return }
        composerFocused = false
        if model.configuration.unlimitedRun == true {
            pendingUnlimitedRequestID = requestID
            confirmUnlimitedRun = true
            return
        }
        Task {
            await model.resumePlannedTask(requestID: requestID)
        }
    }
    private func submitConfirmedUnlimitedRun() {
        let requestID = pendingUnlimitedRequestID
        pendingUnlimitedRequestID = nil
        Task {
            if let requestID {
                guard model.taskFlow.requestID == requestID, !cannotResumePrerequisites else { return }
                await model.resumePlannedTask(requestID: requestID, unlimitedConfirmed: true)
            } else {
                guard !model.isSessionActive, !model.taskFlow.isBusy else { return }
                await model.submitGoal(unlimitedConfirmed: true)
            }
        }
    }
    private var resultPresentation: PilotTaskResultPresentation {
        let command = SharedStore.shared.command
        let scope = command?.id == model.status.sessionID ? command?.messageScope : nil
        return PilotTaskResultPresentation(phase: model.status.phase,
            detail: model.presentedStatusDetail(model.status.detail),
            messageVerified: scope?.verified == true, sendAttempted: scope?.sendAttempted == true,
            pasteAttempted: scope?.pasteAttempted == true)
    }
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 22, height: 22).accessibilityHidden(true)
                Text("SightLatch").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.status.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if resultPresentation.active || model.status.phase == "待广播" {
                executionPresence
            } else {
                HStack(alignment: .top, spacing: 16) {
                    PilotStatusGlyph(symbol: resultPresentation.symbol, tint: resultPresentation.tint, active: false)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(resultPresentation.title)
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                        Text(resultPresentation.subtitle)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 10)
            }
            if let message = model.status.userMessage, !message.isEmpty {
                Label(message, systemImage: "bubble.left")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14).padding(.vertical, 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(PilotPalette.accent).frame(width: 3)
                    }.accessibilityLabel("AI 提示：\(message)")
            }
            if let caution = resultPresentation.caution {
                Label(caution, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            if let command = SharedStore.shared.command, command.running,
               let question = command.pendingClarification {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(question.options) { option in
                        Button {
                            Task { await model.answerClarification(questionID: question.id, optionID: option.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Text(option.title).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                            }.frame(minHeight: 28)
                        }.pilotAction(prominent: false)
                            .disabled(model.stopping)
                            .accessibilityIdentifier("chat.answer.\(option.id)")
                    }
                }.padding(.vertical, 8)
            }
            if model.status.phase == "暂停", SharedStore.shared.command?.running == true {
                Button("结束任务", systemImage: "stop.fill") {
                    Task { await model.endPausedSession() }
                }.pilotAction(prominent: false)
                    .disabled(model.stopping)
                    .accessibilityIdentifier("chat.endPausedSession")
            }
            DisclosureGroup(isExpanded: $showExecution) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.presentedStatusDetail(model.status.detail))
                        .font(.callout).textSelection(.enabled)
                    if model.status.phase == "暂停" {
                        Text(model.recovery.steps).font(.footnote).foregroundStyle(.secondary)
                    }
                    if currentSessionLogs.isEmpty {
                        Text("还没有执行记录").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(currentSessionLogs.suffix(20))) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(PilotPalette.accent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 7)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.presentedStatusDetail(item.message)).font(.footnote).textSelection(.enabled)
                                Text(item.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 16)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                    Text("执行详情")
                    Spacer()
                    if model.status.steps > 0 { Text("\(model.status.steps) 步").monospacedDigit() }
                }.font(.caption).foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
            .tint(.secondary)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: showExecution)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var executionPresence: some View {
        VStack(spacing: 18) {
            PilotPresenceMark(size: dynamicTypeSize.isAccessibilitySize ? 96 : 154,
                              active: resultPresentation.active)
            VStack(spacing: 9) {
                Text(resultPresentation.title)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .contentTransition(.interpolate)
                Text(resultPresentation.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.multilineTextAlignment(.center)
            if model.status.steps > 0 {
                HStack(spacing: 8) {
                    Image(systemName: resultPresentation.symbol)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    Text("第 \(model.status.steps) 步").monospacedDigit().contentTransition(.numericText())
                }.font(.caption.weight(.medium)).foregroundStyle(PilotPalette.accent)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isSessionActive && !showsPlanningConversation {
                HStack {
                    Button { composerFocused = false; showAISettings = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text(model.configuration.provider == "chatgpt-plan" ? "ChatGPT" : model.selectedProfileName)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button { composerFocused = false; showRunDuration = true } label: {
                        Label(model.configuration.unlimitedRun == true ? "不限时" : "\(model.configuration.selectedRunDurationSeconds / 60) 分钟",
                              systemImage: model.configuration.unlimitedRun == true ? "infinity" : "clock")
                            .font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel("设置运行时长")
                        .accessibilityValue(model.configuration.unlimitedRun == true ? "不限时" : "\(model.configuration.selectedRunDurationSeconds / 60) 分钟")
                }.padding(.horizontal, 12)
            }
            if !model.prepared { captureProgress }
            if model.prepared || model.taskFlow.phase == .ready {
                HStack(spacing: 12) {
                    // Keep the picker and its presenting host alive through broadcast startup.
                    BroadcastPicker().frame(width: 44, height: 44)
                        .disabled(!model.prepared || model.stopping)
                        .accessibilityFocused($broadcastFocused)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(captureState.title)
                            .font(.title3.bold())
                        Text(captureState == .ready ? "屏幕将共享给所选 AI" : captureState.detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if model.prepared { primaryAction }
                }.padding(.vertical, 4)
                if model.prepared {
                    if #available(iOS 26.0, *), !reduceTransparency {
                        GlassEffectContainer(spacing: 12) { sessionAudioControls }
                    } else { sessionAudioControls }
                    if [.disabled, .failed, .waitingForForeground, .ended].contains(liveActivity.availability), !liveActivity.message.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Label(liveActivity.message, systemImage: "rectangle.topthird.inset.filled")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("重试") { Task { _ = await liveActivity.retry() } }
                                .font(.caption).buttonStyle(.plain)
                        }.accessibilityIdentifier("chat.liveActivityIssue")
                    }
                    if !sessionVoice.message.isEmpty && !sessionVoice.isEnabled {
                        DisclosureGroup("语音提示") {
                            Text(sessionVoice.message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.prepared {
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("描述你想完成的事…", text: $model.task, axis: .vertical)
                        .focused($composerFocused)
                        .lineLimit(1...5).padding(.leading, 16).padding(.vertical, 14)
                        .disabled(model.isSessionActive || showsPlanningConversation && model.taskFlow.phase != .error && model.taskFlow.phase != .cancelled)
                        .accessibilityLabel("任务消息")
                    VoiceTaskComposer(text: $model.task).disabled(model.isSessionActive || model.taskFlow.isBusy || model.taskFlow.phase == .prerequisites || model.taskFlow.phase == .awaitingPermission)
                    if #available(iOS 26.0, *), !reduceTransparency {
                        GlassEffectContainer(spacing: 8) { primaryAction }
                    } else { primaryAction }
                }
                .padding(6)
                .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 28))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(PilotPalette.accent.opacity(composerFocused ? 0.45 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: composerFocused)
            }
        }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 10)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .background(PilotPalette.canvas)
    }
    private var sessionAudioControls: some View {
        HStack(spacing: 12) {
            Text(sessionVoice.isRequestingPermission ? "正在开启语音…" : sessionVoice.isSpeaking ? "正在播报" : sessionVoice.isListening ? "说“小视”，继续吩咐" : sessionVoice.isEnabled ? "语音已开启" : "语音")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                if sessionVoice.isEnabled { sessionVoice.stop() }
                else { Task { await model.enableSessionVoice() } }
            } label: {
                Image(systemName: sessionVoice.isEnabled ? "mic.fill" : "mic.slash")
            }.pilotAction(prominent: false, iconOnly: true)
                .accessibilityLabel(sessionVoice.isEnabled ? "关闭会话语音" : "开启会话语音")
                .accessibilityIdentifier("chat.sessionVoice")
                .disabled(model.stopping)
            Button {
                voiceFeedback.spokenFeedbackEnabled.toggle()
            } label: {
                Image(systemName: voiceFeedback.spokenFeedbackEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }.pilotAction(prominent: false, iconOnly: true)
                .accessibilityLabel(voiceFeedback.spokenFeedbackEnabled ? "静音任务播报" : "开启任务播报")
                .accessibilityHint("只切换播报，保留当前麦克风监听状态")
                .accessibilityIdentifier("chat.spokenFeedback")
        }
    }
    private var currentCapture: CaptureObservation? {
        HomeCaptureState.currentObservation(model.captureObservation, command: SharedStore.shared.command)
    }
    private var captureState: HomeCaptureState {
        HomeCaptureState.resolve(preparing: model.taskFlow.phase == .planning || (model.taskFlow.phase == .ready && !model.prepared),
            prepared: model.prepared, command: SharedStore.shared.command, status: model.status, observation: currentCapture)
    }
    @ViewBuilder private var captureProgress: some View {
        if [.preparing, .waiting, .interrupted, .paused].contains(captureState) {
            Label(captureState.title, systemImage: captureState == .capturing ? "record.circle" : "rectangle.dashed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    // isSessionActive includes preparation, in-flight ARM and STOP fences, not only broadcasting.
    @ViewBuilder private var primaryAction: some View {
        if model.isSessionActive || model.taskFlow.isBusy || model.taskFlow.phase == .prerequisites || model.taskFlow.phase == .awaitingPermission {
            Button {
                Task {
                    if model.isSessionActive {
                        if model.status.phase == "暂停", model.status.sessionID == SharedStore.shared.command?.id {
                            await model.endPausedSession()
                        } else { await model.stop() }
                    }
                    else { await model.cancelPlannedTask() }
                }
            } label: {
                Image(systemName: "stop.fill")
            }
            .pilotAction(prominent: true, tint: .red, iconOnly: true)
            .accessibilityLabel(model.stopping ? "正在停止控制" : model.isSessionActive ? "停止控制并撤销设备授权" : "取消当前任务")
            .accessibilityIdentifier("chat.stop")
            .disabled(model.stopping)
        } else {
            Button {
                composerFocused = false
                if model.configuration.unlimitedRun == true {
                    pendingUnlimitedRequestID = nil
                    confirmUnlimitedRun = true
                } else { Task { await model.submitGoal() } }
            } label: {
                Image(systemName: "arrow.up")
            }
            .pilotAction(prominent: true, iconOnly: true)
            .accessibilityLabel("发送目标并准备屏幕会话")
            .accessibilityIdentifier("chat.send")
            .disabled(model.probing || model.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var currentSessionLogs: [LogEntry] {
        model.logs.filter { $0.sessionID == model.status.sessionID }
    }
    private func receiveShortcut() {
        guard !showOnboarding, !model.isSessionActive, model.taskFlow.phase != .planning,
              model.taskFlow.phase != .prerequisites, model.taskFlow.phase != .awaitingPermission,
              let request = shortcutRouter.consume() else { return }
        if let task = request.task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.task = task }
        if request.startVoice { shortcutRouter.activateVoiceRequest() }
        // Filling the composer never starts control or ReplayKit broadcasting.
    }
}

/// A compact presentation of recorded state; it never changes the execution result.
struct PilotTaskResultPresentation {
    let phase: String
    let detail: String
    let messageVerified: Bool
    let sendAttempted: Bool
    let pasteAttempted: Bool
    static func needsStopAttention(phase: String, detail: String) -> Bool {
        phase == "请核实硬件停止" || ["停止未确认", "未确认停止", "无法确认停止", "STOP 未确认", "STOP未确认", "停止确认失败", "未确认硬件停止", "未确认设备停止", "本地停止写入失败"].contains(where: detail.contains)
    }
    var stopUnconfirmed: Bool { Self.needsStopAttention(phase: phase, detail: detail) }
    var active: Bool {
        !stopUnconfirmed && ["准备", "观察", "广播中", "规划", "思考", "执行"].contains(phase)
    }
    var title: String {
        if stopUnconfirmed { return "请停止设备" }
        if phase == "等待用户" { return "等你选择" }
        if phase == "暂停" { return "需要你看一下" }
        if phase == "完成" && messageVerified { return "已完成" }
        if sendAttempted && !messageVerified { return active ? "正在核对发送结果" : "发送结果待核对" }
        switch phase {
        case "待广播": return "准备就绪"
        case "准备": return "正在准备"
        case "观察", "广播中": return "正在看屏幕"
        case "规划", "思考": return "正在思考下一步"
        case "执行": return "正在操作"
        case "完成": return "执行已结束"
        case "停止": return "已停止"
        default: return "当前任务"
        }
    }
    var subtitle: String {
        if stopUnconfirmed { return "请断开设备电源，确保操作停止。" }
        if phase == "等待用户" { return "选择后，我会接着完成当前任务。" }
        if phase == "完成" && messageVerified { return "已在聊天画面中确认消息。" }
        if phase == "暂停" || phase == "停止" {
            if sendAttempted && !messageVerified { return "发送结果尚未确认，请查看目标聊天。" }
            if detail.contains("用户") && detail.contains("停止") { return "操作已结束。" }
            if ["执行期限已结束", "准备期限", "会话已到期", "任务已超时"].contains(where: detail.contains) { return "本次任务已到期。需要继续时，发送新任务。" }
            if detail.contains("硬件") && detail.contains("超时") { return "操作结果尚未确认，请检查当前画面。" }
            if ["网络", "连接失败", "timed out", "offline"].contains(where: detail.contains) { return "连接中断，请检查网络与设备。" }
            if detail.contains("校准") { return "请先在设备设置中重新校准。" }
            if ["画面", "置信度", "把握", "ask_user"].contains(where: detail.contains) { return "当前画面需要你确认，请查看执行详情。" }
            return "查看执行详情，了解停在哪一步。"
        }
        if sendAttempted && !messageVerified { return active ? "正在查看聊天画面。" : "请核对目标聊天中的实际结果。" }
        switch phase {
        case "待广播": return "开始共享屏幕，接下来交给我。"
        case "准备": return "正在连接 AI 和设备。"
        case "观察", "广播中": return "正在理解当前画面。"
        case "规划", "思考": return "根据画面安排下一步。"
        case "执行": return "正在完成这一步操作。"
        case "完成": return "请核对目标 App 中的实际结果。"
        default: return "展开详情查看当前进展。"
        }
    }
    var caution: String? {
        if stopUnconfirmed { return nil }
        if sendAttempted && !messageVerified && !active { return "已尝试发送，请先核对结果，避免重复。" }
        if pasteAttempted && !sendAttempted && ["暂停", "停止"].contains(phase) { return "输入框中可能已有正文，请先核对。" }
        return nil
    }
    var symbol: String {
        if stopUnconfirmed { return "exclamationmark.triangle" }
        if phase == "暂停" { return "pause" }
        if phase == "完成" && messageVerified { return "checkmark" }
        if phase == "停止" { return "stop" }
        if phase == "完成" { return "checklist" }
        if phase == "待广播" { return "record.circle" }
        if phase == "执行" { return "cursorarrow.rays" }
        return "viewfinder"
    }
    var tint: Color {
        stopUnconfirmed || phase == "暂停" ? .orange : PilotPalette.accent
    }
}

struct DeviceSettingsView: View {
    var embedded = false
    @State private var showCalibration = false
    @FocusState private var deviceField: DeviceField?
    private enum DeviceField: Hashable { case address, token }
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotSettingsHero(kind: .device, title: "连接你的设备", subtitle: "Wi-Fi 接收任务，蓝牙连接手机。")
                    DeviceConnectionStatus()
                    PilotSettingsCard {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("设备地址").font(.subheadline).foregroundStyle(.secondary)
                            TextField("http://hidbridge.local", text: $model.configuration.deviceURL)
                                .focused($deviceField, equals: .address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .frame(minHeight: 32)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            Text("控制令牌").font(.subheadline).foregroundStyle(.secondary)
                            SecureField("留空以保留已存令牌", text: $model.deviceToken)
                                .focused($deviceField, equals: .token)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .frame(minHeight: 32)
                        }
                    }.disabled(model.isSessionActive || model.probing)
                    DeviceControlPanel(onRequest: { deviceField = nil })
                    PilotSettingsCard {
                        Button { deviceField = nil; showCalibration = true } label: {
                            HStack(spacing: 12) {
                                PilotSettingsRowLabel(title: "屏幕校准", subtitle: "自动测量设备的实际点击位置", symbol: "scope")
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .modifier(PilotSettingsPageStyle(showsCloseButton: false, appliesHorizontalMargins: false))
            .scrollDismissesKeyboard(.interactively)
            .background { PilotPalette.canvas.contentShape(Rectangle()).onTapGesture { deviceField = nil } }
            .onDisappear { deviceField = nil }
            .navigationTitle("设备设置").navigationBarTitleDisplayMode(.inline)
            .modifier(DeviceSettingsPresentationStyle(embedded: embedded))
            .sheet(isPresented: $showCalibration) { CalibrationView().modifier(PilotAppearanceStyle()) }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) {
                        PilotCloseButton { deviceField = nil; dismiss() }
                    }
                }
            }
            .onChange(of: model.configuration.deviceURL) { _, _ in
                model.lastDeviceStatus = nil
                model.deviceStatusCheckedAt = nil
                model.deviceSummary = "设备地址已修改，请重新检查"
                model.configuration.invalidatePointerCalibration()
            }
        }
    }
}

private struct DeviceSettingsPresentationStyle: ViewModifier {
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationBackground(PilotPalette.sheet)
        }
    }
}

private struct DeviceConnectionStatus: View {
    @EnvironmentObject private var model: PilotViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PilotSettingsCard {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { connectionStages }
                    VStack(alignment: .leading, spacing: 16) { connectionStages }
                }
            }
            if !(model.deviceStatusIsFresh && model.lastDeviceStatus?.hid_connected == true && !model.isSessionActive) {
                Text(model.deviceSummary).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let checkedAt = model.deviceStatusCheckedAt, model.deviceStatusIsFresh {
                Text("检查于 \(checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
    @ViewBuilder private var connectionStages: some View {
        connectionStage("局域网", symbol: "wifi", ready: model.deviceStatusIsFresh && model.lastDeviceStatus != nil)
        connectionStage("蓝牙", symbol: "computermouse", ready: model.deviceStatusIsFresh && model.lastDeviceStatus?.hid_connected == true)
    }
    private func connectionStage(_ title: String, symbol: String, ready: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.title3).foregroundStyle(ready ? PilotPalette.accent : Color.secondary)
                .frame(width: 27).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Label(ready ? "已连接" : "尚未确认", systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption).foregroundStyle(ready ? PilotPalette.accent : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(ready ? "已确认连接" : "尚未确认连接")")
    }
}

// Shared device control surface. STOP stays available while ARM/PAIR is in flight.
struct DeviceControlPanel: View {
    var onRequest: () -> Void = {}
    @EnvironmentObject private var model: PilotViewModel
    @State private var deviceSheet: DeviceSheet?
    private enum DeviceSheet: String, Identifiable {
        case probe, pairing, systemMousePairing
        var id: String { rawValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button { onRequest(); deviceSheet = .probe; Task { await model.probe() } } label: {
                HStack(spacing: 8) {
                    if model.probing { ProgressView() }
                    Text(model.probing ? "正在检查连接…" : "保存并检查连接")
                }
            }.pilotAction(prominent: true, fullWidth: true)
                .disabled(model.isSessionActive || model.probing)
                .accessibilityIdentifier("device.probe")
            // Historical failures remain available; the live summary above owns current state.
            if model.probeState.phase != .idle && model.probeState.phase != .success,
               !model.probeState.message.isEmpty && model.probeState.message != model.deviceSummary {
                PilotSettingsCard {
                    DisclosureGroup("上次检查结果") {
                        Text(model.probeState.message).font(.callout).textSelection(.enabled)
                            .accessibilityIdentifier("device.probe.result")
                    }.font(.subheadline)
                }
            }
            if model.softwareControlAvailable {
                PilotSettingsCard {
                    Button { onRequest(); deviceSheet = .pairing; Task { await model.startPairing() } } label: {
                        HStack(spacing: 12) {
                            PilotSettingsRowLabel(title: "开始蓝牙配对", subtitle: "开启本次设备配对窗口", symbol: "antenna.radiowaves.left.and.right")
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(model.isSessionActive || model.probing || model.lastDeviceStatus?.hid_connected == true)
                    Divider()
                    Button {
                        onRequest(); deviceSheet = .systemMousePairing
                        Task { await model.startPairing(usingSystemMouse: true) }
                    } label: {
                        HStack(spacing: 12) {
                            PilotSettingsRowLabel(title: "通过系统连接鼠标", subtitle: "使用 iPhone 的系统蓝牙入口", symbol: "computermouse")
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(model.isSessionActive || model.probing)
                        .accessibilityIdentifier("device.systemMousePairing")
                }
            } else if model.deviceStatusIsFresh {
                Text("请通过设备上的实体按钮开启或停止控制。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup("连接与设备说明") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("手机与设备需连接同一 Wi-Fi。请使用可信网络；HTTP 连接未加密。")
                    Text("设备使用 USB 供电，通过蓝牙操作手机。连接后需完成屏幕校准。若停止无响应，请断开设备电源。")
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $deviceSheet, onDismiss: {
                model.cancelProbe()
                if model.pairingState.phase == .opening || model.pairingState.phase == .waiting {
                    Task { await model.cancelPairing() }
                }
            }) { destination in
                switch destination {
                case .probe: DeviceProbeResultView().modifier(PilotAppearanceStyle())
                case .pairing: DevicePairingResultView().modifier(PilotAppearanceStyle())
                case .systemMousePairing: DevicePairingResultView(usesSystemMouse: true).modifier(PilotAppearanceStyle())
                }
            }
    }
}

/// Keep result copy at its natural height and clear of the fixed footer.
private struct PilotResultScrollView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        }
    }
}

/// Fit the whole result, including navigation and footer insets, instead of jumping to large.
private struct PilotResultSheetStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var requiredHeight: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 0
    @State private var expanded = false

    private var fittedDetent: PresentationDetent {
        guard requiredHeight > 0 else { return .medium }
        // Fixed-height detents add the system's bottom safe area themselves.
        return .height(max(280, ceil(requiredHeight - bottomSafeArea)))
    }

    func body(content: Content) -> some View {
        content
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // These native insets include the toolbar and the fixed action area.
            ceil(geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom)
        } action: { _, height in
            if height > 0 { requiredHeight = height }
        }
        .onGeometryChange(for: CGFloat.self) { max(0, $0.safeAreaInsets.bottom) } action: { bottomSafeArea = $0 }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [fittedDetent, .large], selection: Binding(
            get: { dynamicTypeSize.isAccessibilitySize || expanded ? .large : fittedDetent },
            set: { expanded = $0 == .large }))
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PilotMetrics.sheetCornerRadius)
        .presentationBackground(PilotPalette.sheet)
    }
}

/// A local result sheet. Dismissing invalidates in-flight probe work through cancelProbe.
struct DeviceProbeResultView: View {
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    private var succeeded: Bool { model.probeState.phase == .success }
    var body: some View {
        NavigationStack {
            PilotResultScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotConnectionIllustration()
                    if model.probing { ProgressView().tint(PilotPalette.accent) }
                    Text(model.probing ? "正在连接设备" : succeeded ? "设备已响应" : "连接未完成")
                        .font(.title2.bold())
                    if !succeeded {
                        Text(model.probeState.message).font(.body).textSelection(.enabled)
                            .accessibilityIdentifier("device.probe.sheet.result")
                    } else {
                        DisclosureGroup("连接详情") {
                            Text(model.probeState.message).font(.footnote).textSelection(.enabled)
                                .accessibilityIdentifier("device.probe.sheet.result")
                        }.font(.subheadline)
                    }
                    if succeeded {
                        Label("连接蓝牙后，即可校准屏幕。", systemImage: "arrow.right.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(PilotMetrics.pageInset).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(PilotPalette.sheet)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    if model.probing { model.cancelProbe(); dismiss() }
                    else if succeeded { dismiss() }
                    else { Task { await model.probe() } }
                } label: {
                    Text(model.probing ? "取消检查" : succeeded ? "返回设备设置" : "重试连接")
                }.pilotAction(prominent: true, fullWidth: true).padding(PilotMetrics.pageInset)
                    .frame(maxWidth: 540).frame(maxWidth: .infinity)
                    .background(PilotPalette.sheet)
            }
            .navigationTitle("连接检查").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PilotCloseButton { if model.probing { model.cancelProbe() }; dismiss() }
                }
            }
        }.modifier(PilotResultSheetStyle())
    }
}

struct DevicePairingResultView: View {
    var usesSystemMouse = false
    @StateObject private var accessorySetup = SightLatchAccessorySetupAdapter()
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var automaticallyPresentedDeadline: Date?
    @State private var accessoryFailure: String?
    private var waiting: Bool { model.pairingState.phase == .opening || model.pairingState.phase == .waiting }
    private var connected: Bool { model.pairingState.phase == .connected }
    private var supportsSystemPairing: Bool {
        guard !usesSystemMouse else { return false }
        if #available(iOS 18.4, *) {
            return model.lastDeviceStatus?.accessorySetupServiceUUID?.uppercased() == SightLatchAccessorySetupAdapter.serviceUUID
        }
        return false
    }
    private var showsManualPairing: Bool {
        guard supportsSystemPairing else { return true }
        switch accessorySetup.state {
        case .unavailable, .failed, .cancelled: return true
        default: return false
        }
    }
    var body: some View {
        NavigationStack {
            PilotResultScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let accessoryFailure {
                        Label("连接未完成", systemImage: "exclamationmark.circle")
                            .font(.title2.bold())
                        Text(accessoryFailure).font(.body).textSelection(.enabled)
                        Text(model.pairingState.message).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        PilotConnectionIllustration()
                        if waiting { ProgressView().tint(PilotPalette.accent) }
                        Text(connected ? "蓝牙已连接" : model.pairingState.phase == .opening ? "正在开启配对" : waiting ? "连接 SightLatch" : "配对未完成")
                            .font(.title2.bold())
                        DisclosureGroup("配对详情") {
                            Text(model.pairingState.message).font(.footnote).textSelection(.enabled)
                        }.font(.subheadline)
                    }
                    if waiting && accessoryFailure == nil {
                        if supportsSystemPairing, model.pairingState.phase == .waiting {
                            Button("打开系统配对", systemImage: "rectangle.on.rectangle") {
                                presentSystemPairing(automatically: false)
                            }.pilotAction(prominent: false)
                                .disabled(accessorySetup.state == .activating || accessorySetup.state == .presenting || accessorySetup.state == .choosingAuthorizedAccessory || accessorySetup.state == .selectedAwaitingVerification)
                        }
                        accessorySetupStatus
                        if showsManualPairing {
                            VStack(alignment: .leading, spacing: 16) {
                                Label(usesSystemMouse ? "打开“设置” → “辅助功能” → “触控” → “辅助触控”" : "打开 iPhone 的“设置” → “蓝牙”", systemImage: "1.circle")
                                if usesSystemMouse {
                                    Label("开启辅助触控，进入“设备” → “蓝牙设备”", systemImage: "2.circle")
                                }
                                Label("选择设备 SightLatch", systemImage: usesSystemMouse ? "3.circle" : "2.circle")
                                Label("返回 App，完成屏幕校准", systemImage: usesSystemMouse ? "4.circle" : "3.circle")
                            }.font(.callout)
                        } else {
                            Text("在系统配件选择器中选择 SightLatch 并确认配对，随后自动检查加密连接。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if model.pairingState.deadline != nil {
                                Label("配对窗口剩余 \(model.pairingState.remainingSeconds) 秒", systemImage: "timer")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if connected && accessoryFailure == nil {
                        Text("连接完成。接下来校准屏幕，让点击落在正确位置。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(PilotMetrics.pageInset).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(PilotPalette.sheet)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    if waiting || connected { dismiss() }
                    else { Task { await model.startPairing(usingSystemMouse: usesSystemMouse) } }
                } label: {
                    Text(waiting ? "取消配对" : connected ? "返回设备设置" : "重新开启配对")
                }.pilotAction(prominent: true, fullWidth: true).padding(PilotMetrics.pageInset)
                    .frame(maxWidth: 540).frame(maxWidth: .infinity)
                    .background(PilotPalette.sheet)
                    .disabled(!waiting && !connected && model.isSessionActive)
            }
            .navigationTitle(usesSystemMouse ? "系统鼠标配对" : "蓝牙配对").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { PilotCloseButton { dismiss() } }
            }
        }.modifier(PilotResultSheetStyle())
            .onDisappear {
                if connected && !usesSystemMouse { accessorySetup.completeVerification() }
                else { accessorySetup.cancel() }
            }
            .onChange(of: model.pairingState.phase, initial: true) { _, phase in
                // Only the explicit pairing flow can enter waiting. Repeated status polls
                // keep the same phase, so dismissing the system picker never reopens it.
                guard !usesSystemMouse else { return }
                if phase == .waiting { presentSystemPairing() }
                else if phase == .connected { accessorySetup.completeVerification() }
                else if !waiting { accessorySetup.cancel() }
            }
            .onChange(of: accessorySetup.state) { _, state in
                guard case .failed(let reason) = state else { return }
                accessoryFailure = reason
                // Close only the window owned by this attempt; never issue a broad STOP.
                if waiting { Task { await model.cancelPairing() } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && usesSystemMouse {
                    Task { await model.checkSystemMousePairing() }
                }
            }
    }
    private func presentSystemPairing(automatically: Bool = true) {
        guard !usesSystemMouse, !model.pairingUsesSystemMouse, supportsSystemPairing, model.pairingState.phase == .waiting,
              let deadline = model.pairingState.deadline, deadline > Date() else { return }
        if automatically {
            guard automaticallyPresentedDeadline != deadline else { return }
            automaticallyPresentedDeadline = deadline
        }
        accessoryFailure = nil
        accessorySetup.present(
            serviceUUID: model.lastDeviceStatus?.accessorySetupServiceUUID,
            pairingWindowIsOpen: true,
            remainingSeconds: model.pairingState.remainingSeconds,
            deadline: deadline)
    }
    @ViewBuilder private var accessorySetupStatus: some View {
        switch accessorySetup.state {
        case .activating, .presenting:
            Text("请在系统窗口中确认配对。")
                .font(.caption).foregroundStyle(.secondary)
        case .selectedAwaitingVerification:
            Text("正在连接设备…")
                .font(.caption).foregroundStyle(.secondary)
        case .choosingAuthorizedAccessory:
            VStack(alignment: .leading, spacing: 12) {
                Text("选择本次要连接的已授权设备").font(.callout)
                ForEach(accessorySetup.authorizedChoices) { choice in
                    Button(choice.name) { accessorySetup.selectAuthorizedAccessory(id: choice.id) }
                        .pilotAction(prominent: false, fullWidth: true)
                }
            }
        case .unavailable(let reason), .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .idle, .cancelled:
            EmptyView()
        }
    }
}

/// Presentation only: this never resumes capture, creates a command, or grants control.
enum HomeCaptureState: Equatable {
    case idle, preparing, ready, waiting, capturing, awaitingAnswer, interrupted, paused, ended

    static func currentObservation(_ observation: CaptureObservation?, command: SessionCommand?) -> CaptureObservation? {
        guard let observation, let command, observation.sessionID == command.id,
              observation.generation == command.generation else { return nil }
        return observation
    }
    static func resolve(preparing: Bool, prepared: Bool, command: SessionCommand?,
                        status: PilotStatus, observation: CaptureObservation?) -> Self {
        if preparing { return .preparing }
        let current = currentObservation(observation, command: command)
        let sameStatus = command != nil && status.sessionID == command?.id
        if command?.running != true {
            if current != nil || sameStatus && ["暂停", "停止", "完成"].contains(status.phase) { return .ended }
            return .idle
        }
        if sameStatus && status.phase == "暂停" || current?.state == "paused" { return .paused }
        if sameStatus && ["停止", "完成"].contains(status.phase) { return .ended }
        if command?.pendingClarification != nil { return .awaitingAnswer }
        guard prepared else { return .preparing }
        guard let current else { return .ready }
        if current.hasFreshFrame { return .capturing }
        if current.state == "waiting" { return .waiting }
        return .interrupted
    }
    var title: String {
        switch self {
        case .idle: return "屏幕捕获尚未开始"
        case .preparing: return "正在准备…"
        case .ready: return "开始广播"
        case .waiting: return "正在连接画面"
        case .capturing: return "正在共享屏幕"
        case .awaitingAnswer: return "等待你的选择"
        case .interrupted: return "画面更新已中断"
        case .paused: return "会话已暂停"
        case .ended: return "已结束"
        }
    }
    var detail: String {
        switch self {
        case .idle: return "发送目标后准备本次会话。"
        case .preparing: return "准备完成后，点左侧圆形按钮。"
        case .ready: return "在系统窗口中开始直播。"
        case .waiting: return "画面连接后自动开始。"
        case .capturing: return "AI 正在帮你操作。"
        case .awaitingAnswer: return "屏幕共享继续，选择后接着执行。"
        case .interrupted: return "请检查屏幕共享是否仍在运行。"
        case .paused: return "查看原因后结束本轮任务。"
        case .ended: return "可以开始新的任务。"
        }
    }
}

enum HomeNoticePresentation {
    static func visibleNotice(_ notice: String, command: SessionCommand?, status: PilotStatus) -> String? {
        guard !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // This exact progress copy is written once at URI dispatch. Other notices,
        // especially unconfirmed STOP warnings, must retain their normal visibility.
        if notice == "正在打开微信；AI会读取画面并处理本次系统打开确认。" {
            guard let command, command.running, status.sessionID == command.id,
                  ["待广播", "准备", "观察", "广播中", "规划", "思考", "执行"].contains(status.phase),
                  let scope = command.messageScope,
                  scope.matches(sessionID: command.id, generation: command.generation, task: command.task),
                  [.opening, .opened].contains(scope.launch.phase), !scope.launch.isVisuallyEstablished else { return nil }
        }
        return notice
    }
}

private struct BroadcastPicker: UIViewControllerRepresentable {
    @EnvironmentObject private var model: PilotViewModel

    func makeUIViewController(context: Context) -> BroadcastPickerHostController {
        BroadcastPickerHostController()
    }
    func updateUIViewController(_ controller: BroadcastPickerHostController, context: Context) {
        updateUIView(controller.picker, context: context)
        let command = SharedStore.shared.command
        controller.observeCapture(sessionID: model.taskFlow.sessionID,
                                  command: model.prepared && !model.stopping ? command : nil,
                                  capture: model.captureObservation)
    }
    private func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.isUserInteractionEnabled = context.environment.isEnabled
    }
}

/// Keeps the native picker mounted. ReplayKit owns its system panel and broadcast lifetime.
private final class BroadcastPickerHostController: UIViewController {
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    private var sessionID: String?
    private var generation: Int?
    private var hasObservedFreshFrame = false
    private var lastDiagnostic: BroadcastHostHandoff?

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        picker.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".Broadcast" }
        picker.showsMicrophoneButton = false
        picker.accessibilityLabel = "系统屏幕广播按钮"
        picker.accessibilityHint = "选择SightLatch Broadcast后，由系统确认开始屏幕广播"
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            picker.topAnchor.constraint(equalTo: container.topAnchor),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    func observeCapture(sessionID: String?, command: SessionCommand?, capture: CaptureObservation?) {
        let currentGeneration = command?.generation
        if self.sessionID != sessionID || generation != currentGeneration {
            self.sessionID = sessionID
            generation = currentGeneration
            hasObservedFreshFrame = false
            lastDiagnostic = nil
        }
        guard let sessionID, let command, command.running, command.id == sessionID,
              let capture, capture.sessionID == sessionID,
              capture.generation == command.generation else { return }
        if capture.hasFreshFrame, let receivedAt = capture.receivedAt, receivedAt >= command.createdAt {
            hasObservedFreshFrame = true
        }
        if hasObservedFreshFrame { recordHandoffDiagnostic() }
    }

    private func recordHandoffDiagnostic() {
        guard let sessionID, let generation else { return }
        let value = BroadcastHostHandoff(sessionID: sessionID, generation: generation, observedAt: Date(),
            appState: UIApplication.shared.applicationState.rawValue,
            hasOwnPresented: presentedViewController?.presentingViewController === self,
            attemptedDismiss: false)
        if let lastDiagnostic, lastDiagnostic.appState == value.appState,
           lastDiagnostic.hasOwnPresented == value.hasOwnPresented,
           lastDiagnostic.attemptedDismiss == value.attemptedDismiss { return }
        if (try? SharedStore.shared.write(value, to: "host-handoff.json")) != nil { lastDiagnostic = value }
    }
}

private struct BroadcastHostHandoff: Codable {
    let sessionID: String
    let generation: Int
    let observedAt: Date
    let appState: Int
    let hasOwnPresented: Bool
    let attemptedDismiss: Bool
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
private struct PilotActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let prominent: Bool
    let fullWidth: Bool
    let tint: Color
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        surface(configuration.label
            .font(iconOnly ? .system(size: 18, weight: .semibold) : .subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .tint(prominent ? Color.white : tint)
            .padding(.horizontal, iconOnly ? 0 : 14)
            .padding(.vertical, iconOnly ? 0 : 10)
            .frame(minWidth: 44, maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: iconOnly ? 22 : 14)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: configuration.isPressed)
    }
    @ViewBuilder private func surface<Label: View>(_ label: Label) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent {
                label.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: iconOnly ? 22 : 14))
            } else {
                label.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
            }
        } else if prominent {
            label.background(tint, in: RoundedRectangle(cornerRadius: iconOnly ? 22 : 14))
        } else if reduceTransparency {
            label.background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        } else {
            label.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
extension View {
    func pilotGlass() -> some View { modifier(PilotGlassSurface()) }
    func pilotAction(prominent: Bool, fullWidth: Bool = false, tint: Color = PilotPalette.accent, iconOnly: Bool = false) -> some View {
        buttonStyle(PilotActionStyle(prominent: prominent, fullWidth: fullWidth, tint: tint, iconOnly: iconOnly))
    }
}

struct ConfigurationDetailView: View {
    let safety: Bool
    var embedded = false
    @FocusState private var aiField: AIField?
    private enum AIField: Hashable { case endpoint, model, key }
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false
    @State private var showProfiles = false
    @State private var saveError: String?
    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotSettingsHero(kind: safety ? .privacy : .intelligence,
                        title: safety ? "由你决定访问范围" : "选择与你协作的 AI",
                        subtitle: safety ? "管理屏幕共享与操作权限。" : "连接账户，或使用支持视觉的 API 服务。")
                    if let saveError {
                        PilotSettingsCard { PilotSettingsNotice(message: saveError, isError: true) }
                    }
                    if !safety { aiSettings }
                    if safety { privacySettings }
                    if !model.notice.isEmpty {
                        DisclosureGroup("最近操作") { PilotSettingsNotice(message: model.notice) }
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .disabled(model.isSessionActive || model.probing)
            .modifier(PilotSettingsPageStyle(showsCloseButton: false))
            .scrollDismissesKeyboard(.interactively)
            .background { PilotPalette.canvas.contentShape(Rectangle()).onTapGesture { aiField = nil } }
            .onDisappear { aiField = nil }
            .onChange(of: model.configuration.endpoint) { _, _ in model.configuration.uploadConsent = false; model.configuration.textPlanningConsent = false; model.configuration.gatewayVisionConfirmed = false }
            .onChange(of: model.configuration.provider) { _, _ in model.configuration.uploadConsent = false; model.configuration.textPlanningConsent = false; model.configuration.gatewayVisionConfirmed = false }
            .onChange(of: model.configuration.model) { _, _ in model.configuration.gatewayVisionConfirmed = false }
            .onChange(of: model.configuration.deviceURL) { _, _ in model.lastDeviceStatus = nil; model.deviceSummary = "设备地址已修改，请重新检查"; model.configuration.invalidatePointerCalibration() }
            .navigationTitle(safety ? "权限与安全" : "AI 账户").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isSessionActive {
                    ToolbarItem(id: "configuration.stop", placement: .cancellationAction) {
                        Button("停止并撤回上传", role: .destructive) { Task { await model.stopAndRevokeConsent() } }
                    }
                } else if !embedded {
                    ToolbarItem(id: "configuration.back", placement: .cancellationAction) {
                        Button("返回") { aiField = nil; dismiss() }
                    }
                }
                ToolbarItem(id: "configuration.save", placement: .confirmationAction) {
                    Button("保存", action: saveSettings).disabled(model.isSessionActive)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.isSessionActive {
                    Text("任务进行中。停止后即可修改设置。")
                        .font(.caption).padding().background(PilotPalette.canvas)
                }
            }
            .navigationDestination(isPresented: $showProfiles) { ProfilesView(embedded: true).modifier(PilotAppearanceStyle()) }
            .confirmationDialog("删除当前端点和设备的两项凭据？", isPresented: $showDelete) {
                Button("删除密钥", role: .destructive) { model.deleteSecrets() }
            }
        }
    }

    @ViewBuilder private var aiSettings: some View {
        PilotSettingsCard {
            Picker(selection: $model.configuration.provider) {
                Text("ChatGPT 套餐").tag("chatgpt-plan")
                Text("OpenAI Responses").tag("responses")
                Text("OpenAI 兼容").tag("openai")
                Text("Anthropic Messages").tag("anthropic")
                Text("Google Gemini").tag("gemini")
            } label: {
                PilotSettingsRowLabel(title: "AI 服务", symbol: "sparkles")
            }.frame(minHeight: 44)
        }
        if model.configuration.provider == "chatgpt-plan" {
            ChatGPTSettingsSection(model: model)
        } else {
            apiSettings
        }
        PilotSettingsCard {
            Button { showProfiles = true } label: {
                HStack(spacing: 12) {
                    PilotSettingsRowLabel(title: "模型档案", subtitle: "管理已保存的模型配置", symbol: "square.stack.3d.up")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider()
            DisclosureGroup("凭据管理") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("删除会清除当前 AI 端点的 API Key 与当前设备 Token。ChatGPT 账户需单独退出。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("删除当前 AI 与设备凭据", role: .destructive) { showDelete = true }
                        .frame(minHeight: 44)
                }.padding(.top, 8)
            }.font(.subheadline)
        }
    }

    private var apiSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API 连接").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            PilotSettingsCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text("模型 ID").font(.subheadline).foregroundStyle(.secondary)
                    TextField("支持视觉的模型 ID", text: $model.configuration.model)
                        .focused($aiField, equals: .model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 32)
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("请求地址").font(.subheadline).foregroundStyle(.secondary)
                    TextField("完整 HTTPS 请求 URL", text: $model.configuration.endpoint)
                        .focused($aiField, equals: .endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 32)
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("API Key").font(.subheadline).foregroundStyle(.secondary)
                    SecureField("留空以保留已有密钥", text: $model.apiKey)
                        .focused($aiField, equals: .key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 32)
                }
                if model.configuration.provider == "openai" {
                    Divider()
                    Toggle("确认已获准使用，且模型支持图片", isOn: Binding(get: { model.configuration.gatewayVisionConfirmed == true }, set: { model.configuration.gatewayVisionConfirmed = $0 }))
                }
            }
            Text("任务与截图将发送至所选服务。截图上传需在“权限与安全”中单独开启。")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("端点格式与服务说明") {
                Text("OpenAI: /v1/responses\n兼容网关: /v1/chat/completions\nAnthropic: https://api.anthropic.com/v1/messages\nGemini: https://generativelanguage.googleapis.com/v1beta/models/模型ID:generateContent\nGemini 模型以 URL 中的 ID 为准。模型是否支持截图、计费和数据保留由供应商决定。")
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
            }.font(.subheadline)
        }
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("屏幕内容").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                PilotSettingsCard {
                    Toggle(isOn: $model.configuration.uploadConsent) {
                        PilotSettingsRowLabel(title: "向 AI 共享屏幕截图", symbol: "display")
                    }
                    Divider()
                    LabeledContent("接收服务", value: model.configuration.provider == "chatgpt-plan" ? "OpenAI · ChatGPT 套餐" : (URL(string: model.configuration.endpoint)?.host ?? "尚未配置"))
                        .font(.subheadline).frame(minHeight: 36)
                }
                Text("共享期间会发送跨 App 截图，服务方可能保留图像。")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("了解屏幕共享") {
                    Text("每次开始仍需系统确认。撤回后请停止任务；ChatGPT 套餐与 API 分别计费。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("导航与操作").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                PilotSettingsCard {
                    Toggle(isOn: $model.configuration.allowLowRiskNavigation) {
                        PilotSettingsRowLabel(title: "允许导航与搜索", subtitle: "点击导航、输入搜索词", symbol: "cursorarrow")
                    }
                    Divider()
                    Stepper("最大 \(model.configuration.maxSteps) 步", value: $model.configuration.maxSteps, in: 1...50)
                        .frame(minHeight: 44)
                }
                Text("发送消息只按本次明确的收件人与正文执行。")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("执行边界") {
                    Text("运行到你设置的时限，不限时模式每次开始前确认。画面中断时暂停；购买、支付、删除和敏感授权需你自行处理。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.subheadline)
            }
            PilotSettingsCard {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    HStack(spacing: 12) {
                        PilotSettingsRowLabel(title: "系统权限", subtitle: "管理麦克风与语音识别权限", symbol: "gearshape")
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
                DisclosureGroup("高级后台选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        if #available(iOS 26.0, *) {
                            Toggle("由主 App 处理后台任务", isOn: Binding(get: { model.configuration.continuedProcessingEnabled == true }, set: { model.configuration.continuedProcessingEnabled = $0 }))
                        }
                        Text("默认由屏幕广播处理任务。开启后，最新截图会临时保存在本机并在停止后删除；系统可能限制后台运行。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.font(.subheadline)
            }
            Text("麦克风用于语音输入与会话唤醒，可随时关闭。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func saveSettings() {
        aiField = nil
        if model.save() { dismiss() }
        else { saveError = model.notice }
    }
}

/// Positioning is explicit; measurement observes controlled device clicks without finger markers.
struct CalibrationView: View {
    var returnsToTask = false
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showMeasurement = false
    private var completed: Bool { model.automaticCalibration.phase == .completed && model.configuration.automaticCalibrationProfile?.absoluteMapping != nil }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PilotSettingsHero(kind: .calibration,
                        title: completed ? "点击已校准" : "让每次点击更准确",
                        subtitle: completed ? "屏幕坐标已验证，可以开始任务。" : "自动测量设备的点击位置，并验证准确度。")
                    if !completed {
                        PilotSettingsCard {
                            PilotSettingsRowLabel(title: "约 60 秒", subtitle: "放下手机，让设备自动完成测量", symbol: "timer")
                            Divider()
                            PilotSettingsRowLabel(title: "保持方向不变", subtitle: "开始后不要触碰画布", symbol: "hand.raised")
                        }
                    } else {
                        PilotSettingsCard {
                            PilotSettingsRowLabel(title: "已完成位置验证", subtitle: "现在可以回到任务继续", symbol: "checkmark.circle")
                        }
                    }
                    DisclosureGroup("校准详情") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("通过设备点击读取实际坐标，并用不同位置验证准确度。设备重启、连接或屏幕方向变化后需要重新校准。")
                            if !model.automaticCalibration.detail.isEmpty, model.automaticCalibration.phase != .idle {
                                Text(model.automaticCalibration.detail).textSelection(.enabled)
                            }
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(PilotPalette.canvas)
            .safeAreaInset(edge: .bottom) {
                Button(completed ? "重新校准" : "开始校准") { showMeasurement = true }
                    .pilotAction(prominent: true, fullWidth: true)
                    .disabled(model.isSessionActive || model.automaticCalibration.isBusy || model.probing)
                    .padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity).background(PilotPalette.canvas)
            }
            .navigationTitle("屏幕校准").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { PilotCloseButton { dismiss() } } }
            .fullScreenCover(isPresented: $showMeasurement, onDismiss: {
                if completed && returnsToTask { dismiss() }
            }) {
                AbsoluteCalibrationMeasurementView(returnsToTask: returnsToTask, onLeave: { showMeasurement = false }).environmentObject(model)
            }
        }
    }
}

private struct AbsoluteCalibrationMeasurementView: View {
    let returnsToTask: Bool
    let onLeave: () -> Void
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var launching = true
    private var completed: Bool { model.automaticCalibration.phase == .completed }
    private var measurementTitle: String {
        if model.calibrationFlow.phase == .stopping { return "正在停止校准" }
        switch model.automaticCalibration.phase {
        case .completed: return "校准完成"
        case .error: return "校准未完成"
        case .unavailable: return "校准暂不可用"
        case .idle: return launching ? "准备校准" : "校准已停止"
        case .positioning, .detecting, .sampling, .verifying: return "正在校准"
        }
    }
    private var measurementSymbol: String {
        if model.calibrationFlow.phase == .stopping { return "stop.circle" }
        switch model.automaticCalibration.phase {
        case .completed: return "checkmark.circle"
        case .error, .unavailable: return "exclamationmark.triangle"
        case .idle: return launching ? "scope" : "stop.circle"
        case .positioning, .detecting, .sampling, .verifying: return "scope"
        }
    }
    private var busy: Bool { launching || model.automaticCalibration.isBusy || model.calibrationFlow.isBusy }
    private var canLeave: Bool {
        !busy && !model.sending && !model.calibrationRequestInFlight &&
            (!model.automaticCalibration.controlRequested || model.calibrationFlow.stopConfirmed)
    }
    var body: some View {
        ZStack {
            AbsoluteCalibrationCanvas(model: model).ignoresSafeArea()
                .allowsHitTesting(!canLeave)
            VStack(spacing: 10) {
                Image(systemName: measurementSymbol)
                    .font(.title2).foregroundStyle(PilotPalette.accent).accessibilityHidden(true)
                Text(measurementTitle)
                    .font(.headline)
                Text(busy ? "请勿触碰屏幕 · \(model.automaticCalibration.probeCount)/\(AbsoluteCalibrationPlan.targets.count)" : model.automaticCalibration.detail)
                    .font(.callout).multilineTextAlignment(.center)
                if busy { ProgressView(value: Double(model.automaticCalibration.probeCount), total: Double(AbsoluteCalibrationPlan.targets.count)).tint(PilotPalette.accent).frame(maxWidth: 180) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.top, 80).padding(.bottom, 120)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                if canLeave {
                    Button(completed && returnsToTask ? "返回任务" : "返回") {
                        guard canLeave else { return }
                        onLeave()
                    }
                        .pilotAction(prominent: true)
                } else {
                    Button(busy ? "停止校准" : "重试确认停止", role: .destructive) {
                        let scene = cancellationScene
                        let flowID = model.calibrationFlow.id
                        model.recordCalibrationCancellation(source: .measurementStopButton, scene: scene)
                        Task {
                            guard model.calibrationFlow.id == flowID else { return }
                            await model.endPointerCalibration()
                        }
                    }.pilotAction(prominent: false, tint: .red)
                        .disabled(model.calibrationFlow.phase == .stopping)
                }
            }.padding(.horizontal, 40).padding(.bottom, 72)
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled()
        .task {
            await model.startAutomaticCalibration()
            launching = false
        }
        .onDisappear { cancelIfBusy(source: .viewDisappeared, scene: cancellationScene) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: break
            case .inactive: cancelIfBusy(source: .sceneInactive, scene: .inactive)
            case .background: cancelIfBusy(source: .sceneBackground, scene: .background)
            @unknown default: cancelIfBusy(source: .sceneUnknown, scene: .unknown)
            }
        }
    }
    private var cancellationScene: CalibrationCancellationScene {
        switch scenePhase {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .unknown
        }
    }
    private func cancelIfBusy(source: CalibrationCancellationSource, scene: CalibrationCancellationScene) {
        guard busy else { return }
        let flowID = model.calibrationFlow.id
        model.recordCalibrationCancellation(source: source, scene: scene)
        Task {
            guard model.calibrationFlow.id == flowID else { return }
            await model.endPointerCalibration()
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
            }.navigationTitle("最近动作")
                .modifier(PilotSettingsPageStyle())
                .overlay { if model.logs.isEmpty { ContentUnavailableView("还没有动作", systemImage: "list.bullet") } }
        }
    }
}

enum PilotMetrics {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let minimumRowHeight: CGFloat = 56
    static let minimumHitTarget: CGFloat = 44
    static let cornerRadius: CGFloat = 24
    static let sheetCornerRadius: CGFloat = 32
}

/// Semantic surfaces follow the user's selected light/dark appearance.
enum PilotPalette {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.035, green: 0.043, blue: 0.059, alpha: 1) : .systemGroupedBackground
    })
    static let group = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.110, green: 0.125, blue: 0.157, alpha: 1) : .secondarySystemGroupedBackground
    })
    static let sheet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.065, green: 0.078, blue: 0.102, alpha: 1) : .systemGroupedBackground
    })
    static let accent = Color(red: 0.263, green: 0.518, blue: 1)
}

struct PilotDeviceOverview: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            PilotBridgeArtwork()
                .frame(width: 82, height: 82)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("SightLatch 设备").font(.headline)
                Text("连接手机与设备，让操作发生。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PilotCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button("关闭", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .foregroundStyle(.primary)
    }
}

struct PilotConnectionIllustration: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 280, geometry.size.height / 112)
            PilotLinkArtwork()
                .frame(width: 280, height: 112)
                .scaleEffect(scale)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(maxWidth: .infinity).frame(height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iPhone 与 SightLatch 设备连接示意")
    }
}

/// Static artwork explains the two ends of the link; live connection state stays in the text.
private struct PilotLinkArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if !reduceTransparency {
                Ellipse()
                    .fill(RadialGradient(colors: [PilotPalette.accent.opacity(0.15), .clear],
                                         center: .center, startRadius: 12, endRadius: 125))
                    .frame(width: 260, height: 100)
            }
            Path { path in
                path.move(to: CGPoint(x: 82, y: 56))
                path.addCurve(to: CGPoint(x: 201, y: 56),
                              control1: CGPoint(x: 118, y: 27),
                              control2: CGPoint(x: 165, y: 85))
            }
            .stroke(PilotPalette.accent.opacity(colorScheme == .dark ? 0.6 : 0.45),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))

            HStack(spacing: 108) {
                PilotPhoneArtwork()
                    .frame(width: 58, height: 100)
                    .rotationEffect(.degrees(-7))
                PilotBridgeArtwork()
                    .frame(width: 82, height: 82)
                    .rotationEffect(.degrees(7))
            }
            Image(systemName: "wave.3.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PilotPalette.accent)
                .frame(width: 34, height: 34)
                .background(PilotPalette.sheet, in: Circle())
                .overlay(Circle().strokeBorder(PilotPalette.accent.opacity(0.2), lineWidth: 1))
        }
        .accessibilityHidden(true)
    }
}

/// A small board with a cursor chip gives SightLatch a recognizable hardware motif.
private struct PilotBridgeArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var boardColor: Color {
        colorScheme == .dark ? Color(red: 0.10, green: 0.20, blue: 0.39)
                             : Color(red: 0.85, green: 0.91, blue: 1)
    }
    private var pinColor: Color {
        colorScheme == .dark ? Color(red: 0.44, green: 0.53, blue: 0.67)
                             : Color(red: 0.43, green: 0.51, blue: 0.63)
    }

    var body: some View {
        ZStack {
            ForEach(0..<4) { side in
                HStack(spacing: 7) {
                    ForEach(0..<4) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(pinColor)
                            .frame(width: 4, height: 10)
                    }
                }
                .offset(y: -33)
                .rotationEffect(.degrees(Double(side) * 90))
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [boardColor, PilotPalette.accent.opacity(reduceTransparency ? 1 : 0.32)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 66, height: 66)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.65), PilotPalette.accent.opacity(0.3)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
                .shadow(color: reduceTransparency ? .clear : PilotPalette.accent.opacity(0.13), radius: 7, y: 4)
            ForEach(0..<4) { corner in
                Circle().fill(pinColor).frame(width: 3, height: 3)
                    .offset(x: -23, y: -23)
                    .rotationEffect(.degrees(Double(corner) * 90))
            }
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.05, green: 0.10, blue: 0.20) : .white)
                .frame(width: 36, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PilotPalette.accent.opacity(0.3), lineWidth: 1))
            Image(systemName: "cursorarrow")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(PilotPalette.accent)
                .offset(x: 1, y: 1)
        }
        .frame(width: 82, height: 82)
        .accessibilityHidden(true)
    }
}

private struct PilotPhoneArtwork: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.16, green: 0.20, blue: 0.27) : Color(red: 0.72, green: 0.78, blue: 0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .gray.opacity(0.3)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(PilotPalette.canvas)
                .padding(3)
            VStack(spacing: 0) {
                Capsule().fill(Color.primary.opacity(0.25)).frame(width: 18, height: 4)
                    .padding(.top, 7)
                Spacer(minLength: 7)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(PilotPalette.accent.opacity(0.13)).frame(width: 34, height: 34)
                    Image(systemName: "viewfinder")
                        .font(.system(size: 23, weight: .light)).foregroundStyle(PilotPalette.accent)
                    Circle().fill(PilotPalette.accent).frame(width: 4, height: 4)
                }
                VStack(spacing: 4) {
                    Capsule().fill(PilotPalette.accent.opacity(0.35)).frame(width: 25, height: 3)
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 17, height: 3)
                }.padding(.top, 7)
                Spacer(minLength: 6)
                Capsule().fill(Color.primary.opacity(0.25)).frame(width: 18, height: 2)
                    .padding(.bottom, 6)
            }
        }
        .frame(width: 58, height: 100)
        .accessibilityHidden(true)
    }
}
