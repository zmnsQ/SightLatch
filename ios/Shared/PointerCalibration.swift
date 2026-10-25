import Foundation

struct PointerCalibrationState {
    enum Phase { case idle, starting, active, stopping, finished, error }
    enum Purpose { case positioning, measurement }
    var phase: Phase = .idle
    var purpose: Purpose = .measurement
    var expiresAt: Date?
    var errorMessage: String?
    var id = UUID()
    var bootID = ""
    var sessionID = ""
    var controlEpoch: String?
    var stopGeneration: String?
    var moved = false
    var stopConfirmed = false
    var deviceURL = ""
    // nil preserves compatibility with firmware that has no absolute-position adapter.
    var pointerPositionKnown: Bool?
    // Planning-only hint for bounded sample distances; never calibration evidence.
    var relativeLogicalStep: Int?
    var probeSupported = false
    var observationFailure: String?
    var contextInvalidated = false
    var isBusy: Bool { [.starting, .active, .stopping].contains(phase) }
    func allowsMove(dx: Int, dy: Int, now: Date = Date()) -> Bool {
        phase == .active && observationFailure == nil && (expiresAt ?? .distantPast) > now &&
        (-10...10).contains(dx) && (-10...10).contains(dy) &&
        ((dx == 0 && dy != 0) || (dy == 0 && dx != 0))
    }
    mutating func finish(stopped: Bool) {
        expiresAt = nil
        stopConfirmed = stopped
        let measured = purpose == .measurement && moved
        phase = stopped && (measured || purpose == .positioning) ? .finished : .error
        errorMessage = !stopped ? "未确认设备停止，请拔掉 USB 电源。" : purpose == .measurement && !measured ? "未完成指针微移验证，请重新开始校准。" : nil
    }
}
