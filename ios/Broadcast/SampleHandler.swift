import ReplayKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// ReplayKit invokes entry points on framework-owned threads. Every mutable field below,
// including CIContext use, is confined to `queue`; async work uses immutable snapshots
// and re-enters that queue before reading or mutating capture state. `store` is immutable
// and SharedStore serializes its file operations on its own queue (plus cross-process locks).
// This explicit queue confinement is the Sendable invariant, not permission to access
// capture state from Task closures. Keep the preconditions on queue-only helpers.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "HIDPilot.capture")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var work: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var stopped = false
    private var paused = false
    private var latestFingerprint = [UInt8]()
    private var latestObservedAt = Date.distantPast
    private var observationEnqueuedAt = Date.distantPast
    private var lastCapture = Date.distantPast
    private var steps = 0
    private var generation = -1
    private var sessionID = ""
    private var hardwareSession = ""
    private var config = PilotConfiguration()
    private var agent: AgentSession?
    private let store = SharedStore.shared

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.config = self.store.configuration
            guard self.store.available, let command = self.store.command, command.running,
                  self.config.uploadConsent, self.config.relativeModeConfirmed, !self.config.model.isEmpty else {
                self.finishBroadcastWithError(PilotError.message("请先在主 App 配置并准备会话，授权屏幕上传和相对指针模式。")); return
            }
            do { try self.config.validate() }
            catch { self.finishBroadcastWithError(error); return }
            self.sessionID = command.id
            self.generation = command.generation
            self.agent = AgentSession(id: command.id, startedAt: command.createdAt, maxRounds: self.config.maxSteps)
            self.lastCapture = Date().addingTimeInterval(4)
            self.latestObservedAt = Date()
            self.publish("观察", "等待新帧；若截图看不到指针则暂停")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.pollControl() }
            self.timer = timer
            timer.resume()
        }
    }

    private func pollControl() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        guard store.configuration.uploadConsent, let command = store.command, command.id == sessionID, command.running else {
            stopAndFinish("用户停止会话"); return
        }
        if config.continuedProcessingEnabled == true {
            guard let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == sessionID, lease.expiresAt > Date() else {
                stopAndFinish("后台协调租约已失效；禁止继续采集或执行"); return
            }
        }
        if command.generation != generation {
            generation = command.generation
            work?.cancel()
            // A new generation never replays the prior proposal. The next frame must be newly captured.
            paused = false
            agent?.manualResume()
            hardwareSession = ""
            lastCapture = Date().addingTimeInterval(4)
            publish("观察", "已确认人工处理；等待新的目标画面")
        }
        if !paused && Date().timeIntervalSince(latestObservedAt) > 45 { stopAndFinish("45秒未收到新广播画面"); return }
        if Date().timeIntervalSince(command.createdAt) >= 300 { stopAndFinish("会话已达五分钟上限") }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber)?.int32Value ?? 1
        let sampledAt = Date()
        // Keep at most one frame observation every 300ms, including during AI inference.
        let observe = queue.sync { () -> Bool in
            guard !stopped, !paused, Date().timeIntervalSince(observationEnqueuedAt) >= 0.3 else { return false }
            observationEnqueuedAt = Date()
            return true
        }
        guard observe else { return }
        // ReplayKit owns the sample-buffer lifetime. Finish pixel reads/encoding before
        // this callback returns; only copied JPEG/fingerprint values enter async work.
        queue.sync { [weak self] in
            guard let self else { return }
            guard !self.stopped, !self.paused else { return }
            let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: orientation)
            self.latestFingerprint = self.fingerprint(oriented)
            self.latestObservedAt = sampledAt
            guard !self.busy, Date().timeIntervalSince(self.lastCapture) >= (self.config.continuedProcessingEnabled == true ? 1 : max(2, self.config.frameInterval)) else { return }
            self.busy = true
            self.lastCapture = Date()
            let decisionFingerprint = self.latestFingerprint
            let capturedAt = sampledAt
            let frameID = UUID().uuidString
            let capturedGeneration = self.generation
            guard let command = self.store.command, command.id == self.sessionID, command.running else { self.busy = false; return }
            guard self.steps < min(50, max(1, self.config.maxSteps)) else { self.stopAndFinish("达到最大步数"); return }
            let jpeg: Data? = autoreleasepool {
                var source = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: orientation)
                let scale = min(1, 768 / max(source.extent.width, source.extent.height))
                source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let color = CGColorSpaceCreateDeviceRGB()
                return self.context.jpegRepresentation(of: source, colorSpace: color, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55])
            }
            guard let jpeg, jpeg.count < 600_000 else { self.pause("截图编码失败或超过内存预算"); self.busy = false; return }
            let configuration = self.config
            if configuration.continuedProcessingEnabled == true {
                do {
                    let frame = SharedFrame(sessionID: self.sessionID, id: frameID, capturedAt: capturedAt, jpeg: jpeg, fingerprint: Data(decisionFingerprint))
                    try self.store.write(frame, to: "frame.json")
                } catch { self.stopAndFinish("无法安全暂存最新广播帧") }
                self.busy = false
                return
            }
            guard self.agent?.accepts(frameID: frameID, capturedAt: capturedAt) == true else { self.busy = false; return }
            do { try self.agent?.observe(frameID: frameID, capturedAt: capturedAt, fingerprint: Data(decisionFingerprint)) }
            catch { self.pause(error.localizedDescription); self.busy = false; Task { await HardwareClient(configuration: configuration).stop() }; return }
            let modelContext = self.agent?.modelContext ?? ""
            self.publish("规划", "正在根据新画面和上一轮执行结果选择下一步")
            self.work = Task { [weak self] in
                guard let self else { return }
                defer { self.queue.async { self.busy = false; self.work = nil } }
                var requestedModel = false
                var receivedProposal = false
                var dispatched = false
                do {
                    let hardware = HardwareClient(configuration: configuration)
                    let device = try await hardware.status()
                    guard device.armed, device.hid_connected else { throw PilotError.message("请先物理 ARM，并确认 ESP32 已以 BLE HID 配对。") }
                    try Task.checkCancellation()
                    guard let beforeUpload = self.store.command, beforeUpload.id == command.id,
                          beforeUpload.generation == capturedGeneration, beforeUpload.running,
                          self.store.configuration.uploadConsent else { return }
                    requestedModel = true
                    let proposal = try await AIClient(configuration: configuration).propose(jpeg: jpeg, task: command.task, frameID: frameID, context: modelContext)
                    receivedProposal = true
                    try Task.checkCancellation()
                    guard let latest = self.store.command, latest.running, latest.id == command.id,
                          latest.generation == capturedGeneration else { return }
                    let deadline = capturedAt.addingTimeInterval(min(20, max(3, configuration.maxFrameAge)))
                    guard Date() < deadline else { throw PilotError.message("AI 返回时截图已过期；禁止执行。") }
                    guard self.queue.sync(execute: { self.frameIsStable(comparedTo: decisionFingerprint) }) else {
                        throw PilotError.message("规划期间画面变化或没有新帧，旧动作已丢弃。")
                    }
                    if let reason = SafetyGate.rejection(proposal, task: command.task, config: configuration) {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.pause("\(reason)。提案：\(proposal.description)。请在目标 App 人工完成后回此 App 确认。")
                        }
                        await hardware.stop(); return
                    }
                    if proposal.type == .done {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.stopAndFinish("AI 认为任务完成；请人工确认实际结果", phase: "完成")
                        }; return
                    }
                    if proposal.type == .wait {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.agent?.record(action: "wait", outcome: "No HID sent. Observe a newer screen.")
                            self.steps += 1; self.publish("观察", "模型等待下一帧")
                        }; return
                    }
                    self.queue.async { if !self.stopped && !self.paused && self.generation == capturedGeneration { self.publish("执行", proposal.description) } }
                    try Task.checkCancellation()
                    guard let current = self.store.command, current.running, current.id == command.id, current.generation == capturedGeneration else { return }
                    dispatched = true
                    try await hardware.send(proposal, expectedSession: device.session_id, frameDeadline: deadline, stillAuthorized: {
                        guard let current = self.store.command, current.running, current.id == command.id, current.generation == capturedGeneration,
                              self.store.configuration.uploadConsent else { return false }
                        return self.queue.sync { !self.stopped && !self.paused && self.frameIsStable(comparedTo: decisionFingerprint) }
                    }, sessionAuthorized: {
                        guard let current = self.store.command else { return false }
                        return Date().timeIntervalSince(command.createdAt) < 300 && current.running && current.id == command.id && current.generation == capturedGeneration && self.store.configuration.uploadConsent
                    })
                    let completedAt = Date()
                    self.queue.async {
                        guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                        let action = (try? JSONEncoder().encode(proposal)).flatMap { String(data: $0, encoding: .utf8) } ?? proposal.description
                        self.agent?.record(action: action, outcome: "hardware_completed; UI effect must be verified in the next observation", at: completedAt)
                        self.steps += 1
                        self.store.log("步骤 \(self.steps)：\(proposal.description)；硬件完成，等待新画面验证", sessionID: self.sessionID)
                        self.publish("观察", "硬件已完成，等待新帧判断界面效果")
                        self.lastCapture = Date()
                    }
                } catch is CancellationError {
                    // Stop is independent of this cancelled task, so key/button release is still attempted.
                    let cleanup = Task.detached { await HardwareClient(configuration: configuration).stop() }
                    await cleanup.value
                } catch {
                    // Re-observe only before any dispatch. Never retry an uncertain HID request.
                    let reason = receivedProposal ? "Proposal discarded because its screen is stale or changed; no HID sent." : "Model request failed; no HID sent."
                    let canRecover = requestedModel && !dispatched && self.queue.sync { () -> Bool in
                        guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return false }
                        return self.agent?.recoverBeforeDispatch(reason) == true
                    }
                    if canRecover {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.publish("观察", "本轮未执行，等待新画面重新规划（最多重试两次）"); self.lastCapture = Date()
                        }
                    } else {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.pause(error.localizedDescription)
                        }
                        let cleanup = Task.detached { await HardwareClient(configuration: configuration).stop() }
                        await cleanup.value
                    }
                }
            }
        }
    }

    override func broadcastPaused() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.config.continuedProcessingEnabled == true { self.stopAndFinish("系统广播暂停，后台会话结束"); return }
            self.work?.cancel(); self.pause("系统广播暂停；请回主 App 重新确认并物理 ARM")
            self.stopHardware()
        }
    }
    override func broadcastResumed() {
        // Do not resume side effects automatically after lock, system interruptions or permission changes.
        queue.async { [weak self] in self?.pause("广播已恢复；仍保持安全暂停，请回主 App 确认") }
    }
    override func broadcastFinished() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true; self.work?.cancel(); self.timer?.cancel(); self.timer = nil
            self.endCaptureSession()
            if self.store.status.phase != "完成" { self.publish("停止", "系统广播已结束") }
            self.stopHardware()
        }
    }
    // Conservative coarse change detector, not a proof of UI/target identity.
    private func fingerprint(_ source: CIImage) -> [UInt8] {
        dispatchPrecondition(condition: .onQueue(queue))
        let bounds = source.extent
        let transformed = source.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: CGAffineTransform(scaleX: 32 / bounds.width, y: 32 / bounds.height))
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            if let address = buffer.baseAddress {
                context.render(transformed, toBitmap: address, rowBytes: 128, bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
        }
        return pixels
    }
    private func frameIsStable(comparedTo prior: [UInt8]) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !prior.isEmpty, prior.count == latestFingerprint.count, Date().timeIntervalSince(latestObservedAt) < 1.5 else { return false }
        let difference = zip(prior, latestFingerprint).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(difference) / Double(prior.count * 255) < 0.015
    }
    private func pause(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        paused = true
        store.log("暂停：\(reason)", sessionID: sessionID)
        publish("暂停", reason)
    }
    private func publish(_ phase: String, _ detail: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard store.command?.id == sessionID else { return }
        let current = store.status
        if config.continuedProcessingEnabled == true, current.sessionID == sessionID,
           ["暂停", "停止", "完成"].contains(current.phase) { return } // Main task owns its terminal reason.
        if phase != current.phase || detail != current.detail { store.log("\(phase)：\(detail)", sessionID: sessionID) }
        try? store.write(PilotStatus(phase: phase, detail: detail, steps: steps, sessionID: sessionID), to: "status.json")
    }
    private func endCaptureSession() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Both modes must revoke the command without relying on the main app being foregrounded.
        _ = try? store.updateCommand(sessionID: sessionID) { $0.running = false }
        if let frame = store.read("frame.json", as: SharedFrame.self), frame.sessionID == sessionID { store.remove("frame.json") }
        if let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == sessionID { store.remove("lease.json") }
    }
    private func stopHardware() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Snapshot before leaving the queue. A later start must not redirect this STOP.
        let configuration = config
        Task { await HardwareClient(configuration: configuration).stop() }
    }
    private func stopAndFinish(_ reason: String, phase: String = "停止") {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        stopped = true; work?.cancel(); timer?.cancel(); timer = nil
        endCaptureSession()
        publish(phase, reason)
        stopHardware()
        finishBroadcastWithError(PilotError.message(reason))
    }
}
