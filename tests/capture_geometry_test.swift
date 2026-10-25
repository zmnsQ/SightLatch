import Foundation

@main struct CaptureGeometryTests {
    static func main() throws {
        var configuration = PilotConfiguration()
        let context = PointerCalibrationContext(deviceURL: configuration.deviceURL, phoneModel: "iPhone",
            orientation: "portrait", pixelWidth: 1260, pixelHeight: 2736, scale: 3)
        configuration.automaticCalibrationProfile = PointerCalibrationProfile(context: context,
            pixelsPer100X: 504, pixelsPer100Y: 1094.4, verifiedAt: Date())
        configuration.calibrationX = 504; configuration.calibrationY = 1094.4
        let replay = CaptureGeometry(sourceWidth: 884, sourceHeight: 1920, orientedWidth: 884,
            orientedHeight: 1920, jpegWidth: 590, jpegHeight: 1280, exifOrientation: nil)
        let mapping = try replay.pointerMapping(calibration: configuration).get()
        func near(_ a: Double, _ b: Double) { precondition(abs(a - b) < 0.000_001, "\(a) != \(b)") }
        near(mapping.orientedPixelsPer100X, 353.6); near(mapping.orientedPixelsPer100Y, 768)
        near(mapping.jpegPixelsPer100X, 236); near(mapping.jpegPixelsPer100Y, 512)
        // A 20-unit action is 800 normalized HID units; there is no additional
        // Retina factor when converting its observed JPEG displacement back.
        near(47.2 / mapping.jpegPixelsPer100X * 100, 20)
        near(102.4 / mapping.jpegPixelsPer100Y * 100, 20)
        precondition(replay.modelContext(calibration: configuration).contains("attached JPEG pixels X=236.0, Y=512.0"))
        precondition(replay.modelContext(calibration: configuration).contains("unavailable; do not assume orientation"))

        func failure(_ value: CaptureGeometry, _ expected: CaptureGeometry.MappingFailure,
                     config: PilotConfiguration? = nil) {
            guard case .failure(let actual) = value.pointerMapping(calibration: config ?? configuration) else {
                preconditionFailure("Expected \(expected)")
            }
            precondition(actual == expected, "\(actual) != \(expected)")
        }
        var native = replay
        native.sourceWidth = 1260; native.sourceHeight = 2736
        native.orientedWidth = 1260; native.orientedHeight = 2736
        let nativeMapping = try native.pointerMapping(calibration: configuration).get()
        near(nativeMapping.jpegPixelsPer100X, mapping.jpegPixelsPer100X)
        near(nativeMapping.jpegPixelsPer100Y, mapping.jpegPixelsPer100Y)
        // Independently observed using CIContext + the production transform/JPEG
        // chain: fractional short edges cover outward to 592, not nearest 591.
        for (width, height) in [(1125, 2436), (1090, 2360)] {
            var outward = replay
            outward.sourceWidth = width; outward.orientedWidth = width
            outward.sourceHeight = height; outward.orientedHeight = height
            outward.jpegWidth = 592
            var calibrated = configuration
            calibrated.automaticCalibrationProfile?.context.pixelWidth = width
            calibrated.automaticCalibrationProfile?.context.pixelHeight = height
            let result = try outward.pointerMapping(calibration: calibrated).get()
            near(result.jpegPixelsPer100X, 504 * 592 / Double(width))
            near(result.jpegPixelsPer100Y, 1094.4 * 1280 / Double(height))
            var stretched = outward; stretched.jpegWidth = 593
            failure(stretched, .nonuniformJPEG, config: calibrated)
            var cropped = outward; cropped.jpegWidth = 590
            failure(cropped, .nonuniformJPEG, config: calibrated)
        }
        var exactBoundary = replay
        exactBoundary.sourceWidth = 100; exactBoundary.sourceHeight = 100
        exactBoundary.orientedWidth = 100; exactBoundary.orientedHeight = 100
        exactBoundary.jpegWidth = 100; exactBoundary.jpegHeight = 99
        var square = configuration
        square.automaticCalibrationProfile?.context.pixelWidth = 100
        square.automaticCalibrationProfile?.context.pixelHeight = 100
        failure(exactBoundary, .nonuniformJPEG, config: square)
        var distorted = replay; distorted.sourceHeight = 1900; distorted.orientedHeight = 1900
        failure(distorted, .nonuniformCapture)
        var rotated = replay
        rotated.sourceWidth = 1920; rotated.sourceHeight = 884
        rotated.orientedWidth = 1920; rotated.orientedHeight = 884
        rotated.jpegWidth = 1280; rotated.jpegHeight = 590
        failure(rotated, .orientationChanged)
        var landscape = configuration
        landscape.orientation = "landscape"
        landscape.automaticCalibrationProfile?.context.orientation = "landscape"
        landscape.automaticCalibrationProfile?.context.pixelWidth = 2736
        landscape.automaticCalibrationProfile?.context.pixelHeight = 1260
        landscape.calibrationX = 1094.4; landscape.calibrationY = 504
        let landscapeMapping = try rotated.pointerMapping(calibration: landscape).get()
        near(landscapeMapping.jpegPixelsPer100X, 512); near(landscapeMapping.jpegPixelsPer100Y, 236)
        var normalized = replay
        normalized.sourceWidth = 1920; normalized.sourceHeight = 884; normalized.exifOrientation = 6
        _ = try normalized.pointerMapping(calibration: configuration).get()
        var invalidAxes = normalized; invalidAxes.exifOrientation = 1
        failure(invalidAxes, .invalidDimensions)
        var crop = replay; crop.jpegWidth = 500
        failure(crop, .nonuniformJPEG)
        var zero = replay; zero.jpegHeight = 0
        failure(zero, .invalidDimensions)
        var invalidEXIF = replay; invalidEXIF.exifOrientation = 9
        failure(invalidEXIF, .invalidDimensions)
        var unknown = configuration; unknown.automaticCalibrationProfile = nil
        failure(replay, .missingCalibration, config: unknown)
        var invalidScale = configuration; invalidScale.calibrationX = .nan
        failure(replay, .invalidScale, config: invalidScale)

        var later = replay; later.presentationSeconds = 400
        precondition(replay.hasSameCoordinateSpace(as: later))
        precondition(!replay.hasSameCoordinateSpace(as: native))
        precondition(!replay.hasSameCoordinateSpace(as: normalized))
        var resizedJPEG = replay; resizedJPEG.jpegWidth = 589
        precondition(replay.hasSameCaptureSpace(as: resizedJPEG))
        precondition(!replay.hasSameCoordinateSpace(as: resizedJPEG))
        var confirmedEXIF = replay; confirmedEXIF.exifOrientation = 1
        precondition(!replay.hasSameCoordinateSpace(as: confirmedEXIF))

        // Actual runtime guards must reject changed geometry even when the
        // coarse fingerprint is completely unchanged.
        let sample = SampleGeometryFixture()
        precondition(sample.check(decision: replay, latest: replay) == nil)
        precondition(sample.check(decision: replay, latest: rotated) != nil)
        precondition(sample.check(decision: replay, latest: resizedJPEG) != nil)
        precondition(sample.check(decision: replay, latest: nil) != nil)
        precondition(sample.check(decision: replay, latest: rotated, requiresGeometry: false) == nil)
        let unchanged = [UInt8](repeating: 0, count: 4096)
        let stale = sample.checkSignal(prior: unchanged, latest: unchanged, age: 1.6)!
        precondition(stale.contains("最近没有收到新广播帧"))
        let staleLog = SharedStore.shared.diagnostics.last!
        precondition(!stale.contains("lastObservationAgeSec="))
        precondition(staleLog.contains("lastObservationAgeSec=1.6") && staleLog.contains("remainingDeadlineSec="))
        precondition(staleLog.contains("normalizedDifference=0.000000") && staleLog.contains("geometry=unavailable"))
        let unavailable = sample.checkSignal(prior: [], latest: unchanged, age: 0)!
        let unavailableLog = SharedStore.shared.diagnostics.last!
        precondition(unavailable.contains("校验数据暂不可用") && unavailableLog.contains("normalizedDifference=unavailable"))
        precondition(unavailableLog.contains("decisionFingerprintBytes=0") && unavailableLog.contains("latestFingerprintBytes=4096"))
        var changed = unchanged
        for index in 0..<64 { changed[index] = 255 }
        let difference = sample.checkSignal(prior: unchanged, latest: changed, age: 0)!
        precondition(difference.contains("画面已变化") && SharedStore.shared.diagnostics.last!.contains("normalizedDifference=0.015625"))
        changed[60..<64] = [UInt8](repeating: 0, count: 4)[...]
        precondition(sample.checkSignal(prior: unchanged, latest: changed, age: 0) == nil)
        let expired = sample.checkSignal(prior: unchanged, latest: changed, age: 2, remaining: -0.1)!
        precondition(expired.hasPrefix("截图已过期") && SharedStore.shared.diagnostics.last!.contains("remainingDeadlineSec=-0.1"))
        let frame = SharedFrame(sessionID: "session", id: "frame", capturedAt: Date(), jpeg: Data(),
            fingerprint: Data(repeating: 255, count: 4096), geometry: replay)
        var latest = frame
        SharedStore.shared.latest = latest
        precondition(ContinuedGeometryFixture.check(frame: frame) == nil)
        latest.geometry = rotated; SharedStore.shared.latest = latest
        precondition(ContinuedGeometryFixture.check(frame: frame) != nil)
        precondition(ContinuedGeometryFixture.check(frame: frame, requiresGeometry: false) == nil)
        latest.geometry = nil; SharedStore.shared.latest = latest
        precondition(ContinuedGeometryFixture.check(frame: frame) != nil)
        var agent = AgentSession(id: "session", startedAt: Date(), maxRounds: 20)
        precondition(agent.recoverBeforeDispatch("geometry changed; no HID sent"))
        precondition(agent.recoverBeforeDispatch("geometry changed; no HID sent"))
        precondition(!agent.recoverBeforeDispatch("geometry changed; no HID sent"))
        print("PASS: production geometry mapping, ReplayKit/JPEG rounding, both runtime guards, distinct missing/stale/changed-frame metrics with unchanged thresholds, and bounded reobservation; no real HID")
    }
}
