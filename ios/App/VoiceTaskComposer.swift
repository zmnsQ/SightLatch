import SwiftUI
import Speech
import AVFoundation
import UIKit

/// Short, foreground-only dictation. Recognition never submits a task or starts a broadcast.
@MainActor
final class VoiceTaskRecorder: ObservableObject {
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
