import Foundation
import UIKit

extension PilotViewModel {
    func updateCalibrationCanvas(width: Double, height: Double, context: PointerCalibrationContext,
                                 surface: AbsoluteCalibrationSurface? = nil) {
        let changed = calibrationCanvasContext != context || calibrationCanvasWidth != width || calibrationCanvasHeight != height
        calibrationCanvasWidth = width; calibrationCanvasHeight = height; calibrationCanvasContext = context
        let surfaceChanged = automaticCalibration.surface != surface
        automaticCalibration.surface = surface
        if changed {
            calibrationObservation = nil
            invalidateActiveCalibrationContext("设备方向、屏幕或画布尺寸已变化，本轮校准已取消，未保存新的结果。")
        }
        if surfaceChanged, automaticCalibration.absoluteMode, calibrationFlow.isBusy {
            invalidateActiveCalibrationContext("全屏校准画布的位置或呈现状态已变化，本轮未保存。")
        }
        if let profile = configuration.automaticCalibrationProfile, profile.context != context {
            configuration.invalidatePointerCalibration()
        }
    }
    /// Returns true when the calibration owns this cleanup; a waiting text plan
    /// must not be cancelled through the main task's global STOP path.
    @discardableResult
    func invalidateActiveCalibrationContext(_ reason: String) -> Bool {
        guard automaticCalibration.isBusy || calibrationFlow.isBusy || calibrationRequestInFlight else { return false }
        guard !calibrationFlow.contextInvalidated else { return true }
        let flowID = calibrationFlow.id, cancellationID = UUID()
        calibrationFlow.contextInvalidated = true
        calibrationFlow.observationFailure = reason // Immediately fences in-flight ARM/move/probe checks.
        calibrationObservation = nil
        automaticCalibration.id = cancellationID
        automaticCalibration.isAwaitingMarker = false
        automaticCalibration.isAwaitingProbe = false
        automaticCalibration.probeWindow = nil
        automaticCalibration.correlationVerified = false
        automaticCalibration.phase = .detecting // Block a new round until verified cleanup finishes.
        automaticCalibration.detail = reason + " 正在确认设备停止。"
        Task { [weak self] in
            guard let self, self.calibrationFlow.id == flowID else { return }
            await self.endPointerCalibration()
            guard self.calibrationFlow.id == flowID, self.automaticCalibration.id == cancellationID else { return }
            self.automaticCalibration.phase = .error
            self.automaticCalibration.detail = reason + (self.calibrationFlow.stopConfirmed
                ? " 设备已确认停止；原任务计划仍保留。"
                : " 未确认设备停止，请按物理STOP或拔掉USB电源。")
        }
        return true
    }
    func observeCalibrationPointer(x: Double, y: Double) {
        // Hover remains available for diagnostics, but cannot replace a probe's
        // actual down/up coordinates while automatic measurement is running.
        guard !automaticCalibration.usesClickProbes, !automaticCalibration.usesManualMarkers else { return }
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= calibrationCanvasWidth, y <= calibrationCanvasHeight else { return }
        calibrationObservation = CalibrationObservation(point: .init(x: x, y: y),
            sequence: (calibrationObservation?.sequence ?? 0) + 1, date: Date())
    }
    // Kept only for older callers; finger marks are never calibration evidence.
    func markObservedPointer(x: Double, y: Double) {}
    @discardableResult
    func observeCalibrationProbeTouch(x: Double, y: Double, source: CalibrationProbeTouchSource,
                                      phase: CalibrationProbeTouchPhase, timestamp: TimeInterval, primaryButton: Bool) -> Bool {
        guard automaticCalibration.usesClickProbes, automaticCalibration.isBusy, calibrationActive,
              calibrationFlow.purpose == .measurement else { return false }
        guard automaticCalibration.isAwaitingProbe, automaticCalibration.probeWindow != nil else {
            failCalibrationObservation("收到接收窗口之外的触摸（type=\(source), phase=\(phase)），已停止本轮；请勿触碰屏幕。")
            return false
        }
        let sourceName: String
        switch source {
        case .direct:
            sourceName = "direct"
            if phase == .began { automaticCalibration.directProbeTouches += 1 }
        case .other:
            sourceName = "other"
            if phase == .began { automaticCalibration.otherProbeTouches += 1 }
        case .indirectPointer: sourceName = "indirectPointer"
        }
        automaticCalibration.lastProbeTouchDiagnostic = "type=\(sourceName), primary=\(primaryButton), phase=\(phase)"
        guard x.isFinite, y.isFinite, safeCalibrationPoint(.init(x: x, y: y)) else {
            failCalibrationObservation("点击落点不在安全画布内部，已停止本轮。")
            return false
        }
        automaticCalibration.probeWindow?.observe(point: .init(x: x, y: y), source: source,
            phase: phase, timestamp: timestamp, primaryButton: primaryButton)
        automaticCalibration.lastProbeTouchDiagnostic += ", events=\(automaticCalibration.probeWindow?.eventCount ?? 0)"
        if let failure = automaticCalibration.probeWindow?.failure { failCalibrationObservation(failure); return false }
        return phase == .ended && automaticCalibration.probeWindow?.point != nil
    }
    private func failCalibrationObservation(_ reason: String) {
        guard calibrationFlow.observationFailure == nil else { return }
        let stage = automaticCalibration.absoluteMode ? "绝对坐标测量\(automaticCalibration.probeCount + 1)/\(AbsoluteCalibrationPlan.targets.count)" : "设备点击关联"
        let diagnostic = "\(stage)：\(reason)（\(automaticCalibration.lastProbeTouchDiagnostic)）"
        calibrationFlow.observationFailure = diagnostic
        automaticCalibration.detail = diagnostic + " 正在确认停止，未保存校准。"
        let id = automaticCalibration.id, flowID = calibrationFlow.id
        Task {
            guard self.calibrationFlow.id == flowID else { return }
            await self.endPointerCalibration()
            guard self.calibrationFlow.id == flowID, self.automaticCalibration.id == id else { return }
            self.automaticCalibration.phase = .error
            self.automaticCalibration.detail = diagnostic + (self.calibrationFlow.stopConfirmed ? " 设备已确认停止。" : " 未确认停止，请拔掉USB电源。")
        }
    }
    func calibrationCanvasDetached(surfaceID: UUID? = nil) {
        if let surfaceID, automaticCalibration.surface?.id != surfaceID { return }
        calibrationCanvasContext = nil; calibrationObservation = nil
        invalidateActiveCalibrationContext("校准画布已离开，未保存新的结果。")
    }
    func recordCalibrationCancellation(source: CalibrationCancellationSource, scene: CalibrationCancellationScene) {
        SharedStore.shared.log("校准取消 source=\(source.rawValue) phase=\(automaticCalibration.phase) probeInFlight=\(automaticCalibration.isAwaitingProbe) scene=\(scene.rawValue)")
        let firstFailure = calibrationFlow.observationFailure ?? calibrationFlow.errorMessage
        if let firstFailure, !firstFailure.isEmpty,
           automaticCalibration.phase != .error, automaticCalibration.phase != .unavailable {
            automaticCalibration.detail = firstFailure
        }
        automaticCalibration.cancel(source: source, preservingFailure: firstFailure != nil)
    }
    func cancelAutomaticCalibration(source: CalibrationCancellationSource, scene: CalibrationCancellationScene) async {
        recordCalibrationCancellation(source: source, scene: scene)
        await endPointerCalibration()
    }
    func startAssistedCalibration() async { await startAutomaticCalibration() }
    func startAutomaticCalibration() async {
        guard !automaticCalibration.isBusy, !calibrationFlow.isBusy, !calibrationRequestInFlight else { return }
        let initialID = automaticCalibration.id
        // The full-screen controller publishes readiness only after viewDidAppear.
        let layoutDeadline = ProcessInfo.processInfo.systemUptime + 3
        while automaticCalibration.surface?.isFullScreen != true {
            guard !Task.isCancelled, automaticCalibration.id == initialID,
                  ProcessInfo.processInfo.systemUptime < layoutDeadline else {
                guard automaticCalibration.id == initialID else { return }
                automaticCalibration.phase = .error
                automaticCalibration.detail = "全屏安全画布尚未就绪，未申请设备控制。"
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard automaticCalibration.id == initialID, let context = calibrationCanvasContext,
              let surface = automaticCalibration.surface else { return }
        // Let the initiating finger release and verify that geometry remains stable before ARM.
        do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
        guard !Task.isCancelled, automaticCalibration.id == initialID,
              automaticCalibration.surface == surface, surface.isFullScreen else { return }
        automaticCalibration = AutomaticCalibrationState(phase: .detecting, detail: "正在申请本次绝对坐标校准控制。")
        automaticCalibration.absoluteMode = true
        automaticCalibration.usesClickProbes = true
        automaticCalibration.surface = surface
        calibrationObservation = nil
        configuration.invalidatePointerCalibration()
        do {
            var saved = SharedStore.shared.configuration
            saved.invalidatePointerCalibration()
            try SharedStore.shared.write(saved, to: "configuration.json")
        } catch {
            automaticCalibration.phase = .error
            automaticCalibration.detail = "未能撤销旧校准资料，未申请设备控制。"
            return
        }
        let id = automaticCalibration.id
        await beginPointerCalibration(purpose: .measurement)
        guard automaticCalibration.id == id else { return }
        guard calibrationActive else {
            automaticCalibration.phase = .error
            automaticCalibration.detail = notice
            return
        }
        do {
            guard let generation = automaticCalibration.hidGeneration else { throw PilotError.message("设备未提供绝对坐标连接代际。") }
            var samples: [AbsoluteCalibrationSample] = []
            var source: CalibrationProbeTouchSource?
            for (index, target) in AbsoluteCalibrationPlan.targets.enumerated() {
                guard automaticCalibration.surface == surface, surface.isFullScreen,
                      calibrationCanvasContext == context else { throw PilotError.message("全屏校准几何已变化，未继续发送探针。") }
                guard let expiresAt = calibrationFlow.expiresAt, expiresAt.timeIntervalSinceNow > 5 else {
                    throw PilotError.message("校准剩余时间不足以完成下一次探针和停止确认，未续期或保存。")
                }
                if index > 0 { try await Task.sleep(nanoseconds: UInt64.random(in: 150_000_000...300_000_000)) }
                automaticCalibration.detail = "正在读取绝对坐标 \(index + 1)/\(AbsoluteCalibrationPlan.targets.count)，请勿触碰屏幕。"
                let sample = try await captureAbsoluteCalibrationProbe(target: target, id: id)
                if let source, calibrationObservation?.probeSource != source { throw PilotError.message("测量期间触摸来源发生变化，未保存校准。") }
                source = calibrationObservation?.probeSource
                samples.append(sample)
                automaticCalibration.probeCount = samples.count
            }
            automaticCalibration.phase = .verifying
            automaticCalibration.detail = "正在验证独立坐标与不同路径回返点。"
            let tolerance = context.scale * 1.5
            let fit = try AbsoluteCalibrationFit.fit(AbsoluteCalibrationPlan.fitIndices.map { samples[$0] }, tolerancePixels: tolerance)
            let independent = AbsoluteCalibrationPlan.validationIndices.map { samples[$0] }
            let validationError = independent.map { AbsoluteCalibrationFit.residual($0, transform: fit.transform) }.max() ?? .infinity
            guard validationError.isFinite, validationError <= tolerance else { throw PilotError.message("绝对坐标独立验证误差过大，未保存映射。") }
            let centers = AbsoluteCalibrationPlan.centerIndices.map { samples[$0].screen }
            let returnError = centers.flatMap { a in centers.map { b in hypot(a.x - b.x, a.y - b.y) } }.max() ?? .infinity
            guard returnError <= tolerance else { throw PilotError.message("不同路径到达同一绝对目标的落点不一致，未保存映射。") }
            automaticCalibration.correlationVerified = true
            automaticCalibration.probeSource = source
            automaticCalibration.sourceQualificationCount = centers.count
            calibrationFlow.moved = true // Distinct absolute targets have actual UIKit observations.
            let bootID = calibrationFlow.bootID
            await endPointerCalibration()
            guard automaticCalibration.id == id, calibrationFlow.phase == .finished, calibrationFlow.stopConfirmed,
                  !calibrationRequestInFlight, !sending, calibrationCanvasContext == context,
                  automaticCalibration.surface == surface else { throw CancellationError() }
            let t = fit.transform, verifiedAt = Date()
            var profile = PointerCalibrationProfile(context: context,
                pixelsPer100X: hypot(t.a, t.d) * 4000, pixelsPer100Y: hypot(t.b, t.e) * 4000, verifiedAt: verifiedAt)
            profile.hardwareBootID = bootID
            profile.observationSource = source == .direct
                ? "correlated_assistive_touch:absolute HID targets paired with actual UIKit screen pixels; three same-target returns, affine fit and independent heldout; causal correlation, not device identity authentication"
                : "typed_pointer:absolute HID targets paired with actual UIKit screen pixels, affine fit and independent heldout"
            profile.absoluteMapping = AbsolutePointerMapping(hardwareBootID: bootID, hidGeneration: generation,
                screenFromHID: .init(a: t.a, b: t.b, c: t.c, d: t.d, e: t.e, f: t.f),
                maxResidualPixels: max(fit.maxResidualPixels, validationError, returnError), verifiedAt: verifiedAt,
                validationPointCount: independent.count,
                validatedHIDBounds: .init(minX: 500, maxX: 9500, minY: 500, maxY: 9500))
            guard profile.absoluteMapping?.isValid(context: context) == true else { throw PilotError.message("绝对校准资料未通过完整性校验。") }
            var saved = SharedStore.shared.configuration
            saved.automaticCalibrationProfile = profile; saved.deviceURL = context.deviceURL
            saved.orientation = context.orientation; saved.calibrationX = profile.pixelsPer100X; saved.calibrationY = profile.pixelsPer100Y
            saved.relativeModeConfirmed = false // A relative-only grant cannot stand in for this mapping.
            saved.calibratedAt = verifiedAt
            try saved.validate(); try SharedStore.shared.write(saved, to: "configuration.json")
            configuration.automaticCalibrationProfile = profile; configuration.orientation = saved.orientation
            configuration.calibrationX = saved.calibrationX; configuration.calibrationY = saved.calibrationY
            configuration.relativeModeConfirmed = false; configuration.calibratedAt = verifiedAt
            automaticCalibration.phase = .completed
            automaticCalibration.detail = "已验证绝对坐标映射、独立落点与不同路径回返，并确认设备停止。可用范围为实测 HID 500–9500；范围外不会外推或点击。"
        } catch {
            guard automaticCalibration.id == id else { return }
            let reason = calibrationFlow.observationFailure ?? calibrationFlow.errorMessage ?? error.localizedDescription
            await endPointerCalibration()
            guard automaticCalibration.id == id else { return }
            automaticCalibration.phase = calibrationObservation == nil ? .unavailable : .error
            automaticCalibration.detail = "\(reason) 未保存新的绝对映射。" + (calibrationFlow.stopConfirmed ? " 设备已确认停止。" : " 未确认设备停止，请物理停止或断电。")
        }
    }
    // Legacy entry points no longer authorize relative positioning or a second lease.
    func startCalibrationMeasurement() async { await startAutomaticCalibration() }
    func movePositioningPointer(dx: Int, dy: Int) async { notice = "绝对坐标校准不需要手动搬动指针。" }
    private func safeCalibrationPoint(_ point: CalibrationPoint, margin: Double = 20) -> Bool {
        guard let context = calibrationCanvasContext else { return false }
        let inset = margin * context.scale
        return point.x >= inset && point.y >= inset &&
            point.x <= Double(context.pixelWidth) - inset && point.y <= Double(context.pixelHeight) - inset
    }
    private func probeStillAuthorized(id: UUID, calibrationID: UUID) -> Bool {
        automaticCalibration.id == id && automaticCalibration.usesClickProbes && calibrationActive && calibrationFlow.observationFailure == nil &&
        calibrationFlow.id == calibrationID && calibrationFlow.purpose == .measurement &&
        calibrationFlow.stopGeneration == SharedStore.shared.stopGeneration &&
        calibrationFlow.deviceURL == configuration.deviceURL && calibrationCanvasContext != nil &&
        automaticCalibration.absoluteMode && automaticCalibration.surface?.isFullScreen == true
    }
    private func captureAbsoluteCalibrationProbe(target: AbsoluteCalibrationTarget, id: UUID) async throws -> AbsoluteCalibrationSample {
        guard let snapshot = calibrationConfiguration, let expiresAt = calibrationFlow.expiresAt,
              let generation = automaticCalibration.hidGeneration, calibrationFlow.probeSupported, !sending else {
            throw PilotError.message("绝对校准授权或连接代际不可用。")
        }
        let calibrationID = calibrationFlow.id
        guard probeStillAuthorized(id: id, calibrationID: calibrationID) else { throw CancellationError() }
        let actionID = UUID().uuidString
        sending = true
        defer {
            sending = false
            if automaticCalibration.id == id { automaticCalibration.isAwaitingProbe = false; automaticCalibration.probeWindow = nil }
        }
        let receipt = try await HardwareClient(configuration: snapshot).sendAbsoluteCalibrationProbe(id: actionID,
            hidX: target.x, hidY: target.y, expectedBootID: calibrationFlow.bootID, expectedHIDGeneration: generation,
            expectedSession: calibrationFlow.sessionID, expectedControlEpoch: calibrationFlow.controlEpoch,
            frameDeadline: expiresAt.addingTimeInterval(-4),
            stillAuthorized: { self.probeStillAuthorized(id: id, calibrationID: calibrationID) },
            willDispatch: {
                let now = ProcessInfo.processInfo.systemUptime
                self.automaticCalibration.probeWindow = .init(actionID: actionID, openedAt: now, deadline: now + 3, allowsCorrelatedDirect: true)
                self.automaticCalibration.lastProbeTouchDiagnostic = "尚未收到本次绝对目标的点击"
                self.automaticCalibration.isAwaitingProbe = true
            })
        guard probeStillAuthorized(id: id, calibrationID: calibrationID),
              receipt.absolute_position_known == true, receipt.absolute_hid_x == target.x, receipt.absolute_hid_y == target.y,
              receipt.hid_generation == generation else { throw CancellationError() }
        automaticCalibration.probeWindow?.completeHardware(actionID: actionID)
        while let window = automaticCalibration.probeWindow {
            try Task.checkCancellation()
            guard probeStillAuthorized(id: id, calibrationID: calibrationID) else { throw CancellationError() }
            if let failure = window.failure { throw PilotError.message(failure) }
            if let point = window.verifiedPoint {
                calibrationObservation = CalibrationObservation(point: point,
                    sequence: (calibrationObservation?.sequence ?? 0) + 1, date: Date(), probeSource: window.source)
                return .init(target: .init(x: receipt.absolute_hid_x!, y: receipt.absolute_hid_y!), screen: point)
            }
            if ProcessInfo.processInfo.systemUptime >= window.deadline { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw PilotError.message("未收到本次绝对探针完整且唯一的 UIKit 点击（\(automaticCalibration.lastProbeTouchDiagnostic)），未重试。")
    }
    func validateAutomaticCalibrationContext() throws {
        guard let profile = configuration.automaticCalibrationProfile else { return }
        let screen = UIScreen.main
        let orientation = screen.bounds.width > screen.bounds.height ? "landscape" : "portrait"
        let current = PointerCalibrationContext(deviceURL: configuration.deviceURL, phoneModel: UIDevice.current.model,
            orientation: orientation, pixelWidth: Int(screen.bounds.width * screen.scale),
            pixelHeight: Int(screen.bounds.height * screen.scale), scale: Double(screen.scale))
        guard profile.context == current else {
            configuration.invalidatePointerCalibration()
            throw PilotError.message("设备、方向或屏幕尺寸已变化，请重新自动校准。")
        }
    }
}
