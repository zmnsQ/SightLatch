import ReplayKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A pending continued-processing owner may receive frames, never extension-side execution.
enum ContinuedCapturePolicy {
    static func rejection(enabled: Bool, execution: ContinuedExecution?, sessionID: String,
                          stopGeneration: String?, lease: ExecutionLease?, now: Date) -> String? {
        guard enabled else {
            return execution == nil ? nil : "当前任务属于后台执行者，广播扩展不能接管执行；请重新准备会话。"
        }
        guard let execution else { return "后台执行者尚未准备，请回到 SightLatch 重新开始本次会话。" }
        guard execution.stopGeneration == stopGeneration else { return "已收到停止请求，旧后台会话不能继续采集。" }
        switch execution.phase {
        case .awaitingFirstFrame:
            return nil // No system task has been submitted and no lease is expected yet.
        case .starting:
            guard let requestedAt = execution.requestedAt else { return "后台启动请求缺少时间记录，请重新准备会话。" }
            let age = now.timeIntervalSince(requestedAt)
            guard age >= 0, age < ContinuedExecution.startupTimeout else {
                return "系统后台执行者未在十秒内启动，本轮广播已停止。"
            }
            return nil // Capture only while the real system callback is pending.
        case .active:
            guard let lease, lease.sessionID == sessionID, lease.expiresAt > now,
                  lease.expiresAt.timeIntervalSince(now) <= 6 else {
                return "后台协调租约已失效；禁止继续采集或执行。"
            }
            return nil
        }
    }
}

enum BroadcastRecoveryPolicy {
    static func permits(modelRequested: Bool, proposalReceived: Bool, mayHaveDispatched: Bool,
                        reservedMessageAttempt: Bool, frameFailureBeforeDispatch: Bool,
                        taskCancelled: Bool, sessionAuthorized: Bool) -> Bool {
        guard !taskCancelled, sessionAuthorized, !mayHaveDispatched, !reservedMessageAttempt else { return false }
        return frameFailureBeforeDispatch || (modelRequested && !proposalReceived)
    }
}

struct BroadcastFrameObservationFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// One early observation after a real HID completion. Ordinary scheduling is unchanged.
struct PostActionObservationPolicy {
    private(set) var eligibleAfter: Date?
    mutating func completed(at: Date) { eligibleAfter = at.addingTimeInterval(0.35) }
    mutating func reset() { eligibleAfter = nil }
    mutating func beganEncoding() { eligibleAfter = nil }
    func permitsCapture(now: Date, capturedAt: Date, lastCapture: Date, interval: TimeInterval, busy: Bool) -> Bool {
        guard !busy else { return false }
        if let eligibleAfter { return now >= eligibleAfter && capturedAt >= eligibleAfter }
        return now.timeIntervalSince(lastCapture) >= interval
    }
}

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
    private var renewalWork: Task<Void, Never>?
    private var busy = false
    private var stopped = false
    private var startupFailed = false
    private var paused = false
    private var latestFingerprint = [UInt8]()
    private var latestGeometry: CaptureGeometry?
    private var latestObservedAt = Date.distantPast
    private var observationEnqueuedAt = Date.distantPast
    private var lastCaptureStatus = Date.distantPast
    private var captureObservation: CaptureObservation?
    private var lastCapture = Date.distantPast
    private var postActionObservation = PostActionObservationPolicy()
    private var steps = 0
    private var generation = -1
    private var sessionID = ""
    private var expectedStopGeneration: String?
    private var hardwareSession = ""
    private var config = PilotConfiguration()
    private var agent: AgentSession?
    private let captureOwnerID = UUID().uuidString
    private let store = SharedStore.shared

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        queue.async { [weak self] in
            guard let self else { return }
            let startupFence = self.store.stopGeneration
            let startupCommand = self.store.command
            self.config = self.store.configuration
            func reject(_ code: Int, _ reason: String) {
                let expectedFence: String?
                if let execution = startupCommand?.continuedExecution { expectedFence = execution.stopGeneration }
                else if let scope = startupCommand?.messageScope { expectedFence = scope.stopGeneration }
                else { expectedFence = startupFence }
                self.failBroadcastStartup(reason, code: code, command: startupCommand, stopGeneration: expectedFence)
            }
            guard self.store.available else { reject(1001, "广播扩展无法访问共享存储，请检查主App与扩展的App Group和本机签名。"); return }
            guard let command = startupCommand else { reject(1002, "未找到已准备的任务。请回到SightLatch，从当前计划允许本次操作后再开始广播。"); return }
            guard command.running else { reject(1003, "任务会话已经停止，尚未开始屏幕捕获。请回到SightLatch重新明确开始本次任务。"); return }
            guard self.config.uploadConsent else { reject(1004, "本次屏幕上传尚未获准。请回到SightLatch，从当前计划明确允许本次操作。"); return }
            guard self.config.hasVerifiedPointerCalibration else { reject(1005, "广播扩展尚未读到有效指针校准，请回到SightLatch检查当前设备的校准结果。"); return }
            guard !self.config.model.isEmpty else { reject(1006, "广播扩展尚未读到视觉模型配置，请回到SightLatch检查AI账户设置。"); return }
            do { try self.config.validate() }
            catch { reject(1007, "广播配置无效：\(error.localizedDescription)"); return }
            guard command.authorizationIsCurrent(), let execution = command.execution,
                  execution.phase == .awaitingCapture, execution.stopGeneration == startupFence else {
                reject(1008, "准备已过期或此会话已开始过广播，请明确准备一个新会话；不会刷新执行期限。"); return
            }
            if let scope = command.messageScope, scope.stopGeneration != startupFence {
                reject(1009, "本次任务已收到停止请求，旧广播不能重新开始。"); return
            }
            if let reason = self.continuedCaptureFailure(command) { reject(1010, reason); return }
            self.sessionID = command.id
            self.expectedStopGeneration = startupFence
            self.captureObservation = CaptureObservation(sessionID: command.id, state: "waiting", generation: command.generation)
            self.publishCaptureState("waiting")
            self.generation = command.generation
            self.agent = nil // A real capture, not preparation or a picker callback, starts the clock.
            self.lastCapture = .distantPast
            self.postActionObservation.reset()
            self.latestObservedAt = Date()
            self.publish("待广播", "等待首张真实画面，尚未开启设备控制")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.pollControl() }
            self.timer = timer
            timer.resume()
        }
    }

    private func failBroadcastStartup(_ reason: String, code: Int, command: SessionCommand?, stopGeneration: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        startupFailed = true; stopped = true
        postActionObservation.reset()
        work?.cancel(); timer?.cancel(); timer = nil
        if let command {
            sessionID = command.id; generation = command.generation
            captureObservation = CaptureObservation(sessionID: command.id, state: "failed", generation: command.generation,
                failureReason: reason, failureStopGeneration: stopGeneration)
            // Never let a late rejected extension overwrite or stop a newer task.
            if (try? store.recordCaptureStartupFailure(sessionID: command.id, generation: command.generation,
                    expectedStopGeneration: stopGeneration, reason: reason)) == true { stopHardware() }
        }
        finishBroadcastWithError(NSError(domain: "SightLatch.Broadcast", code: code,
            userInfo: [NSLocalizedDescriptionKey: reason]))
    }

    private func pollControl() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        guard var command = store.command else {
            stopAndFinish("未找到当前会话指令，屏幕广播已停止。"); return
        }
        guard command.id == sessionID else {
            stopAndFinish("当前会话已更换，旧屏幕广播已停止。"); return
        }
        guard command.running else {
            let terminal = store.status
            if terminal.sessionID == sessionID, ["暂停", "停止", "完成"].contains(terminal.phase),
               !terminal.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stopAndFinish(terminal.detail, phase: terminal.phase)
            } else {
                stopAndFinish("会话执行授权已撤销（running=false）；未记录主动停止来源，屏幕广播已停止。")
            }
            return
        }
        guard store.configuration.uploadConsent else {
            stopAndFinish("屏幕上传许可已撤回，屏幕广播已停止。"); return
        }
        guard store.stopGeneration == expectedStopGeneration else {
            stopAndFinish("已收到停止请求，屏幕广播已停止。"); return
        }
        var goalReplaced = false
        if config.continuedProcessingEnabled != true, !busy {
            do {
                if let updated = try store.applyPendingGoal(sessionID: sessionID, expectedGeneration: command.generation) {
                    command = updated
                    goalReplaced = true
                }
            } catch { stopAndFinish("无法接收追加命令：\(error.localizedDescription)"); return }
        }
        if let scope = command.messageScope {
            if scope.launch.phase == .failed {
                stopAndFinish(scope.launch.failure ?? "系统未接受微信打开请求，本轮已停止。", phase: "暂停"); return
            }
        }
        if let reason = continuedCaptureFailure(command) { stopAndFinish(reason); return }
        if command.generation != generation {
            generation = command.generation
            postActionObservation.reset()
            work?.cancel()
            // A new generation never replays the prior proposal. The next frame must be newly captured.
            paused = false
            if goalReplaced { agent?.replaceGoal() } else { agent?.manualResume() }
            hardwareSession = ""
            lastCapture = Date()
            publish("观察", "任务指令已更新，等待新画面重新判断")
        }
        if !paused && Date().timeIntervalSince(latestObservedAt) > 45 { stopAndFinish("45秒未收到新广播画面"); return }
        if !command.authorizationIsCurrent() { stopAndFinish("准备或执行期限已结束；不会自动延长或重新ARM。"); return }
        renewHardwareIfNeeded(command)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // iOS 27 no longer supplies this attachment. Absence is unknown, not confirmed portrait.
        let rawOrientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber)?.intValue
        let knownOrientation = rawOrientation.flatMap { (1...8).contains($0) ? $0 : nil }
        let orientation = Int32(knownOrientation ?? 1)
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let sampledAt = Date()
        let receivedUptime = ProcessInfo.processInfo.systemUptime
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
            guard let frameCommand = self.store.command, frameCommand.id == self.sessionID,
                  frameCommand.running, frameCommand.generation == self.generation else { return }
            if let owner = frameCommand.execution?.captureOwnerID, owner != self.captureOwnerID {
                self.stopAndFinish("另一广播实例已领取首次启动；此实例不执行也不停止获胜会话。"); return
            }
            guard self.store.configuration.uploadConsent, self.store.stopGeneration == self.expectedStopGeneration else {
                self.stopAndFinish("屏幕许可或停止状态已变化，广播已停止。"); return
            }
            guard frameCommand.authorizationIsCurrent(now: sampledAt) else { self.stopAndFinish("准备或执行期限已结束；不会自动延长或重新ARM。"); return }
            if let reason = self.continuedCaptureFailure(frameCommand) { self.stopAndFinish(reason); return }
            let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: orientation)
            var observedGeometry = CaptureGeometry(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                orientedWidth: Int(oriented.extent.width), orientedHeight: Int(oriented.extent.height),
                jpegWidth: 0, jpegHeight: 0, exifOrientation: knownOrientation,
                presentationSeconds: presentationTime.isFinite ? presentationTime : nil)
            // The encoder is fixed for this broadcast. Reuse its measured JPEG
            // dimensions only while the incoming capture coordinate space is identical.
            if let prior = self.latestGeometry, observedGeometry.hasSameCaptureSpace(as: prior) {
                observedGeometry.jpegWidth = prior.jpegWidth
                observedGeometry.jpegHeight = prior.jpegHeight
            }
            self.latestGeometry = observedGeometry
            self.latestFingerprint = self.fingerprint(oriented)
            self.latestObservedAt = sampledAt
            self.captureObservation = CaptureObservation(sessionID: self.sessionID, state: "capturing",
                receivedAt: sampledAt, receivedUptime: receivedUptime, sourceWidth: sourceWidth,
                sourceHeight: sourceHeight, exifOrientation: knownOrientation, generation: self.generation)
            if frameCommand.execution?.phase == .awaitingCapture {
                do {
                    let claimed = try self.store.claimCaptureExecution(sessionID: self.sessionID, generation: self.generation,
                        expectedStopGeneration: self.expectedStopGeneration, captureOwnerID: self.captureOwnerID,
                        firstFrame: self.captureObservation!)
                    self.startHardwareAfterFirstCapture(claimed)
                } catch { self.stopAndFinish(error.localizedDescription); return }
            }
            if sampledAt.timeIntervalSince(self.lastCaptureStatus) >= 1 {
                self.publishCaptureState("capturing")
                self.lastCaptureStatus = sampledAt
            }
            // Real frames remain observable while first ARM is pending. No AI,
            // app launch, continued scheduler or input can use this pending phase.
            guard self.store.command?.authorizationIsCurrent(requireActive: true) == true else { return }
            if let current = self.store.command, let scope = current.messageScope {
                // The continued-processing owner may have committed a voice goal
                // since this callback began. Drop the old frame until pollControl syncs it.
                guard current.generation == self.generation else { return }
                guard current.id == self.sessionID, current.running,
                      scope.matches(sessionID: current.id, generation: current.generation, task: current.task),
                      self.store.stopGeneration == scope.stopGeneration else {
                    self.stopAndFinish("消息会话或停止状态已变化；不会继续。"); return
                }
                // Observe the first authorized frame, including an app-opening dialog.
                // SafetyGate separately limits launch actions until WeChat is visible.
            }
            let interval = self.config.continuedProcessingEnabled == true ? 1 : max(2, self.config.frameInterval)
            guard self.postActionObservation.permitsCapture(now: Date(), capturedAt: sampledAt,
                lastCapture: self.lastCapture, interval: interval, busy: self.busy) else { return }
            self.busy = true
            self.lastCapture = Date()
            let decisionFingerprint = self.latestFingerprint
            let capturedAt = sampledAt
            let frameID = UUID().uuidString
            let capturedGeneration = self.generation
            let capturedStopGeneration = self.expectedStopGeneration
            guard let command = self.store.command, command.id == self.sessionID, command.running else { self.busy = false; return }
            guard self.steps < min(50, max(1, self.config.maxSteps)) else { self.stopAndFinish("达到最大步数"); return }
            self.postActionObservation.beganEncoding()
            let jpeg: Data? = autoreleasepool {
                var source = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: orientation)
                let scale = min(1, 1280 / max(source.extent.width, source.extent.height))
                source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let color = CGColorSpaceCreateDeviceRGB()
                return self.context.jpegRepresentation(of: source, colorSpace: color, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.75])
            }
            guard let jpeg, jpeg.count < 600_000 else { self.pause("截图编码失败或超过内存预算"); self.busy = false; return }
            guard let imageSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let jpegWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let jpegHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
                self.pause("无法确认截图尺寸"); self.busy = false; return
            }
            let geometry = CaptureGeometry(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                orientedWidth: Int(oriented.extent.width), orientedHeight: Int(oriented.extent.height),
                jpegWidth: jpegWidth, jpegHeight: jpegHeight, exifOrientation: knownOrientation,
                presentationSeconds: presentationTime.isFinite ? presentationTime : nil)
            self.latestGeometry = geometry
            let configuration = self.config
            if configuration.continuedProcessingEnabled == true {
                do {
                    // Encoding may overlap a STOP or an instruction-generation change.
                    guard let current = self.store.command, current.id == self.sessionID, current.running,
                          current.generation == capturedGeneration,
                          self.store.configuration.uploadConsent,
                          self.store.stopGeneration == self.expectedStopGeneration else { self.busy = false; return }
                    if let reason = self.continuedCaptureFailure(current) {
                        self.stopAndFinish(reason); self.busy = false; return
                    }
                    let frame = SharedFrame(sessionID: self.sessionID, id: frameID, capturedAt: capturedAt, jpeg: jpeg, fingerprint: Data(decisionFingerprint), geometry: geometry, capturedUptime: receivedUptime)
                    try self.store.write(frame, to: "frame.json")
                } catch { self.stopAndFinish("无法安全暂存最新广播帧") }
                self.busy = false
                return
            }
            guard self.agent?.accepts(frameID: frameID, capturedAt: capturedAt) == true else { self.busy = false; return }
            do { try self.agent?.observe(frameID: frameID, capturedAt: capturedAt, fingerprint: Data(decisionFingerprint)) }
            catch { self.pause(error.localizedDescription); self.busy = false; self.stopHardware(); return }
            let agentContext = self.agent?.modelContext ?? ""
            self.publish("规划", "正在根据新画面和上一轮执行结果选择下一步")
            self.work = Task { [weak self] in
                guard let self else { return }
                defer { self.queue.async { self.busy = false; self.work = nil } }
                var requestedModel = false
                var receivedProposal = false
                var dispatched = false
                var reservedMessageAttempt = false
                var preDispatchFrameFailure: String?
                let deadline = capturedAt.addingTimeInterval(min(20, max(3, configuration.maxFrameAge)))
                let isSessionAuthorized = { () -> Bool in
                    guard let current = self.store.command, current.id == command.id, current.running,
                          current.generation == capturedGeneration, current.task == command.task,
                          current.messageScope?.id == command.messageScope?.id,
                          current.continuedExecution == nil, self.store.configuration.uploadConsent,
                          self.store.stopGeneration == capturedStopGeneration else { return false }
                    guard current.authorizationIsCurrent(requireActive: true),
                          current.execution?.captureOwnerID == self.captureOwnerID else { return false }
                    if let scope = current.messageScope {
                        guard scope.id == command.messageScope?.id, scope.stopGeneration == capturedStopGeneration,
                              scope.matches(sessionID: current.id, generation: current.generation, task: current.task),
                              scope.launch.phase != .failed else { return false }
                    }
                    return true
                }
                do {
                    let hardware = HardwareClient(configuration: configuration)
                    let device = try await hardware.status()
                    guard device.armed, device.hid_connected,
                          device.session_id == self.store.command?.execution?.hardwareSessionID else { throw PilotError.message("首帧授权的硬件会话已失效；不会自动重新ARM。") }
                    let absoluteContext = try device.absolutePointerContext(configuration: configuration, geometry: geometry, frameID: frameID)
                    let modelContext = agentContext + "\n" + (absoluteContext?.modelContext ?? geometry.modelContext(calibration: configuration))
                    try Task.checkCancellation()
                    guard isSessionAuthorized() else { throw CancellationError() }
                    if let reason = self.queue.sync(execute: { self.frameObservationFailure(comparedTo: decisionFingerprint, deadline: deadline) }) {
                        throw BroadcastFrameObservationFailure(reason: "上传前：" + reason)
                    }
                    guard let beforeUpload = self.store.command, beforeUpload.id == command.id,
                          beforeUpload.generation == capturedGeneration, beforeUpload.running,
                          self.store.configuration.uploadConsent else { return }
                    requestedModel = true
                    let proposal = try await AIClient(configuration: configuration).propose(jpeg: jpeg, task: command.task, frameID: frameID, context: modelContext, messageScope: beforeUpload.messageScope, absoluteContext: absoluteContext)
                    receivedProposal = true
                    try Task.checkCancellation()
                    guard isSessionAuthorized() else { throw CancellationError() }
                    guard let latest = self.store.command, latest.running, latest.id == command.id,
                          latest.generation == capturedGeneration else { return }
                    if beforeUpload.messageScope?.launch.phase != latest.messageScope?.launch.phase ||
                       beforeUpload.messageScope?.launch.visuallyEstablishedFrameID != latest.messageScope?.launch.visuallyEstablishedFrameID {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.agent?.record(action: "observe", outcome: "App launch advanced during inference; discard this proposal and observe a newer frame.", countsAsUIAttempt: false)
                            self.publish("观察", "微信启动状态已更新，正在读取新画面")
                        }
                        return
                    }
                    let pointerGeometry = [.move, .click].contains(proposal.type) ? geometry : nil
                    if let pointerGeometry {
                        do {
                            if let absoluteContext {
                                _ = try pointerGeometry.validateCalibrationGeometry(context: absoluteContext.calibrationContext, orientation: configuration.orientation).get()
                            } else { _ = try pointerGeometry.pointerMapping(calibration: configuration).get() }
                        }
                        catch {
                            self.store.log("指针坐标校验失败 \(geometry.diagnosticDimensions)：\(error.localizedDescription)", sessionID: command.id)
                            throw error
                        }
                    }
                    if let reason = self.queue.sync(execute: { self.frameObservationFailure(comparedTo: decisionFingerprint, deadline: deadline, geometry: pointerGeometry) }) {
                        throw BroadcastFrameObservationFailure(reason: "模型返回后：" + reason)
                    }
                    if let reason = SafetyGate.rejection(proposal, task: command.task, config: configuration, command: latest, frameID: frameID, capturedAt: capturedAt, capturedUptime: receivedUptime, absoluteContext: absoluteContext) {
                        self.store.log("AI提案诊断 \(proposal.rejectionDiagnostic(frameAge: Date().timeIntervalSince(capturedAt))) \(geometry.diagnosticDimensions)", sessionID: command.id)
                        if SafetyGate.canReobserveLowConfidenceNavigationMove(proposal, config: configuration,
                            command: latest, frameID: frameID, capturedAt: capturedAt, capturedUptime: receivedUptime, absoluteContext: absoluteContext),
                           self.queue.sync(execute: {
                               guard !self.stopped, !self.paused, self.generation == capturedGeneration,
                                     isSessionAuthorized() else { return false }
                               return self.agent?.recoverBeforeDispatch("The navigation move was not executed. Inspect a NEW frame and independently choose the next step; do not assume the discarded move happened.") == true
                           }) {
                            self.queue.async {
                                guard !self.stopped, !self.paused, self.generation == capturedGeneration,
                                      isSessionAuthorized() else { return }
                                self.publish("观察", "本轮未移动，正在读取新画面重新判断（最多两次）")
                            }
                            return
                        }
                        if latest.messageScope?.launch.isVisuallyEstablished == false,
                           reason == "微信尚未打开或仍是启动前画面；不会规划控制",
                           self.queue.sync(execute: { self.agent?.recoverBeforeDispatch("Launch gate rejected an ordinary action. No HID sent. Read the current launch state: only app_launch_confirmation for the exact WeChat Open dialog, app_launch_verify for visible WeChat, or an empty low-risk wait during transition is allowed.") == true }) {
                            self.queue.async {
                                guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                                self.publish("观察", "尚未进入微信，已丢弃这一步并根据新画面修正")
                            }
                            return
                        }
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.pause("本轮未执行动作。\(reason)", userMessage: proposal.type == .ask_user || proposal.confidence < 0.85 ? String(proposal.userFacingReason.prefix(80)) : nil)
                            self.stopHardware()
                        }
                        return // pause owns the session-scoped STOP.
                    }
                    let messageContext = latest.messageScope.map { MessageDispatchContext(sessionID: latest.id,
                        generation: latest.generation, frameID: frameID, scopeID: $0.id) }
                    if proposal.purpose == "app_launch_verify" {
                        guard let messageContext else { throw PilotError.message("缺少微信启动范围") }
                        try self.store.confirmMessageAppVisible(context: messageContext,
                            expectedStopGeneration: latest.messageScope?.stopGeneration,
                            capturedAt: capturedAt, capturedUptime: receivedUptime)
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.agent?.record(action: "app_launch_verify", outcome: "WeChat is visually established. Observe a newer frame before ordinary navigation; no HID sent.", countsAsUIAttempt: false)
                            self.steps += 1
                            self.publish("观察", "已从画面确认微信，继续读取新画面")
                        }
                        return
                    }
                    if proposal.type == .done {
                        if let messageContext { try self.store.verifyMessage(context: messageContext, capturedAt: capturedAt) }
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration else { return }
                            self.stopAndFinish(messageContext == nil ? "AI 认为任务完成；请人工确认实际结果" : "新画面已显示本次消息；仅发送一次，未取得服务器送达回执", phase: "完成")
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
                    guard isSessionAuthorized() else { throw CancellationError() }
                    guard let current = self.store.command, current.running, current.id == command.id, current.generation == capturedGeneration else { return }
                    dispatched = true // Conservatively means POST may have started until a typed/pre-POST rejection proves otherwise.
                    try await hardware.send(proposal, expectedSession: device.session_id, frameDeadline: deadline, absoluteContext: absoluteContext, stillAuthorized: {
                        guard isSessionAuthorized() else { return false }
                        if let absoluteContext, !absoluteContext.matches(configuration: self.store.configuration) { return false }
                        guard let current = self.store.command, current.running, current.id == command.id, current.generation == capturedGeneration,
                              self.store.configuration.uploadConsent else { return false }
                        if let scope = current.messageScope {
                            guard self.store.stopGeneration == scope.stopGeneration,
                                  scope.id == messageContext?.scopeID,
                                  scope.matches(sessionID: current.id, generation: current.generation, task: current.task) else { return false }
                            // reserveMessageAction consumes the one-shot before POST.
                            // Recheck its scope/freshness, not its already-consumed flag.
                            if ["message_paste", "message_send"].contains(proposal.purpose) {
                                guard scope.launch.permitsFrame(capturedAt: capturedAt, capturedUptime: receivedUptime),
                                      proposal.purpose != "message_paste" || scope.clipboardIsReady else { return false }
                            } else if SafetyGate.rejection(proposal, task: current.task, config: configuration, command: current,
                                frameID: frameID, capturedAt: capturedAt, capturedUptime: receivedUptime, absoluteContext: absoluteContext) != nil { return false }
                        }
                        return self.queue.sync {
                            guard !self.stopped, !self.paused else { return false }
                            if let reason = self.frameObservationFailure(comparedTo: decisionFingerprint, deadline: deadline, geometry: pointerGeometry) {
                                // This final pre-POST predicate also preserves
                                // its reason; no later silent stability check.
                                preDispatchFrameFailure = reason
                                return false
                            }
                            return true
                        }
                    }, sessionAuthorized: {
                        isSessionAuthorized()
                    }, reserveMessageAction: {
                        if ["message_paste", "message_send"].contains(proposal.purpose) {
                            guard let messageContext else { throw PilotError.message("缺少消息范围") }
                            try self.store.reserveMessageAction(purpose: proposal.purpose, context: messageContext)
                            reservedMessageAttempt = true
                        }
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
                        self.postActionObservation.completed(at: completedAt)
                    }
                } catch {
                    // Only these errors prove HardwareClient stopped before submitting a POST.
                    let hardwarePreDispatchFailure = error is HardwareClient.PreDispatchFailure
                    let frameGuardRejected = error is CancellationError && preDispatchFrameFailure != nil
                    if hardwarePreDispatchFailure || frameGuardRejected { dispatched = false }
                    let frameFailure = error is BroadcastFrameObservationFailure || hardwarePreDispatchFailure || frameGuardRejected
                    if frameFailure {
                        let rejection: String
                        if hardwarePreDispatchFailure {
                            let diagnostic = self.queue.sync { self.frameObservationDiagnostic(comparedTo: decisionFingerprint, deadline: deadline) }
                            rejection = error.localizedDescription + " " + diagnostic + " " + geometry.diagnosticDimensions
                        } else {
                            rejection = preDispatchFrameFailure ?? error.localizedDescription
                        }
                        // Also retain the first two discarded rounds, before
                        // recovery replaces their user-facing status text.
                        self.store.log("屏幕帧校验拒绝：" + rejection, sessionID: command.id)
                    }
                    let authorized = isSessionAuthorized()
                    let eligible = BroadcastRecoveryPolicy.permits(modelRequested: requestedModel, proposalReceived: receivedProposal,
                        mayHaveDispatched: dispatched, reservedMessageAttempt: reservedMessageAttempt,
                        frameFailureBeforeDispatch: frameFailure, taskCancelled: Task.isCancelled, sessionAuthorized: authorized)
                    let reason = frameFailure ? "Stale or changed frame discarded before POST; no HID sent. Observe a new frame." : "Model request failed; no HID sent."
                    let canRecover = eligible && self.queue.sync { () -> Bool in
                        guard !self.stopped, !self.paused, self.generation == capturedGeneration,
                              isSessionAuthorized() else { return false }
                        return self.agent?.recoverBeforeDispatch(reason) == true
                    }
                    if canRecover {
                        self.queue.async {
                            guard !self.stopped, !self.paused, self.generation == capturedGeneration,
                                  isSessionAuthorized() else { return }
                            self.publish("观察", "本轮未执行，等待新画面重新规划（最多重试两次）"); self.lastCapture = Date()
                        }
                    } else {
                        // A STOP/generation/permission cancellation keeps its existing terminal reason.
                        if !Task.isCancelled, authorized {
                            let stopReason: String
                            if reservedMessageAttempt { stopReason = "消息尝试已消耗，不会自动重发。" + error.localizedDescription }
                            else if frameFailure { stopReason = (preDispatchFrameFailure ?? error.localizedDescription) + "；已用完两次重新观察，未提交动作。" }
                            else { stopReason = error.localizedDescription }
                            self.queue.async {
                                guard !self.stopped, !self.paused, self.generation == capturedGeneration,
                                      isSessionAuthorized() else { return }
                                self.pause(stopReason)
                            }
                        }
                        // Independent of the cancelled task, so releases are still attempted.
                        let cleanup = Task.detached {
                            await HardwareClient(configuration: configuration).stopRuntimeAndReport(sessionID: self.sessionID, captureOwnerID: self.captureOwnerID)
                        }
                        await cleanup.value
                    }
                }
            }
        }
    }

    override func broadcastPaused() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.publishCaptureState("paused")
            self.work?.cancel()
            if self.config.continuedProcessingEnabled == true {
                let previous = self.store.status
                if previous.sessionID == self.sessionID, ["暂停", "停止", "完成"].contains(previous.phase) {
                    self.stopAndFinish(previous.detail, phase: previous.phase)
                } else { self.stopAndFinish("系统广播暂停，后台会话结束") }
                return
            }
            if !self.paused { self.pause("系统广播暂停；请回主 App 重新确认并物理 ARM") }
            self.stopHardware()
        }
    }
    override func broadcastResumed() {
        // Do not resume side effects automatically after lock, system interruptions or permission changes.
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.work?.cancel()
            self.publishCaptureState("paused")
            let previous = self.store.status
            if !self.paused {
                if self.config.continuedProcessingEnabled == true, previous.sessionID == self.sessionID,
                   ["暂停", "停止", "完成"].contains(previous.phase) {
                    self.paused = true; self.postActionObservation.reset()
                } else { self.pause("广播已恢复；仍保持安全暂停，请回主 App 确认") }
            }
            self.stopHardware()
        }
    }
    override func broadcastFinished() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.startupFailed else { return } // Preserve the specific startup rejection.
            self.stopped = true; self.work?.cancel(); self.timer?.cancel(); self.timer = nil
            self.postActionObservation.reset()
            self.endCaptureSession()
            let terminal = self.store.status
            if terminal.sessionID != self.sessionID || !["完成", "停止", "暂停"].contains(terminal.phase) {
                self.publish("停止", "系统广播已结束")
            }
            self.stopHardware()
        }
    }
    /// Capture owns lease liveness in both default and continued execution modes.
    /// No fresh frame means no renewal; an expired or uncertain lease never re-arms.
    private func renewHardwareIfNeeded(_ command: SessionCommand) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, !paused, renewalWork == nil,
              let execution = command.execution, execution.phase == .active,
              execution.renewableHardwareLease == true, execution.captureOwnerID == captureOwnerID,
              let hardwareEnd = execution.hardwareLeaseExpiresAt,
              hardwareEnd.timeIntervalSinceNow < 15,
              Date().timeIntervalSince(latestObservedAt) >= 0,
              Date().timeIntervalSince(latestObservedAt) < 1.5 else { return }
        let configuration = config, owner = captureOwnerID, fence = expectedStopGeneration
        renewalWork = Task { [weak self] in
            guard let self else { return }
            defer { self.queue.async { self.renewalWork = nil } }
            let authorized = { () -> Bool in
                guard !Task.isCancelled, let current = self.store.command,
                      current.id == command.id, current.authorizationIsCurrent(requireActive: true),
                      current.execution?.captureOwnerID == owner,
                      self.store.stopGeneration == fence, self.store.configuration.uploadConsent,
                      self.store.configuration.deviceURL == configuration.deviceURL else { return false }
                return self.queue.sync { !self.stopped && !self.paused && Date().timeIntervalSince(self.latestObservedAt) < 1.5 }
            }
            var channel: HardwareChannelLease?
            do {
                guard authorized() else { throw CancellationError() }
                guard let acquired = try self.store.acquireCaptureHardwareChannel(sessionID: command.id, captureOwnerID: owner) else { return }
                channel = acquired
                let current = try self.store.reserveHardwareRenewal(sessionID: command.id, captureOwnerID: owner, expectedStopGeneration: fence)
                guard let snapshot = current.execution, let sequence = snapshot.nextRenewalSequence else { throw CancellationError() }
                let requestStarted = Date()
                let leaseMS = min(30000, Int((current.authorizationExpiresAt?.timeIntervalSince(requestStarted) ?? 30) * 1000))
                let reply = try await HardwareClient(configuration: configuration).renewExecution(snapshot, sequence: sequence,
                    leaseMilliseconds: leaseMS, stillAuthorized: authorized)
                try self.store.confirmHardwareRenewal(sessionID: command.id, captureOwnerID: owner, expectedStopGeneration: fence,
                    sequence: sequence, remainingMS: reply.lease_remaining_ms ?? 0, requestStartedAt: requestStarted)
                try self.store.finishCaptureHardwareChannel(acquired, confirmed: true)
            } catch {
                if let channel {
                    await Task.detached {
                        do {
                            try await HardwareClient(configuration: configuration).stopAndVerify(heldChannel: channel)
                            try self.store.finishCaptureHardwareChannel(channel, confirmed: true)
                        } catch { try? self.store.finishCaptureHardwareChannel(channel, confirmed: false)
                            self.store.recordRuntimeStopFailure(sessionID: command.id, captureOwnerID: owner) }
                    }.value
                }
                self.queue.async {
                    guard !self.stopped, self.store.command?.id == command.id else { return }
                    self.stopAndFinish("设备续租未确认，已停止本次运行；不会自动重新ARM。")
                }
            }
            withExtendedLifetime(channel) {}
        }
    }

    // Conservative coarse change detector, not a proof of UI/target identity.
    private func startHardwareAfterFirstCapture(_ command: SessionCommand) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, !busy, let execution = command.execution,
              execution.phase == .startingHardware, execution.captureOwnerID == captureOwnerID,
              let deadline = execution.startupExpiresAt else { return }
        busy = true
        let configuration = config, owner = captureOwnerID, fence = expectedStopGeneration
        publish("启动", "已收到真实画面，正在开启本次固定期限的设备控制")
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.queue.async { self.busy = false; self.work = nil } }
            let authorized = { () -> Bool in
                guard !Task.isCancelled, let current = self.store.command,
                      current.id == command.id, current.generation == command.generation,
                      current.authorizationIsCurrent(), current.execution?.phase == .startingHardware,
                      current.execution?.captureOwnerID == owner,
                      self.store.stopGeneration == fence, self.store.configuration.uploadConsent,
                      self.store.configuration.deviceURL == configuration.deviceURL else { return false }
                return true
            }
            var channel: HardwareChannelLease?
            do {
                guard let acquired = try self.store.acquireCaptureHardwareChannel(sessionID: command.id, captureOwnerID: owner) else {
                    throw PilotError.message("设备授权或停止尚未排空，首次启动未提交。")
                }
                channel = acquired
                let device = try await HardwareClient(configuration: configuration).beginPreparedExecution(execution.hardware,
                    deadline: deadline, renewable: execution.renewableHardwareLease == true, stillAuthorized: authorized)
                guard authorized() else { throw CancellationError() }
                let activated = try self.store.activateCaptureExecution(sessionID: command.id, generation: command.generation,
                    expectedStopGeneration: fence, captureOwnerID: owner, hardwareBootID: device.boot_id,
                    controlEpoch: device.control_epoch, hidGeneration: device.hid_generation, hardwareSessionID: device.session_id,
                    hardwareLeaseRemainingMS: device.lease_remaining_ms)
                try self.store.finishCaptureHardwareChannel(acquired, confirmed: true)
                self.queue.async {
                    guard !self.stopped, self.store.command?.id == command.id else { return }
                    self.hardwareSession = device.session_id
                    guard let startedAt = activated.executionStartedAt else { self.stopAndFinish("首帧执行时钟无效"); return }
                    self.agent = AgentSession(id: activated.id, startedAt: startedAt, maxRounds: self.config.maxSteps, durationSeconds: activated.isUnlimited ? nil : activated.execution?.boundedDuration ?? 300)
                    self.lastCapture = .distantPast
                    self.publish("观察", activated.isUnlimited ? "设备控制已开启，正在读取新画面；可随时停止本次运行" : "设备控制已开启，正在读取新画面；按本次所选时长执行")
                }
            } catch {
                if let channel {
                    let cleanup = Task.detached {
                        do {
                            try await HardwareClient(configuration: configuration).stopAndVerify(heldChannel: channel)
                            try self.store.finishCaptureHardwareChannel(channel, confirmed: true)
                        } catch {
                            try? self.store.finishCaptureHardwareChannel(channel, confirmed: false)
                            self.store.recordRuntimeStopFailure(sessionID: command.id, captureOwnerID: owner)
                        }
                    }
                    await cleanup.value
                }
                self.queue.async {
                    guard !self.stopped, let current = self.store.command, current.id == command.id,
                          current.execution?.captureOwnerID == owner else { return }
                    self.stopAndFinish("首帧控制未能开启：\(error.localizedDescription)。请明确准备新会话；不会自动重试ARM。")
                }
            }
            withExtendedLifetime(channel) {}
        }
    }

    private func continuedCaptureFailure(_ command: SessionCommand) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        let lease = command.continuedExecution?.phase == .active ? store.read("lease.json", as: ExecutionLease.self) : nil
        return ContinuedCapturePolicy.rejection(enabled: config.continuedProcessingEnabled == true,
            execution: command.continuedExecution, sessionID: command.id, stopGeneration: store.stopGeneration,
            lease: lease, now: Date())
    }

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
    private func frameIsStable(comparedTo prior: [UInt8], now: Date, failure: inout String?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !prior.isEmpty, prior.count == latestFingerprint.count else {
            failure = "画面校验数据暂不可用，旧动作已丢弃。"
            return false
        }
        guard now.timeIntervalSince(latestObservedAt) < 1.5 else {
            failure = "最近没有收到新广播帧，旧动作已丢弃。"
            return false
        }
        let difference = zip(prior, latestFingerprint).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        guard Double(difference) / Double(prior.count * 255) < 0.015 else {
            failure = "规划期间画面已变化，旧动作已丢弃。"
            return false
        }
        return true
    }
    private func frameObservationDiagnostic(comparedTo prior: [UInt8], deadline: Date, now: Date = Date()) -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        func number(_ value: Double) -> String {
            value.isFinite ? String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) : "invalid"
        }
        let difference: String
        if !prior.isEmpty, prior.count == latestFingerprint.count {
            let total = zip(prior, latestFingerprint).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            difference = number(Double(total) / Double(prior.count * 255))
        } else { difference = "unavailable" }
        return "lastObservationAgeSec=\(number(now.timeIntervalSince(latestObservedAt))) remainingDeadlineSec=\(number(deadline.timeIntervalSince(now))) normalizedDifference=\(difference) decisionFingerprintBytes=\(prior.count) latestFingerprintBytes=\(latestFingerprint.count)"
    }
    private func frameObservationFailure(comparedTo prior: [UInt8], deadline: Date, geometry: CaptureGeometry? = nil) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = Date()
        let diagnostic = frameObservationDiagnostic(comparedTo: prior, deadline: deadline, now: now)
            + " " + (latestGeometry?.diagnosticDimensions ?? "geometry=unavailable")
        func reject(_ reason: String, decisionDimensions: String? = nil) -> String {
            store.log("帧校验诊断：" + reason + " " + diagnostic
                + (decisionDimensions.map { " decision{" + $0 + "}" } ?? ""), sessionID: sessionID)
            return reason
        }
        guard now < deadline else { return reject("截图已过期，旧动作已丢弃。") }
        if let geometry {
            guard let latestGeometry, geometry.hasSameCoordinateSpace(as: latestGeometry) else {
                return reject("屏幕方向或截图尺寸在规划期间改变，旧指针动作已丢弃。", decisionDimensions: geometry.diagnosticDimensions)
            }
        }
        var failure: String?
        guard frameIsStable(comparedTo: prior, now: now, failure: &failure) else {
            return reject(failure ?? "画面校验未通过，旧动作已丢弃。")
        }
        return nil
    }
    private func pause(_ reason: String, userMessage: String? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        paused = true
        postActionObservation.reset()
        publishCaptureState("paused")
        store.log("暂停：\(reason)", sessionID: sessionID)
        publish("暂停", reason, userMessage: userMessage)
    }
    private func publish(_ phase: String, _ detail: String, userMessage: String? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard ownsCaptureCommand() else { return }
        let current = store.status
        if current.sessionID == sessionID, current.phase == "请核实硬件停止" { return }
        if config.continuedProcessingEnabled == true, current.sessionID == sessionID,
           ["暂停", "停止", "完成"].contains(current.phase) { return } // Main task owns its terminal reason.
        if phase != current.phase || detail != current.detail { store.log("\(phase)：\(detail)", sessionID: sessionID) }
        try? store.write(PilotStatus(phase: phase, detail: detail, steps: steps, sessionID: sessionID, userMessage: userMessage), to: "status.json")
    }
    private func endCaptureSession() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard ownsCaptureCommand() else { return }
        publishCaptureState("stopped")
        // Both modes must revoke the command without relying on the main app being foregrounded.
        _ = try? store.updateCommand(sessionID: sessionID) {
            guard $0.execution?.captureOwnerID == self.captureOwnerID ||
                ($0.execution?.phase == .awaitingCapture && $0.execution?.captureOwnerID == nil) else { return }
            $0.running = false
        }
        if let frame = store.read("frame.json", as: SharedFrame.self), frame.sessionID == sessionID { store.remove("frame.json") }
        if let lease = store.read("lease.json", as: ExecutionLease.self), lease.sessionID == sessionID { store.remove("lease.json") }
    }
    private func publishCaptureState(_ state: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard ownsCaptureCommand(), var observation = captureObservation else { return }
        observation.state = state
        captureObservation = observation
        try? store.write(observation, to: "capture-status.json")
    }
    private func stopHardware() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Snapshot before leaving the queue. A later start must not redirect this STOP.
        let configuration = config, session = sessionID, owner = captureOwnerID
        Task.detached {
            await HardwareClient(configuration: configuration).stopRuntimeAndReport(sessionID: session, captureOwnerID: owner)
        }
    }
    private func ownsCaptureCommand() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let command = store.command, command.id == sessionID else { return false }
        return command.execution?.captureOwnerID == captureOwnerID ||
            (command.execution?.phase == .awaitingCapture && command.execution?.captureOwnerID == nil)
    }
    private func stopAndFinish(_ reason: String, phase: String = "停止") {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        stopped = true; work?.cancel(); timer?.cancel(); timer = nil
        postActionObservation.reset()
        if ownsCaptureCommand() {
            endCaptureSession()
            publish(phase, reason)
            stopHardware()
        }
        finishBroadcastWithError(NSError(domain: "SightLatch.Broadcast", code: phase == "完成" ? 2000 : 2001,
            userInfo: [NSLocalizedDescriptionKey: reason]))
    }
}
