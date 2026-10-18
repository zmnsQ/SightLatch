import Foundation

struct CalibrationPoint: Equatable { var x: Double; var y: Double }
struct CalibrationObservation { var point: CalibrationPoint; var sequence: Int; var date: Date }
struct CalibrationMotionSample {
    var dx: Int; var dy: Int
    var before: CalibrationPoint; var after: CalibrationPoint
}
struct AutomaticCalibrationState {
    enum Phase { case idle, detecting, sampling, verifying, completed, unavailable, error }
    var phase: Phase = .idle
    var detail = "在安全画布内检测真实指针位置，不使用AI猜测。"
    var id = UUID()
    var usesManualMarkers = false
    var isAwaitingMarker = false
    var markerCount = 0
    var isBusy: Bool { [.detecting, .sampling, .verifying].contains(phase) }
}
enum CalibrationFit {
    static func fit(_ samples: [CalibrationMotionSample], minSamplesPerAxis: Int = 4) throws -> (x: Double, y: Double) {
        let horizontal = samples.filter { $0.dx != 0 && $0.dy == 0 }
        let vertical = samples.filter { $0.dy != 0 && $0.dx == 0 }
        guard horizontal.count >= minSamplesPerAxis, vertical.count >= minSamplesPerAxis else { throw PilotError.message("真实观测样本不足。") }
        func slope(_ rows: [CalibrationMotionSample], x: Bool) throws -> Double {
            let ratios = rows.map { row in
                x ? (row.after.x - row.before.x) / Double(row.dx) : (row.after.y - row.before.y) / Double(row.dy)
            }
            guard ratios.allSatisfy({ $0.isFinite && $0 >= 0.05 && $0 <= 30 }) else {
                throw PilotError.message("未检测到正确方向的实际指针位移。")
            }
            let value = ratios.reduce(0, +) / Double(ratios.count)
            for (row, ratio) in zip(rows, ratios) {
                let cross = x ? abs(row.after.y - row.before.y) : abs(row.after.x - row.before.x)
                guard abs(ratio - value) <= max(0.1, value * 0.2), cross <= 1.5 else {
                    throw PilotError.message("指针加速、方向或位置观测不稳定，不能可靠保存。")
                }
            }
            return value
        }
        return (try slope(horizontal, x: true), try slope(vertical, x: false))
    }
    static func validate(_ sample: CalibrationMotionSample, x: Double, y: Double) -> Bool {
        let expectedX = Double(sample.dx) * x, expectedY = Double(sample.dy) * y
        return abs(sample.after.x - sample.before.x - expectedX) <= max(1.5, abs(expectedX) * 0.15) &&
            abs(sample.after.y - sample.before.y - expectedY) <= max(1.5, abs(expectedY) * 0.15)
    }
}
