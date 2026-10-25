import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@MainActor final class UIDevice {
    enum Idiom { case phone, pad }
    static let current = UIDevice()
    var userInterfaceIdiom = Idiom.phone
    var model = "test-phone"
}
@MainActor final class UIScreen {
    static let main = UIScreen()
    var bounds = CGRect(x: 0, y: 0, width: 420, height: 912)
    var scale = 3.0
}
@main struct CalibrationPositioningTests {
    @MainActor static func main() async throws {
        func setup() throws -> PilotViewModel {
            HardwareClient.device = .calibrationFixture(positionKnown: false)
            HardwareClient.calls = []; HardwareClient.failStop = false; HardwareClient.failProbe = false
            HardwareClient.failMove = false; HardwareClient.armDelay = 0; HardwareClient.onStop = nil; HardwareClient.onAbsoluteProbe = nil
            let model = PilotViewModel()
            model.calibrationCanvasWidth = 420; model.calibrationCanvasHeight = 912
            model.calibrationCanvasContext = .init(deviceURL: model.configuration.deviceURL, phoneModel: "test-phone",
                orientation: "portrait", pixelWidth: 1260, pixelHeight: 2736, scale: 3)
            model.automaticCalibration.surface = .init(id: UUID(), originX: 0, originY: 0, width: 420, height: 912,
                screenWidth: 420, screenHeight: 912, presentationReady: true)
            try SharedStore.shared.write(PilotConfiguration(), to: "configuration.json")
            return model
        }
        func installObservations(_ model: PilotViewModel, adjustment: @escaping (Int, inout CalibrationPoint) -> Void = { _, _ in }) {
            var index = 0
            HardwareClient.onAbsoluteProbe = { x, y in
                var point = CalibrationPoint(x: 0.12 * Double(x) + 0.001 * Double(y) + 20,
                    y: 0.002 * Double(x) + 0.25 * Double(y) + 50)
                adjustment(index, &point); index += 1
                let sequence = model.calibrationObservation?.sequence
                let now = ProcessInfo.processInfo.systemUptime
                model.observeCalibrationProbeTouch(x: point.x, y: point.y, source: .direct, phase: .began, timestamp: now, primaryButton: false)
                model.observeCalibrationProbeTouch(x: point.x, y: point.y, source: .direct, phase: .ended, timestamp: now, primaryButton: false)
                precondition(model.calibrationObservation?.sequence == sequence, "Actual UIKit alone cannot become an observation before the matching hardware receipt")
                precondition(model.configuration.automaticCalibrationProfile == nil)
            }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(condition())
        }
        var model = try setup()
        let request = model.taskFlow.begin(goal: "retain this pending goal", configurationID: Data())!
        model.taskFlow.receive("existing plan", requestID: request)
        installObservations(model)
        let measuredModel = model
        HardwareClient.onStop = {
            precondition(measuredModel.configuration.automaticCalibrationProfile == nil)
            precondition(SharedStore.shared.configuration.automaticCalibrationProfile == nil, "STOP/drain must finish before profile persistence")
        }
        await model.startAutomaticCalibration()
        precondition(model.automaticCalibration.phase == .completed && model.automaticCalibration.probeCount == 8)
        precondition(HardwareClient.calls.filter { $0 == "arm" }.count == 1 && HardwareClient.calls.filter { $0 == "absolute_probe" }.count == 8)
        precondition(!HardwareClient.calls.contains("move") && !model.configuration.relativeModeConfirmed && !HardwareClient.device.armed)
        let profile = model.configuration.automaticCalibrationProfile!, mapping = profile.absoluteMapping!
        precondition(abs(mapping.screenFromHID.a - 0.12) < 1e-9 && abs(mapping.screenFromHID.b - 0.001) < 1e-9)
        precondition(abs(mapping.screenFromHID.c - 20) < 1e-8 && abs(mapping.screenFromHID.d - 0.002) < 1e-9 && abs(mapping.screenFromHID.f - 50) < 1e-8)
        precondition(mapping.hardwareBootID == "boot" && mapping.hidGeneration == 9 && mapping.validationPointCount == 4)
        precondition(mapping.validatedHIDBounds.minX == 500 && mapping.validatedHIDBounds.maxY == 9500 && mapping.maxResidualPixels < 1e-7)
        precondition(model.automaticCalibration.correlationVerified && model.automaticCalibration.sourceQualificationCount == 3)
        precondition(model.taskFlow.requestID == request && model.taskFlow.plan == "existing plan")
        precondition(profile.observationSource.hasPrefix("correlated_assistive_touch"))
        precondition(!model.confirmPointerCalibration(), "Legacy confirmation cannot turn an absolute mapping into a relative grant")

        // Independent center is never used in the fit, so its bias cannot be hidden in an intercept.
        model = try setup(); installObservations(model) { index, point in if index == 0 { point.x += 20 } }
        await model.startAutomaticCalibration()
        precondition(model.configuration.automaticCalibrationProfile == nil && model.automaticCalibration.detail.contains("独立验证"))
        precondition(!HardwareClient.device.armed && model.calibrationFlow.stopConfirmed)

        // Each heldout is within the per-point tolerance, but path-dependent return spread is not.
        model = try setup(); installObservations(model) { index, point in
            if [0, 7].contains(index) { point.x += 3 }; if index == 5 { point.x -= 3 }
        }
        await model.startAutomaticCalibration()
        precondition(model.configuration.automaticCalibrationProfile == nil && model.automaticCalibration.detail.contains("不同路径"))

        model = try setup(); installObservations(model); HardwareClient.failStop = true
        await model.startAutomaticCalibration()
        precondition(model.configuration.automaticCalibrationProfile == nil && !model.calibrationFlow.stopConfirmed)
        HardwareClient.failStop = false; await model.endPointerCalibration()

        model = try setup(); HardwareClient.device.absolute_probe_supported = false
        await model.startAutomaticCalibration()
        precondition(HardwareClient.calls == ["status"] && !model.automaticCalibration.controlRequested)
        model = try setup(); HardwareClient.device.lease_remaining_ms = 3500; installObservations(model)
        await model.startAutomaticCalibration()
        precondition(HardwareClient.calls.filter { $0 == "arm" }.count == 1 && !HardwareClient.calls.contains("absolute_probe"))
        precondition(model.configuration.automaticCalibrationProfile == nil && model.automaticCalibration.detail.contains("剩余时间不足"))

        model = try setup(); installObservations(model); HardwareClient.armDelay = 100_000_000
        let interrupted = model
        let task = Task { await interrupted.startAutomaticCalibration() }
        try await waitUntil { HardwareClient.calls.contains("arm") }
        await model.cancelAutomaticCalibration(source: .sceneInactive, scene: .inactive); await task.value
        precondition(!HardwareClient.device.armed && model.calibrationFlow.stopConfirmed && !HardwareClient.calls.contains("absolute_probe"))
        precondition(model.configuration.automaticCalibrationProfile == nil && model.automaticCalibration.detail == CalibrationCancellationSource.sceneInactive.detail)

        model = try setup(); installObservations(model)
        let changed = model
        HardwareClient.onAbsoluteProbe = { _, _ in
            changed.updateCalibrationCanvas(width: 421, height: 912, context: changed.calibrationCanvasContext!, surface: changed.automaticCalibration.surface)
        }
        await model.startAutomaticCalibration()
        try await waitUntil { !changed.calibrationFlow.isBusy }
        precondition(changed.calibrationFlow.contextInvalidated && changed.configuration.automaticCalibrationProfile == nil)
        precondition(HardwareClient.calls.filter { $0 == "absolute_probe" }.count == 1 && !HardwareClient.device.armed)

        // A detached older surface cannot revoke a replacement canvas with the same screen size.
        model = try setup()
        let currentSurfaceID = model.automaticCalibration.surface!.id
        model.calibrationCanvasDetached(surfaceID: UUID())
        precondition(model.calibrationCanvasContext != nil && model.automaticCalibration.surface?.id == currentSurfaceID)
        print("PASS: production 8-probe absolute calibration, unknown initial position, true screen-pixel affine intercept/cross terms, heldout/path return checks, one lease/no relative positioning, STOP before persistence, retained goal, capability/lease/geometry/cancellation/failed-STOP rejection; hardware and UIKit seams mocked")
    }
}
