import Foundation

struct PointerCalibrationState {
    enum Phase { case idle, starting, active, stopping, finished, error }
    var phase: Phase = .idle
    var expiresAt: Date?
    var errorMessage: String?
    var id = UUID()
    var bootID = ""
    var sessionID = ""
    var controlEpoch: String?
    var stopGeneration: String?
    var moved = false
    var deviceURL = ""
    var isBusy: Bool { [.starting, .active, .stopping].contains(phase) }
    func allowsMove(dx: Int, dy: Int, now: Date = Date()) -> Bool {
        phase == .active && (expiresAt ?? .distantPast) > now &&
        (-10...10).contains(dx) && (-10...10).contains(dy) &&
        ((dx == 0 && dy != 0) || (dy == 0 && dx != 0))
    }
    mutating func finish(stopped: Bool) {
        expiresAt = nil
        phase = stopped && moved ? .finished : .error
        errorMessage = !stopped ? "未确认设备停止，请拔掉 USB 电源。" : !moved ? "未完成指针微移验证，请重新开始校准。" : nil
    }
}
