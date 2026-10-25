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

/// App-only output preferences. They grant no microphone, task or screen-upload permission.
@MainActor
final class VoiceFeedbackPreferences: ObservableObject {
    static let shared = VoiceFeedbackPreferences()
    private enum Key {
        static let enabled = "SightLatch.voiceFeedback.enabled"
        static let identifier = "SightLatch.voiceFeedback.voiceIdentifier"
    }
    @Published var spokenFeedbackEnabled: Bool {
        didSet { defaults.set(spokenFeedbackEnabled, forKey: Key.enabled) }
    }
    @Published var selectedVoiceIdentifier: String {
        didSet { defaults.set(selectedVoiceIdentifier, forKey: Key.identifier) }
    }
    @Published private(set) var availableVoices: [VoiceFeedbackVoiceOption] = []
    private var systemMandarinIdentifier: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        spokenFeedbackEnabled = defaults.object(forKey: Key.enabled) == nil ? true : defaults.bool(forKey: Key.enabled)
        selectedVoiceIdentifier = defaults.string(forKey: Key.identifier) ?? ""
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
        if let selected = availableVoices.first(where: { $0.id == selectedVoiceIdentifier }) { return selected.displayName }
        let best = availableVoices.first?.displayName ?? "系统基础中文音色"
        return selectedVoiceIdentifier.isEmpty ? "自动 · \(best)" : "原音色不可用，暂用 \(best)"
    }
}

struct VoiceFeedbackSettingsView: View {
    @ObservedObject private var preferences = VoiceFeedbackPreferences.shared
    @ObservedObject private var voice = SessionVoiceController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    PilotSettingsRowLabel(title: "进度播报", subtitle: "在关键步骤告诉你发生了什么", symbol: "speaker.wave.2")
                }.tint(PilotPalette.accent)
                    .accessibilityIdentifier("settings.spokenFeedback")
            }
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
                }
                    .accessibilityIdentifier("settings.feedbackVoice")
                if preferences.selectedVoiceIdentifier.isEmpty ||
                    !preferences.availableVoices.contains(where: { $0.id == preferences.selectedVoiceIdentifier }) {
                    Text(preferences.selectedVoiceDescription).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                }
            }
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
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("仅控制任务播报，不改变麦克风状态。关闭播报后，已开启的会话语音仍可用“小视”追加指令。")
                    Text("仅使用此 iPhone 已有的中文声音，优先高级和增强音色。试听不会开启播报，也不会提交指令。")
                    if !preferences.availableVoices.contains(where: { $0.qualityRank > 1 }) {
                        Text("当前只有基础音色。可到 iPhone「设置 → 辅助功能 → 阅读与朗读 → 声音 → 中文」下载增强或高级声音；旧系统入口名为「朗读内容」。下载后返回此页即可更新。")
                        Link("Apple 音色下载说明", destination: URL(string: "https://support.apple.com/zh-cn/111798")!)
                            .frame(minHeight: 44)
                    }
                }.font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            } label: {
                Text("音色与下载").frame(minHeight: 44)
            }.font(.subheadline).padding(.horizontal, 4)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: preferences.selectedVoiceIdentifier)
        .onChange(of: preferences.selectedVoiceIdentifier) { _, _ in voice.stopVoicePreview() }
        .onAppear { preferences.reloadAvailableVoices() }
        .onDisappear { voice.stopVoicePreview() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            preferences.reloadAvailableVoices()
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
    @Published private(set) var isPreviewingFeedback = false
    @Published private(set) var voicePreviewMessage = ""
    @Published private(set) var message = ""
    @Published private(set) var activeSessionID: String?
    var onCommand: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
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
        preferences.$spokenFeedbackEnabled.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyFeedbackMute() }
        }.store(in: &preferenceObservers)
        preferences.$selectedVoiceIdentifier.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.replaceCurrentFeedbackVoice() }
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
        utteranceID = nil; pendingAnnouncement = nil
        activeSpokenText = nil; previewResumeGeneration = nil
        previewLimit?.cancel(); previewLimit = nil; isPreviewingFeedback = false
        speaker.stopSpeaking(at: .immediate)
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
        guard !isSpeaking, pendingCommand == nil else { return }
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
                    if accepted { self.onCommand?(command) }
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
        guard isEnabled, !isSpeaking, let phrase = pendingAnnouncement else { return }
        guard VoiceFeedbackPreferences.shared.spokenFeedbackEnabled else {
            pendingAnnouncement = nil
            if isFinishing { stop() } else { scheduleRestart() }
            return
        }
        pendingAnnouncement = nil
        restart?.cancel(); restart = nil
        endRecognition() // Half duplex: our own speech never reaches the recognizer.
        speak(phrase)
    }

    private func speechFinished(_ id: ObjectIdentifier) {
        guard utteranceID == id else { return }
        utteranceID = nil; activeSpokenText = nil; isSpeaking = false
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
        utteranceID = nil; speaker.stopSpeaking(at: .immediate); isSpeaking = false
        pendingAnnouncement = phrase
        speakPendingAnnouncement()
        sessionLimit?.cancel()
        let token = sessionGeneration
        sessionLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.sessionGeneration == token else { return }
            self.stop() // A missing TTS callback cannot retain the audio session.
        }
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
        utteranceID = nil; speaker.stopSpeaking(at: .immediate)
        isSpeaking = false; pendingAnnouncement = nil
        VoiceFeedbackPreferences.shared.reloadAvailableVoices()
        guard VoiceFeedbackPreferences.shared.resolvedVoice != nil else {
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
            previewLimit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.stopVoicePreview()
            }
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
        utteranceID = nil; activeSpokenText = nil
        speaker.stopSpeaking(at: .immediate); isSpeaking = false
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
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = VoiceFeedbackPreferences.shared.resolvedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.pitchMultiplier = 1
        activeSpokenText = phrase
        utteranceID = ObjectIdentifier(utterance); isSpeaking = true
        speaker.speak(utterance)
    }

    private func applyFeedbackMute() {
        guard !VoiceFeedbackPreferences.shared.spokenFeedbackEnabled else { return }
        pendingAnnouncement = nil
        if isPreviewingFeedback { stopVoicePreview(); return }
        guard isSpeaking else { return }
        utteranceID = nil; activeSpokenText = nil
        speaker.stopSpeaking(at: .immediate); isSpeaking = false
        if isFinishing { stop() }
        else if isEnabled {
            guard sessionIsCurrent() else { stop(); return }
            scheduleRestart(delay: 0.3)
        }
    }

    private func replaceCurrentFeedbackVoice() {
        guard isSpeaking, let phrase = activeSpokenText,
              isPreviewingFeedback || VoiceFeedbackPreferences.shared.spokenFeedbackEnabled else { return }
        utteranceID = nil; speaker.stopSpeaking(at: .immediate); isSpeaking = false
        speak(phrase)
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
