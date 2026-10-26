import SwiftUI
import Speech
import AVFoundation
import UIKit
import Combine

/// Short, foreground-only dictation. Recognition never submits a task or starts a broadcast.
@MainActor
final class VoiceTaskRecorder: ObservableObject {
    private static weak var activeRecorder: VoiceTaskRecorder?
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var transcript = ""
    @Published private(set) var message: String?
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var hasTap = false
    private var ownsSession = false

    func start() async {
        guard !Task.isCancelled, !isRecording, !isRequestingPermission else { return }
        SessionVoiceController.shared.stopVoicePreview()
        guard !SessionVoiceController.shared.isEnabled else {
            message = "会话语音正在监听；请先关闭会话监听，再填写语音草稿。"; return
        }
        Self.activeRecorder?.stop(); Self.activeRecorder = self
        let token = UUID(); generation = token
        message = nil; transcript = ""; isRequestingPermission = true
        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token else { return }
        guard speechPermission == .authorized else {
            isRequestingPermission = false
            message = "请在系统设置中允许语音识别，或直接输入文字。"; return
        }
        let microphonePermission = await AVAudioApplication.requestRecordPermission()
        guard generation == token else { return }
        isRequestingPermission = false
        guard microphonePermission else { message = "请在系统设置中允许麦克风，或直接输入文字。"; return }
        guard UIApplication.shared.applicationState == .active else {
            message = "回到 App 后，点麦克风开始说话。"; return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            message = "语音识别暂不可用，请稍后重试或输入文字。"; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true); ownsSession = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw PilotError.message("麦克风当前不可用。")
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Transfer only plain values out of the framework callback.
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if let text { self.transcript = text }
                    if finished || failed {
                        self.stop()
                        if failed { self.message = "语音输入已结束；已识别的文字留在草稿中。" }
                    }
                }
            }
            engine.prepare(); try engine.start(); isRecording = true
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.stop(); self.message = "本次语音输入已结束，可以继续编辑或再说一段。"
            }
        } catch {
            stop(); message = "暂时无法开始语音输入，请检查麦克风后重试。"
        }
    }

    func cancel() { stop(); transcript = "" }

    func stop() {
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        generation = UUID() // Late permission/recognition callbacks cannot restart or overwrite a newer draft.
        timeout?.cancel(); timeout = nil
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recognition?.cancel()
        recognition = nil; request = nil
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
        isRecording = false; isRequestingPermission = false
    }
    static func stopActive() { activeRecorder?.stop() }
}

struct VoiceTaskComposer: View {
    @Binding var text: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var recorder = VoiceTaskRecorder()
    @ObservedObject private var router = PilotShortcutRouter.shared
    @State private var originalDraft = ""
    @State private var voiceMessage: String?
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        Button {
            if recorder.isRecording || recorder.isRequestingPermission { stopRecording() }
            else { begin() }
        } label: {
            Image(systemName: recorder.isRecording ? "waveform" : "mic")
                .font(.body).frame(width: 44, height: 44)
                .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "结束听写" : recorder.isRequestingPermission ? "取消授权等待" : "语音输入")
        .accessibilityHint("语音只填写草稿，不会发送任务")
        .accessibilityIdentifier("chat.microphone")
        .alert("语音输入", isPresented: Binding(get: { voiceMessage != nil }, set: { if !$0 { voiceMessage = nil } })) {
            Button("好") { voiceMessage = nil }
        } message: { Text(voiceMessage ?? "") }
        .onChange(of: recorder.message) { _, value in voiceMessage = value }
        .onChange(of: recorder.transcript) { _, value in
            guard !value.isEmpty else { return }
            text = originalDraft.isEmpty ? value : originalDraft + "\n" + value
        }
        .onChange(of: router.voiceRequestID) { _, _ in consumeVoiceRequest() }
        .onAppear { consumeVoiceRequest() }
        .onChange(of: scenePhase) { _, phase in
            // Permission alerts briefly make the app inactive. Backgrounding always cancels the request.
            if phase == .background || (phase != .active && recorder.isRecording) { stopRecording() }
            if phase == .active { consumeVoiceRequest() }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { stopRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in stopRecording() }
        .onDisappear { stopRecording() }
    }
    private func begin() {
        guard isEnabled, scenePhase == .active else { return }
        originalDraft = text
        startTask?.cancel()
        startTask = Task { await recorder.start() }
    }
    private func stopRecording() {
        startTask?.cancel(); startTask = nil
        recorder.stop()
    }
    private func consumeVoiceRequest() {
        guard isEnabled, scenePhase == .active, router.consumeVoiceRequest() else { return }
        begin()
    }
}

/// Each recognition segment starts a new utterance. Ambient speech cannot submit a command.
enum SessionVoiceWakeParser {
    static func command(in transcript: String) -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?:^|[\s，。！？、,!?;；:：])(?:小视(?!频)|sight\s*latch)(?=$|[\s\p{P}\p{Han}])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text) else { return nil }
        var command = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = command.unicodeScalars.first,
              CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains(first) {
            command.removeFirst()
        }
        guard !command.isEmpty, command.count <= 2_000,
              command.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return command
    }
}

struct SessionVoiceCommandDeduplicator {
    private var previous = ""
    private var previousTime: TimeInterval = -.infinity

    mutating func accept(_ command: String, at uptime: TimeInterval) -> Bool {
        let normalized = command.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
        }.map(String.init).joined()
        guard !normalized.isEmpty else { return false }
        guard normalized != previous || uptime - previousTime >= 3 else { return false }
        previous = normalized; previousTime = uptime
        return true
    }
}

/// Shared only between the audio tap and the main actor; no audio leaves this process.
private final class SessionVoiceAudioActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastVoice = ProcessInfo.processInfo.systemUptime

    func reset() {
        lock.lock(); lastVoice = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = channels[0]
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
        guard sqrt(energy / Float(buffer.frameLength)) > 0.012 else { return }
        reset()
    }

    func hasBeenQuiet(for duration: TimeInterval) -> Bool {
        lock.lock(); let elapsed = ProcessInfo.processInfo.systemUptime - lastVoice; lock.unlock()
        return elapsed >= duration
    }
}

struct VoiceFeedbackVoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    let qualityRank: Int
    var qualityLabel: String { qualityRank >= 3 ? "高级" : qualityRank == 2 ? "增强" : "基础" }
    var displayName: String {
        let region = language == "zh-CN" ? "普通话" : language == "zh-TW" ? "台湾普通话" : language == "zh-HK" ? "香港中文" : language
        return "\(name) · \(region) · \(qualityLabel)"
    }
    static func sorted(_ options: [Self], systemMandarinIdentifier: String? = nil) -> [Self] {
        options.sorted {
            if $0.qualityRank != $1.qualityRank { return $0.qualityRank > $1.qualityRank }
            // For basic voices, use the system's locale-selected identifier, never a guessed display name.
            if $0.qualityRank == 1, ($0.id == systemMandarinIdentifier) != ($1.id == systemMandarinIdentifier) {
                return $0.id == systemMandarinIdentifier
            }
            if ($0.language == "zh-CN") != ($1.language == "zh-CN") { return $0.language == "zh-CN" }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
    static func selected(_ identifier: String, from options: [Self], systemMandarinIdentifier: String? = nil) -> Self? {
        options.first(where: { $0.id == identifier }) ?? sorted(options, systemMandarinIdentifier: systemMandarinIdentifier).first
    }
}

enum VoiceFeedbackProvider: String, CaseIterable, Identifiable {
    case system, fishAudio
    var id: String { rawValue }
    var title: String { self == .system ? "iPhone 声音" : "Fish Audio" }
}

/// One generation spans synthesis and playback. Cancellation invalidates late audio.
struct VoiceFeedbackPlaybackGate {
    enum Intent { case automatic, preview }
    private(set) var generation: UUID?
    private var intent: Intent?

    mutating func begin(intent: Intent, feedbackEnabled: Bool) -> UUID? {
        cancel()
        guard intent == .preview || feedbackEnabled else { return nil }
        let token = UUID()
        self.intent = intent
        generation = token
        return token
    }

    func permits(_ token: UUID, feedbackEnabled: Bool) -> Bool {
        generation == token && (intent == .preview || feedbackEnabled)
    }

    mutating func cancel() { generation = nil; intent = nil }
}

/// App-only output preferences. They grant no microphone, task or screen-upload permission.
@MainActor
final class VoiceFeedbackPreferences: ObservableObject {
    static let shared = VoiceFeedbackPreferences()
    private enum Key {
        static let enabled = "SightLatch.voiceFeedback.enabled"
        static let identifier = "SightLatch.voiceFeedback.voiceIdentifier"
        static let provider = "SightLatch.voiceFeedback.provider"
        static let fishModel = "SightLatch.voiceFeedback.fishModel"
        static let fishReference = "SightLatch.voiceFeedback.fishReference"
    }
    @Published var spokenFeedbackEnabled: Bool {
        didSet { defaults.set(spokenFeedbackEnabled, forKey: Key.enabled) }
    }
    @Published var selectedVoiceIdentifier: String {
        didSet { defaults.set(selectedVoiceIdentifier, forKey: Key.identifier) }
    }
    @Published var provider: VoiceFeedbackProvider {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }
    @Published var fishModel: FishSpeechModel {
        didSet { defaults.set(fishModel.rawValue, forKey: Key.fishModel) }
    }
    @Published var fishReferenceID: String {
        didSet { defaults.set(fishReferenceID, forKey: Key.fishReference) }
    }
    @Published private(set) var availableVoices: [VoiceFeedbackVoiceOption] = []
    private var systemMandarinIdentifier: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        spokenFeedbackEnabled = defaults.object(forKey: Key.enabled) == nil ? true : defaults.bool(forKey: Key.enabled)
        selectedVoiceIdentifier = defaults.string(forKey: Key.identifier) ?? ""
        provider = VoiceFeedbackProvider(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .system
        fishModel = FishSpeechModel(rawValue: defaults.string(forKey: Key.fishModel) ?? "") ?? .defaultModel
        fishReferenceID = defaults.string(forKey: Key.fishReference) ?? ""
        reloadAvailableVoices()
    }

    func reloadAvailableVoices() {
        let standard = AVSpeechSynthesisVoice(language: "zh-CN")
        systemMandarinIdentifier = standard.flatMap { voice in
            guard voice.language == "zh-CN", !voice.voiceTraits.contains(.isNoveltyVoice),
                  !voice.voiceTraits.contains(.isPersonalVoice) else { return nil }
            return voice.identifier
        }
        availableVoices = VoiceFeedbackVoiceOption.sorted(AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("zh") && !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { VoiceFeedbackVoiceOption(id: $0.identifier, name: $0.name, language: $0.language, qualityRank: $0.quality.rawValue) },
            systemMandarinIdentifier: systemMandarinIdentifier)
    }

    var resolvedVoice: AVSpeechSynthesisVoice? {
        if let selected = VoiceFeedbackVoiceOption.selected(selectedVoiceIdentifier, from: availableVoices,
                systemMandarinIdentifier: systemMandarinIdentifier),
           let voice = AVSpeechSynthesisVoice(identifier: selected.id) { return voice }
        // A filtered-out voice must not re-enter through a fallback initializer.
        if let standard = AVSpeechSynthesisVoice(language: "zh-CN"),
           !standard.voiceTraits.contains(.isNoveltyVoice), !standard.voiceTraits.contains(.isPersonalVoice) { return standard }
        return nil
    }

    var selectedVoiceDescription: String {
        if provider == .fishAudio { return fishReferenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Fish Audio · 默认音色" : "Fish Audio · 自选音色" }
        if let selected = availableVoices.first(where: { $0.id == selectedVoiceIdentifier }) { return selected.displayName }
        let best = availableVoices.first?.displayName ?? "系统基础中文音色"
        return selectedVoiceIdentifier.isEmpty ? "自动 · \(best)" : "原音色不可用，暂用 \(best)"
    }
}

struct VoiceFeedbackSettingsView: View {
    @ObservedObject private var preferences = VoiceFeedbackPreferences.shared
    @ObservedObject private var voice = SessionVoiceController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fishAPIKey = ""
    @State private var fishKeySaved = false
    @State private var fishKeyMessage = ""
    @State private var fishKeyError = false
    @State private var confirmKeyRemoval = false

    private var featuredVoices: [VoiceFeedbackVoiceOption] {
        var result = Array(preferences.availableVoices.prefix(2))
        if let selected = preferences.availableVoices.first(where: { $0.id == preferences.selectedVoiceIdentifier }),
           !result.contains(where: { $0.id == selected.id }) {
            if result.count == 2 { result.removeLast() }
            result.append(selected)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) {
                PilotVoiceWaveform(active: voice.isPreviewingFeedback)
                Text("听见任务的进展")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Text("选择喜欢的声音，随时试听。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 4)
            PilotSettingsCard {
                Toggle(isOn: $preferences.spokenFeedbackEnabled) {
                    PilotSettingsRowLabel(title: "进度播报", subtitle: "会话语音开启时，播报关键进展", symbol: "speaker.wave.2")
                }.tint(PilotPalette.accent)
                    .accessibilityIdentifier("settings.spokenFeedback")
            }
            Picker("播报服务", selection: $preferences.provider) {
                ForEach(VoiceFeedbackProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.feedbackProvider")
            if preferences.provider == .fishAudio { fishSettings }
            else { systemVoices }
            Button {
                if voice.isPreviewingFeedback { voice.stopVoicePreview() }
                else { voice.previewFeedbackVoice() }
            } label: {
                Label(voice.isPreviewingFeedback ? "停止试听" : "试听这个声音",
                      systemImage: voice.isPreviewingFeedback ? "stop.fill" : "play.fill")
            }.pilotAction(prominent: true, fullWidth: true)
                .accessibilityIdentifier("settings.previewVoice")
            if !voice.voicePreviewMessage.isEmpty {
                PilotSettingsNotice(message: voice.voicePreviewMessage)
            }
            Text(preferences.provider == .fishAudio
                 ? "播报文字会发送至 Fish Audio。密钥保存在本机，试听不会开启任务播报。"
                 : "使用 iPhone 已下载的中文声音。试听不会开启任务播报。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)

        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: preferences.selectedVoiceIdentifier)
        .onChange(of: preferences.selectedVoiceIdentifier) { _, _ in voice.stopVoicePreview() }
        .onAppear {
            preferences.reloadAvailableVoices()
            fishKeySaved = (try? FishSpeechKeychain.load()) != nil
        }
        .confirmationDialog("移除 Fish Audio 密钥？", isPresented: $confirmKeyRemoval) {
            Button("移除密钥", role: .destructive) { saveFishKey(removing: true) }
        }
        .onDisappear { voice.stopVoicePreview() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            preferences.reloadAvailableVoices()
        }
    }

    private var fishSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            PilotSettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PilotSettingsRowLabel(title: "API Key", subtitle: fishKeySaved ? "已保存在此 iPhone" : "连接你的 Fish Audio 账户", symbol: "key")
                        Spacer(minLength: 8)
                        Link("获取", destination: URL(string: "https://fish.audio/app/api-keys")!)
                            .font(.subheadline).frame(minHeight: 44)
                    }
                    SecureField(fishKeySaved ? "输入新密钥以替换" : "粘贴 API Key", text: $fishAPIKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settings.fishAPIKey")
                        .padding(12).background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button(fishKeySaved ? "更新密钥" : "保存密钥") { saveFishKey() }
                            .disabled(fishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("settings.saveFishAPIKey")
                        Spacer()
                        if fishKeySaved {
                            Button("移除", role: .destructive) { confirmKeyRemoval = true }
                        }
                    }.font(.subheadline).frame(minHeight: 44)
                }
            }
            if !fishKeyMessage.isEmpty { PilotSettingsNotice(message: fishKeyMessage, isError: fishKeyError) }
            PilotSettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        PilotSettingsRowLabel(title: "音色", subtitle: "填入音色 ID，留空使用默认声音", symbol: "waveform")
                        Spacer(minLength: 8)
                        Link("选声音", destination: URL(string: "https://fish.audio/")!)
                            .font(.subheadline).frame(minHeight: 44)
                    }
                    TextField("Reference ID", text: $preferences.fishReferenceID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settings.fishReferenceID")
                        .padding(12).background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 12))
                    Divider()
                    Picker("语音模型", selection: $preferences.fishModel) {
                        ForEach(FishSpeechModel.allCases) { model in Text(model.displayName).tag(model) }
                    }.accessibilityIdentifier("settings.fishModel")
                }
            }
        }
    }

    private var systemVoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("中文音色").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
            voiceOption(id: "", name: "自动选择", detail: "优先使用已下载的高品质声音", symbol: "sparkles")
            ForEach(featuredVoices) { option in
                voiceOption(id: option.id, name: option.name, detail: "\(voiceRegion(option.language)) · \(option.qualityLabel)", symbol: "waveform")
            }
            Menu {
                Picker("中文音色", selection: $preferences.selectedVoiceIdentifier) {
                    Text("自动选择最佳音色").tag("")
                    if !preferences.selectedVoiceIdentifier.isEmpty,
                       !preferences.availableVoices.contains(where: { $0.id == preferences.selectedVoiceIdentifier }) {
                        Text("原音色已不可用").tag(preferences.selectedVoiceIdentifier)
                    }
                    ForEach(preferences.availableVoices) { option in Text(option.displayName).tag(option.id) }
                }
            } label: {
                HStack {
                    Text("更多音色")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("settings.feedbackVoice")
            if preferences.selectedVoiceIdentifier.isEmpty ||
                !preferences.availableVoices.contains(where: { $0.id == preferences.selectedVoiceIdentifier }) {
                Text(preferences.selectedVoiceDescription).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            if !preferences.availableVoices.contains(where: { $0.qualityRank > 1 }) {
                Link("下载高品质 iPhone 声音", destination: URL(string: "https://support.apple.com/zh-cn/111798")!)
                    .font(.caption).frame(minHeight: 44)
            }
        }
    }

    private func saveFishKey(removing: Bool = false) {
        voice.cancelCurrentFeedback()
        do {
            try FishSpeechKeychain.save(removing ? "" : fishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
            fishAPIKey = ""; fishKeySaved = !removing; fishKeyError = false
            fishKeyMessage = removing ? "密钥已移除。" : "密钥已保存，可以试听了。"
        } catch {
            fishKeyError = true
            fishKeyMessage = (error as? FishSpeechError)?.localizedDescription ?? "密钥未能保存，请解锁 iPhone 后重试。"
        }
    }

    private func voiceOption(id: String, name: String, detail: String, symbol: String) -> some View {
        let selected = preferences.selectedVoiceIdentifier == id
        return Button { preferences.selectedVoiceIdentifier = id } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular))
                    .foregroundStyle(PilotPalette.accent).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? PilotPalette.accent : Color.secondary.opacity(0.4))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace)).accessibilityHidden(true)
            }.padding(18).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? PilotPalette.accent.opacity(0.65) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func voiceRegion(_ language: String) -> String {
        language == "zh-CN" ? "普通话" : language == "zh-TW" ? "台湾普通话" : language == "zh-HK" ? "香港中文" : language
    }
}

/// Bind each persisted task phase once. Polling or a wall-clock adjustment cannot
/// extend an already bound phase; the host alone advances the execution phase.
struct SessionVoiceDeadline {
    private var phase: Int?
    private var expiresAt: Date?
    private(set) var uptimeDeadline: TimeInterval?
    private(set) var isUnlimited = false

    mutating func bind(phase nextPhase: Int, expiresAt nextExpiry: Date?, unlimited: Bool = false,
                       now: Date, uptime: TimeInterval) -> Bool {
        if nextPhase == 2, unlimited, nextExpiry == nil, uptime.isFinite {
            guard phase == nil || phase! < 2 || isUnlimited else { return false }
            phase = 2; expiresAt = nil; uptimeDeadline = nil; isUnlimited = true
            return true
        }
        guard !isUnlimited, let nextExpiry else { return false }
        guard (0...2).contains(nextPhase), nextExpiry > now, uptime.isFinite else { return false }
        let proposed = uptime + nextExpiry.timeIntervalSince(now)
        if let phase {
            guard nextPhase >= phase else { return false }
            if nextPhase == phase {
                guard let expiresAt, nextExpiry <= expiresAt, let uptimeDeadline else { return false }
                self.expiresAt = nextExpiry
                self.uptimeDeadline = min(uptimeDeadline, proposed)
                return uptime < self.uptimeDeadline!
            }
        }
        phase = nextPhase; expiresAt = nextExpiry; uptimeDeadline = proposed
        return true
    }
}

/// Explicit, bounded, on-device session listening. It never changes a task or controls hardware.
@MainActor
final class SessionVoiceController: NSObject, ObservableObject {
    static let shared = SessionVoiceController()
    @Published private(set) var isEnabled = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparingFeedback = false
    @Published private(set) var isPreviewingFeedback = false
    @Published private(set) var voicePreviewMessage = ""
    @Published private(set) var message = ""
    @Published private(set) var activeSessionID: String?
    var onCommand: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    private let fishSpeech = FishSpeechClient()
    private var fishPlayer: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    private var playbackGate = VoiceFeedbackPlaybackGate()
    private let activity = SessionVoiceAudioActivity()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var sessionLimit: Task<Void, Never>?
    private var segmentLimit: Task<Void, Never>?
    private var silenceWait: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var sessionGeneration = UUID()
    private var recognitionGeneration = UUID()
    private var voiceDeadline = SessionVoiceDeadline()
    private var withinDeadline: Bool { voiceDeadline.isUnlimited || (voiceDeadline.uptimeDeadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false) }
    private var expectedStopGeneration: String?
    private var isFinishing = false
    private var hasTap = false
    private var ownsAudioSession = false
    private var latestTranscript = ""
    private var pendingCommand: String?
    private var finalTranscript = false
    private var failures = 0
    private var deduplicator = SessionVoiceCommandDeduplicator()
    private var announcedKeys = Set<String>()
    private var pendingAnnouncement: String?
    private var utteranceID: ObjectIdentifier?
    private var activeSpokenText: String?
    private var previewResumeGeneration: UUID?
    private var previewLimit: Task<Void, Never>?
    private var preferenceObservers = Set<AnyCancellable>()

    private override init() {
        super.init()
        speaker.delegate = self
        let preferences = VoiceFeedbackPreferences.shared
        // @Published emits before storage changes. Use the emitted value and cancel
        // synchronously so a queued utterance cannot escape between the tap and mute.
        preferences.$spokenFeedbackEnabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.cancelCurrentFeedback() }
        }.store(in: &preferenceObservers)
        preferences.$selectedVoiceIdentifier.dropFirst().sink { [weak self] _ in
            self?.cancelCurrentFeedback()
        }.store(in: &preferenceObservers)
        preferences.$provider.dropFirst().sink { [weak self] _ in
            self?.cancelCurrentFeedback()
        }.store(in: &preferenceObservers)
        preferences.$fishModel.dropFirst().sink { [weak self] _ in
            self?.cancelCurrentFeedback()
        }.store(in: &preferenceObservers)
        preferences.$fishReferenceID.dropFirst().sink { [weak self] _ in
            self?.cancelCurrentFeedback()
        }.store(in: &preferenceObservers)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled || self.isRequestingPermission || self.isPreviewingFeedback else { return }
                self.stop()
                self.message = "音频被系统中断，会话语音已关闭。请回到 App 重新开启，或在输入框追加指令。"
            }
        }
    }

    @discardableResult
    func start(sessionID: String) async -> Bool {
        VoiceTaskRecorder.stopActive()
        stop()
        guard !sessionID.isEmpty, !Task.isCancelled,
              UIApplication.shared.applicationState == .active else {
            message = "请在 App 前台开启会话语音，也可以在输入框追加指令。"; return false
        }
        let token = UUID(); sessionGeneration = token
        activeSessionID = sessionID; expectedStopGeneration = SharedStore.shared.stopGeneration
        guard sessionIsCurrent() else {
            stop(); message = "会话已结束或许可已关闭，未开启麦克风。"; return false
        }
        isRequestingPermission = true; message = ""
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionGeneration == token else { return false }
        guard sessionIsCurrent() else { stop(); return false }
        guard !Task.isCancelled, permission == .authorized else {
            stop(); message = "请在系统设置中允许语音识别，也可以在输入框追加指令。"; return false
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard sessionGeneration == token else { return false }
        guard sessionIsCurrent() else { stop(); return false }
        guard !Task.isCancelled, microphone, UIApplication.shared.applicationState == .active else {
            stop(); message = "请在 App 前台允许麦克风后重试，也可以在输入框追加指令。"; return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            stop(); message = "当前设备暂不支持中文本地会话语音，请在输入框追加指令。"; return false
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audio.setActive(true); ownsAudioSession = true
            self.recognizer = recognizer; isRequestingPermission = false; isEnabled = true
            deduplicator = SessionVoiceCommandDeduplicator(); announcedKeys.removeAll(); failures = 0
            try beginRecognition()
            message = "会话语音已开启，将随任务结束关闭。先说“小视”再追加指令；后台收音仍受系统和音频中断限制。"
            sessionLimit = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.sessionGeneration == token else { return }
                    guard self.sessionIsCurrent() else {
                        self.stop(); self.message = "任务已结束或授权已到期，会话语音已关闭。"; return
                    }
                }
            }
            return true
        } catch {
            stop(); message = "会话语音暂时无法开始，请检查麦克风，也可以在输入框追加指令。"; return false
        }
    }

    func stop() {
        sessionGeneration = UUID()
        sessionLimit?.cancel(); sessionLimit = nil
        restart?.cancel(); restart = nil
        endRecognition()
        cancelSpeechOutput(); pendingAnnouncement = nil
        previewResumeGeneration = nil
        previewLimit?.cancel(); previewLimit = nil; isPreviewingFeedback = false
        isSpeaking = false; isEnabled = false; isRequestingPermission = false
        activeSessionID = nil; recognizer = nil; voiceDeadline = SessionVoiceDeadline()
        expectedStopGeneration = nil; isFinishing = false
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        message = "会话语音已关闭。"
    }

    /// The caller supplies the shared command snapshot; this method never writes it.
    func update(status: PilotStatus, command: SessionCommand?) {
        guard isEnabled || isRequestingPermission else { return }
        guard let command, command.id == activeSessionID,
              SharedStore.shared.configuration.uploadConsent,
              SharedStore.shared.stopGeneration == expectedStopGeneration else { stop(); return }
        guard !isFinishing else { return }
        if !command.running {
            if status.sessionID == activeSessionID, status.phase == "完成", isEnabled {
                finishWithAnnouncement("本次任务已结束，请检查实际结果。")
            } else { stop() }
            return
        }
        guard isEnabled, status.sessionID == activeSessionID else { return }
        if status.phase == "完成" {
            finishWithAnnouncement("本次任务已结束，请检查实际结果。")
            return
        }
        let phrase: String
        switch status.phase {
        case "待广播": phrase = "准备好了，请确认系统屏幕广播。"
        case "规划": phrase = "我在看画面，判断下一步。"
        case "执行": phrase = "正在执行第\(status.steps + 1)步。"
        case "等待用户": phrase = "有个问题需要你选择，请查看实时活动。"
        case "暂停", "需确认", "等待确认": phrase = "任务已暂停，请回到小视查看。"
        default: return
        }
        // Repeated polling and observe/plan transitions at the same step stay silent.
        let key = command.pendingClarification.map { "question:\($0.id)" }
            ?? (status.phase == "规划" ? "planning" : "\(status.phase):\(status.steps)")
        announce(phrase, key: key)
    }

    func announce(_ text: String, key: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceFeedbackPreferences.shared.spokenFeedbackEnabled, !isPreviewingFeedback,
              isEnabled, !isFinishing, sessionIsCurrent(), withinDeadline,
              !phrase.isEmpty, phrase.count <= 120, !announcedKeys.contains(key) else { return }
        announcedKeys.insert(key)
        pendingAnnouncement = phrase // Keep only the latest status while a phrase is speaking.
        guard !isSpeaking, !isPreparingFeedback, pendingCommand == nil else { return }
        speakPendingAnnouncement()
    }

    private func beginRecognition() throws {
        guard isEnabled, !isFinishing, sessionIsCurrent(), !isSpeaking, withinDeadline,
              let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw PilotError.message("本地会话语音当前不可用。")
        }
        endRecognition()
        let token = UUID(); recognitionGeneration = token
        let sessionToken = sessionGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PilotError.message("麦克风当前不可用。")
        }
        activity.reset()
        let activity = self.activity
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            activity.record(buffer); request.append(buffer)
        }
        hasTap = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == sessionToken,
                      self.recognitionGeneration == token, self.isEnabled, !self.isSpeaking else { return }
                self.receive(text: text, final: final, failed: failed, token: token)
            }
        }
        engine.prepare(); try engine.start(); isListening = true
        segmentLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(55))
            guard !Task.isCancelled, let self, self.recognitionGeneration == token else { return }
            self.scheduleRestart()
        }
    }

    private func receive(text: String?, final: Bool, failed: Bool, token: UUID) {
        if let text, text != latestTranscript {
            failures = 0; latestTranscript = text
            pendingCommand = SessionVoiceWakeParser.command(in: text)
            silenceWait?.cancel(); silenceWait = nil
            if pendingCommand != nil { waitForCommand(token: token) }
        }
        finalTranscript = finalTranscript || final
        if final {
            stopCapture(); request?.endAudio(); segmentLimit?.cancel(); segmentLimit = nil
            if pendingCommand == nil { scheduleRestart() }
        } else if failed {
            failures += 1
            if failures >= 3 {
                stop(); message = "本地语音识别已中断，请回到 App 重新开启，或在输入框追加指令。"
            } else { scheduleRestart(delay: 0.5) }
        }
    }

    private func waitForCommand(token: UUID) {
        silenceWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self, self.recognitionGeneration == token, self.isEnabled,
                      !self.isSpeaking, let command = self.pendingCommand else { return }
                if self.finalTranscript || self.activity.hasBeenQuiet(for: 1) {
                    guard self.sessionIsCurrent() else { self.stop(); return }
                    let accepted = self.deduplicator.accept(command, at: ProcessInfo.processInfo.systemUptime)
                    self.endRecognition() // Invalidates this segment before invoking user code.
                    if accepted {
                        self.cancelSpeechOutput(); self.pendingAnnouncement = nil
                        self.onCommand?(command)
                    }
                    guard self.isEnabled, !self.isFinishing else { return }
                    if self.pendingAnnouncement != nil { self.speakPendingAnnouncement() }
                    else { self.scheduleRestart() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func scheduleRestart(delay: TimeInterval = 0.2) {
        endRecognition()
        restart?.cancel()
        let token = sessionGeneration
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.sessionGeneration == token,
                  self.isEnabled, !self.isFinishing, !self.isSpeaking else { return }
            guard self.sessionIsCurrent(), self.withinDeadline else { self.stop(); return }
            do { try self.beginRecognition() }
            catch { self.stop(); self.message = "会话收音已停止，请回到 App 重新开启，或在输入框追加指令。" }
        }
    }

    private func endRecognition() {
        recognitionGeneration = UUID()
        segmentLimit?.cancel(); segmentLimit = nil
        silenceWait?.cancel(); silenceWait = nil
        stopCapture()
        request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil
        latestTranscript = ""; pendingCommand = nil; finalTranscript = false
    }

    private func stopCapture() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        isListening = false
    }

    private func speakPendingAnnouncement() {
        guard isEnabled, !isSpeaking, !isPreparingFeedback, let phrase = pendingAnnouncement else { return }
        guard VoiceFeedbackPreferences.shared.spokenFeedbackEnabled else {
            pendingAnnouncement = nil
            if isFinishing { stop() } else { scheduleRestart() }
            return
        }
        pendingAnnouncement = nil
        restart?.cancel(); restart = nil
        // Cloud generation stays quiet: keep wake-word recognition until audio is ready.
        if VoiceFeedbackPreferences.shared.provider == .system { endRecognition() }
        speak(phrase)
    }

    private func speechFinished(_ id: ObjectIdentifier) {
        guard utteranceID == id else { return }
        completeSpeech()
    }

    private func audioFinished(_ id: ObjectIdentifier, successfully: Bool) {
        guard let player = fishPlayer, ObjectIdentifier(player) == id else { return }
        if !successfully {
            failSpeech("Fish Audio 音频未能播放，请重新试听。")
        } else { completeSpeech() }
    }

    private func completeSpeech() {
        playbackGate.cancel()
        synthesisTask = nil; fishPlayer = nil
        utteranceID = nil; activeSpokenText = nil; isSpeaking = false; isPreparingFeedback = false
        if isPreviewingFeedback { finishVoicePreview(); return }
        guard isEnabled else { return }
        if isFinishing { stop(); message = "任务已结束，会话语音已关闭。"; return }
        if pendingAnnouncement != nil { speakPendingAnnouncement() }
        else { scheduleRestart(delay: 0.3) }
    }

    private func sessionIsCurrent() -> Bool {
        guard let id = activeSessionID, let command = SharedStore.shared.command else { return false }
        let now = Date()
        guard command.id == id, command.authorizationIsCurrent(now: now),
              SharedStore.shared.configuration.uploadConsent,
              SharedStore.shared.stopGeneration == expectedStopGeneration else { return false }
        let phase: Int
        switch command.execution?.phase {
        case .active: phase = 2
        case .startingHardware: phase = 1
        case .awaitingCapture, .none: phase = 0
        }
        return voiceDeadline.bind(phase: phase, expiresAt: command.authorizationExpiresAt, unlimited: command.isUnlimited,
            now: now, uptime: ProcessInfo.processInfo.systemUptime)
    }

    private func finishWithAnnouncement(_ phrase: String) {
        guard VoiceFeedbackPreferences.shared.spokenFeedbackEnabled else { stop(); return }
        isFinishing = true
        previewLimit?.cancel(); previewLimit = nil
        isPreviewingFeedback = false; previewResumeGeneration = nil
        restart?.cancel(); restart = nil
        endRecognition()
        cancelSpeechOutput()
        pendingAnnouncement = phrase
        sessionLimit?.cancel()
        let token = sessionGeneration
        sessionLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, let self, self.sessionGeneration == token else { return }
            self.stop() // Synthesis itself times out at 30 seconds; release even if a callback is lost.
        }
        speakPendingAnnouncement()
    }

    /// An explicit, foreground-only sample shares the same half-duplex audio coordinator.
    func previewFeedbackVoice() {
        guard UIApplication.shared.applicationState == .active, !isFinishing else {
            voicePreviewMessage = "请在 App 前台试听音色。"; return
        }
        if isPreviewingFeedback { stopVoicePreview() }
        if isRequestingPermission || (isEnabled && !sessionIsCurrent()) { stop() }
        VoiceTaskRecorder.stopActive()
        restart?.cancel(); restart = nil
        endRecognition()
        cancelSpeechOutput(); pendingAnnouncement = nil
        VoiceFeedbackPreferences.shared.reloadAvailableVoices()
        guard VoiceFeedbackPreferences.shared.provider == .fishAudio || VoiceFeedbackPreferences.shared.resolvedVoice != nil else {
            voicePreviewMessage = "此 iPhone 暂无可用中文音色。"
            if isEnabled { scheduleRestart() }
            return
        }
        do {
            if !isEnabled {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
                try audio.setActive(true); ownsAudioSession = true
            }
            previewResumeGeneration = isEnabled ? sessionGeneration : nil
            isPreviewingFeedback = true
            voicePreviewMessage = "正在试听：\(VoiceFeedbackPreferences.shared.selectedVoiceDescription)"
            speak("你好，我是小视。我会一边观察画面，一边帮你完成任务。")
        } catch {
            voicePreviewMessage = "暂时无法试听，请检查当前音频输出后再试。"
            if isEnabled { scheduleRestart() }
            else if ownsAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
            }
        }
    }

    func stopVoicePreview() {
        guard isPreviewingFeedback else { return }
        cancelSpeechOutput()
        finishVoicePreview()
    }

    private func finishVoicePreview() {
        let resumeToken = previewResumeGeneration
        isPreviewingFeedback = false; previewResumeGeneration = nil
        previewLimit?.cancel(); previewLimit = nil
        voicePreviewMessage = "试听已结束。"
        if isEnabled {
            guard resumeToken == sessionGeneration, sessionIsCurrent(),
                  withinDeadline else { stop(); return }
            scheduleRestart(delay: 0.3)
        } else if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func speak(_ phrase: String) {
        let preferences = VoiceFeedbackPreferences.shared
        guard isPreviewingFeedback || feedbackSessionIsCurrent() else { cancelCurrentFeedback(); return }
        let intent: VoiceFeedbackPlaybackGate.Intent = isPreviewingFeedback ? .preview : .automatic
        guard let token = playbackGate.begin(intent: intent, feedbackEnabled: preferences.spokenFeedbackEnabled) else {
            pendingAnnouncement = nil
            if isFinishing { stop() } else if isEnabled { scheduleRestart() }
            return
        }
        activeSpokenText = phrase
        if preferences.provider == .fishAudio {
            isPreparingFeedback = true
            let configuration = FishSpeechConfiguration(model: preferences.fishModel, referenceID: preferences.fishReferenceID)
            let apiKey: String
            do {
                guard let savedKey = try FishSpeechKeychain.load(), !savedKey.isEmpty else {
                    failSpeech("请先在语音与播报中保存 Fish Audio 密钥。"); return
                }
                apiKey = savedKey
            } catch {
                failSpeech("暂时无法读取 Fish Audio 密钥，请解锁 iPhone 后重试。"); return
            }
            if isPreviewingFeedback { voicePreviewMessage = "正在生成试听声音…" }
            synthesisTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let audio = try await self.fishSpeech.synthesize(text: phrase, configuration: configuration, apiKey: apiKey)
                    guard !Task.isCancelled,
                          self.playbackGate.permits(token, feedbackEnabled: VoiceFeedbackPreferences.shared.spokenFeedbackEnabled) else { return }
                    if self.isPreviewingFeedback, UIApplication.shared.applicationState != .active {
                        self.stopVoicePreview(); return
                    }
                    // A response can arrive after STOP, expiry or a session replacement.
                    guard self.isPreviewingFeedback || self.feedbackSessionIsCurrent() else {
                        self.cancelCurrentFeedback(); return
                    }
                    guard self.pendingCommand == nil else {
                        self.cancelSpeechOutput(); return // Let an in-progress user command finish first.
                    }
                    let player = try AVAudioPlayer(data: audio)
                    player.delegate = self
                    self.fishPlayer = player
                    self.restart?.cancel(); self.restart = nil
                    self.endRecognition() // Half duplex starts at playback, not during synthesis.
                    self.isPreparingFeedback = false; self.isSpeaking = true
                    guard player.prepareToPlay(), player.play() else {
                        self.failSpeech("Fish Audio 音频未能播放，请重新试听。"); return
                    }
                    self.limitPlayback(token: token, duration: min(30, max(5, player.duration + 2)))
                    if self.isPreviewingFeedback { self.voicePreviewMessage = "正在试听：\(VoiceFeedbackPreferences.shared.selectedVoiceDescription)" }
                } catch {
                    guard !Task.isCancelled,
                          self.playbackGate.permits(token, feedbackEnabled: VoiceFeedbackPreferences.shared.spokenFeedbackEnabled) else { return }
                    self.failSpeech(error.localizedDescription)
                }
            }
            if !isPreviewingFeedback, !isFinishing, !isListening { scheduleRestart() }
        } else {
            guard let voice = preferences.resolvedVoice else {
                failSpeech("此 iPhone 暂无可用中文音色。"); return
            }
            isSpeaking = true
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
            utterance.pitchMultiplier = 1
            utteranceID = ObjectIdentifier(utterance)
            speaker.speak(utterance)
            limitPlayback(token: token, duration: 25)
        }
    }

    private func feedbackSessionIsCurrent() -> Bool {
        guard isEnabled, let id = activeSessionID,
              let command = SharedStore.shared.command, command.id == id,
              SharedStore.shared.configuration.uploadConsent,
              SharedStore.shared.stopGeneration == expectedStopGeneration else { return false }
        // Completion has already ended the task, but STOP still invalidates its final phrase.
        return isFinishing || sessionIsCurrent()
    }

    private func limitPlayback(token: UUID, duration: TimeInterval) {
        guard isPreviewingFeedback || isFinishing else { return }
        let limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self,
                  self.playbackGate.permits(token, feedbackEnabled: VoiceFeedbackPreferences.shared.spokenFeedbackEnabled) else { return }
            if self.isPreviewingFeedback { self.stopVoicePreview() }
            else if self.isFinishing { self.stop() }
        }
        if isPreviewingFeedback { previewLimit?.cancel(); previewLimit = limit }
        else { sessionLimit?.cancel(); sessionLimit = limit }
    }

    private func failSpeech(_ reason: String) {
        let wasPreview = isPreviewingFeedback
        cancelSpeechOutput()
        pendingAnnouncement = nil
        if wasPreview { finishVoicePreview() }
        else if isFinishing { stop() }
        else if isEnabled, !isListening { scheduleRestart(delay: 0.3) }
        voicePreviewMessage = reason
        if !wasPreview { message = reason }
    }

    private func cancelSpeechOutput() {
        playbackGate.cancel()
        synthesisTask?.cancel(); synthesisTask = nil
        fishPlayer?.delegate = nil; fishPlayer?.stop(); fishPlayer = nil
        utteranceID = nil; activeSpokenText = nil
        speaker.stopSpeaking(at: .immediate); isSpeaking = false; isPreparingFeedback = false
    }

    /// Stops current output without disabling an independently enabled microphone.
    func cancelCurrentFeedback() {
        pendingAnnouncement = nil
        if isPreviewingFeedback { stopVoicePreview(); return }
        let wasSpeaking = isSpeaking
        cancelSpeechOutput()
        if isFinishing { stop() }
        else if wasSpeaking, isEnabled {
            guard sessionIsCurrent() else { stop(); return }
            scheduleRestart(delay: 0.3)
        }
    }

}

extension SessionVoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speechFinished(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speechFinished(id) }
    }
}


extension SessionVoiceController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.audioFinished(id, successfully: flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.audioFinished(id, successfully: false) }
    }
}
