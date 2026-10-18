import Foundation
import UIKit

extension PilotViewModel {
    func updateCalibrationCanvas(width: Double, height: Double, context: PointerCalibrationContext) {
        let changed = calibrationCanvasContext != context || calibrationCanvasWidth != width || calibrationCanvasHeight != height
        calibrationCanvasWidth = width; calibrationCanvasHeight = height; calibrationCanvasContext = context
        if changed {
            calibrationObservation = nil
            if automaticCalibration.isBusy { Task { await cancelAutomaticCalibration() } }
        }
        if let profile = configuration.automaticCalibrationProfile, profile.context != context {
            configuration.relativeModeConfirmed = false
        }
    }
    func observeCalibrationPointer(x: Double, y: Double) {
        guard !automaticCalibration.usesManualMarkers else { return }
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= calibrationCanvasWidth, y <= calibrationCanvasHeight else { return }
        calibrationObservation = CalibrationObservation(point: .init(x: x, y: y),
            sequence: (calibrationObservation?.sequence ?? 0) + 1, date: Date())
    }
    func markObservedPointer(x: Double, y: Double) {
        guard automaticCalibration.usesManualMarkers, automaticCalibration.isAwaitingMarker,
              automaticCalibration.isBusy, calibrationActive,
              x.isFinite, y.isFinite, x >= 20, y >= 20,
              x <= calibrationCanvasWidth - 20, y <= calibrationCanvasHeight - 20 else { return }
        calibrationObservation = CalibrationObservation(point: .init(x: x, y: y),
            sequence: (calibrationObservation?.sequence ?? 0) + 1, date: Date())
        automaticCalibration.isAwaitingMarker = false
        automaticCalibration.markerCount += 1
    }
    func calibrationCanvasDetached() {
        calibrationCanvasContext = nil; calibrationObservation = nil
        if automaticCalibration.isBusy || calibrationFlow.isBusy { Task { await cancelAutomaticCalibration() } }
    }
    func cancelAutomaticCalibration() async {
        automaticCalibration.id = UUID()
        automaticCalibration.phase = .error
        automaticCalibration.detail = "校准已取消，未保存新的结果。"
        await endPointerCalibration()
    }
    func startAssistedCalibration() async { await runMeasuredCalibration(assisted: true) }
    func startAutomaticCalibration() async {
        await runMeasuredCalibration(assisted: UIDevice.current.userInterfaceIdiom == .phone)
    }
    private func runMeasuredCalibration(assisted: Bool) async {
        guard !automaticCalibration.isBusy, let context = calibrationCanvasContext,
              calibrationCanvasWidth >= 160, calibrationCanvasHeight >= 160 else {
            notice = "请保持安全画布可见，再开始自动校准。"; return
        }
        automaticCalibration = AutomaticCalibrationState(phase: .detecting, detail: "正在申请本次短时校准控制。")
        automaticCalibration.usesManualMarkers = assisted
        if assisted { calibrationObservation = nil }
        await beginPointerCalibration()
        guard calibrationActive else { automaticCalibration.phase = .error; automaticCalibration.detail = notice; return }
        automaticCalibration = AutomaticCalibrationState(phase: .detecting,
            detail: "正在检测真实指针位置。若有鼠标或触控板，请将指针移到画布中央；不要触碰屏幕。")
        automaticCalibration.usesManualMarkers = assisted
        let id = automaticCalibration.id
        do {
            let initial = try await waitForCalibrationObservation(after: -1, id: id, timeout: assisted ? 15 : 5)
            guard safeCalibrationPoint(initial.point, margin: 55) else { throw PilotError.message("指针靠近画布边缘。请移到中央后重试。") }
            automaticCalibration.phase = .sampling
            automaticCalibration.detail = "正在测量实际指针的小步往返移动，请勿手动移动指针。"
            var samples: [CalibrationMotionSample] = []
            let samplingMoves = assisted ? [(10,0),(-10,0),(0,10),(0,-10)] : [(5,0),(-5,0),(0,5),(0,-5),(10,0),(-10,0),(0,10),(0,-10)]
            for (dx, dy) in samplingMoves {
                samples.append(try await collectCalibrationMotion(dx: dx, dy: dy, id: id))
            }
            let fit = try CalibrationFit.fit(samples, minSamplesPerAxis: assisted ? 2 : 4)
            automaticCalibration.phase = .verifying
            automaticCalibration.detail = "正在用新的微移验证测量结果。"
            let validationMoves = assisted ? [(7,0),(0,7)] : [(7,0),(-7,0),(0,7),(0,-7)]
            for (dx, dy) in validationMoves {
                let sample = try await collectCalibrationMotion(dx: dx, dy: dy, id: id)
                guard CalibrationFit.validate(sample, x: fit.x, y: fit.y) else { throw PilotError.message("独立验证不一致，未保存校准。") }
            }
            await endPointerCalibration()
            guard automaticCalibration.id == id, calibrationFlow.phase == .finished,
                  calibrationCanvasContext == context else { throw CancellationError() }
            var profile = PointerCalibrationProfile(context: context,
                pixelsPer100X: fit.x * context.scale * 100, pixelsPer100Y: fit.y * context.scale * 100, verifiedAt: Date())
            profile.observationSource = assisted ? "User-marked visible pointer positions on in-app canvas; not automatic observation" : "UIKit indirect-pointer hover; in-app canvas only"
            profile.hardwareBootID = calibrationFlow.bootID
            var saved = SharedStore.shared.configuration
            saved.automaticCalibrationProfile = profile; saved.deviceURL = context.deviceURL
            saved.orientation = context.orientation; saved.calibrationX = profile.pixelsPer100X; saved.calibrationY = profile.pixelsPer100Y
            saved.relativeModeConfirmed = true; saved.calibratedAt = profile.verifiedAt
            try saved.validate(); try SharedStore.shared.write(saved, to: "configuration.json")
            configuration.automaticCalibrationProfile = profile; configuration.orientation = saved.orientation
            configuration.calibrationX = saved.calibrationX; configuration.calibrationY = saved.calibrationY
            configuration.relativeModeConfirmed = true; configuration.calibratedAt = saved.calibratedAt
            automaticCalibration.phase = .completed
            automaticCalibration.detail = assisted
                ? "已根据你标记的实际指针位置计算并验证移动尺度，设备已确认停止。已保存当前设备、方向和屏幕尺寸的辅助校准结果。"
                : "已用系统指针位置完成测量与独立验证，设备已停止控制。结果仅适用于当前设备、方向和屏幕尺寸。"
        } catch {
            guard automaticCalibration.id == id else { return }
            let noObservation = !assisted && calibrationObservation == nil
            await endPointerCalibration()
            guard automaticCalibration.id == id else { return }
            automaticCalibration.phase = noObservation ? .unavailable : .error
            automaticCalibration.detail = noObservation
                ? "当前系统没有提供可测量的指针位置。iPhone 的辅助触控可能不提供此事件；已停止，未保存校准。若有鼠标或触控板，可将指针移入画布后重试，否则当前设备无法自动校准。"
                : "\(error.localizedDescription) 未保存新的校准；请查看下方停止状态。"
            if calibrationFlow.phase == .finished { automaticCalibration.detail += " 设备已确认停止。" }
            else if let failure = calibrationFlow.errorMessage { automaticCalibration.detail += " \(failure)" }
            else { automaticCalibration.detail += " 正在确认停止，请勿退出安全页面。" }
        }
    }
    private func safeCalibrationPoint(_ point: CalibrationPoint, margin: Double = 20) -> Bool {
        point.x >= margin && point.y >= margin && point.x <= calibrationCanvasWidth - margin && point.y <= calibrationCanvasHeight - margin
    }
    private func waitForCalibrationObservation(after sequence: Int, id: UUID, timeout: Double = 2) async throws -> CalibrationObservation {
        if automaticCalibration.usesManualMarkers {
            automaticCalibration.isAwaitingMarker = true
            automaticCalibration.detail = "第\(automaticCalibration.markerCount + 1)/7次：请用手指点你现在看到的实际指针中心。看不清或不在画布内请取消；60秒内未完成会停止，可重新开始。"
        }
        defer { automaticCalibration.isAwaitingMarker = false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard automaticCalibration.id == id, calibrationActive, calibrationCanvasContext != nil else { throw CancellationError() }
            try Task.checkCancellation()
            if let observation = calibrationObservation, observation.sequence > sequence,
               Date().timeIntervalSince(observation.date) < 0.7,
               Date().timeIntervalSince(observation.date) >= 0.15 { return observation }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PilotError.message("未收到稳定的新指针位置，无法确认实际移动。")
    }
    private func collectCalibrationMotion(dx: Int, dy: Int, id: UUID) async throws -> CalibrationMotionSample {
        guard let before = calibrationObservation, safeCalibrationPoint(before.point),
              automaticCalibration.id == id, calibrationActive else { throw CancellationError() }
        await moveCalibrationPointer(dx: dx, dy: dy)
        guard calibrationActive, automaticCalibration.id == id else { throw CancellationError() }
        let after = try await waitForCalibrationObservation(after: before.sequence, id: id, timeout: automaticCalibration.usesManualMarkers ? 10 : 2)
        guard safeCalibrationPoint(after.point) else { throw PilotError.message("指针已接近画布边缘，已中止测试。") }
        return .init(dx: dx, dy: dy, before: before.point, after: after.point)
    }
    func validateAutomaticCalibrationContext() throws {
        guard let profile = configuration.automaticCalibrationProfile else { return }
        let screen = UIScreen.main
        let orientation = screen.bounds.width > screen.bounds.height ? "landscape" : "portrait"
        let current = PointerCalibrationContext(deviceURL: configuration.deviceURL, phoneModel: UIDevice.current.model,
            orientation: orientation, pixelWidth: Int(screen.bounds.width * screen.scale),
            pixelHeight: Int(screen.bounds.height * screen.scale), scale: Double(screen.scale))
        guard profile.context == current else {
            configuration.relativeModeConfirmed = false
            throw PilotError.message("设备、方向或屏幕尺寸已变化，请重新自动校准。")
        }
    }
}
