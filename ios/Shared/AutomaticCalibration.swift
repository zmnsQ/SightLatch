import Foundation

struct CalibrationPoint: Equatable { var x: Double; var y: Double }
struct CalibrationObservation {
    var point: CalibrationPoint; var sequence: Int; var date: Date
    var probeSource: CalibrationProbeTouchSource? = nil
}
struct CalibrationMotionSample {
    var dx: Int; var dy: Int
    var before: CalibrationPoint; var after: CalibrationPoint
}
struct AbsoluteCalibrationSurface: Equatable {
    var id: UUID
    var originX: Double; var originY: Double
    var width: Double; var height: Double
    var screenWidth: Double; var screenHeight: Double
    var presentationReady: Bool
    var isFullScreen: Bool {
        [originX, originY, width, height, screenWidth, screenHeight].allSatisfy(\.isFinite) &&
        presentationReady && screenWidth > 0 && screenHeight > 0 &&
        abs(originX) <= 0.5 && abs(originY) <= 0.5 &&
        abs(width - screenWidth) <= 0.5 && abs(height - screenHeight) <= 0.5
    }
}
struct AbsoluteCalibrationTarget: Equatable {
    var x: Int; var y: Int
    static let center = Self(x: 5000, y: 5000)
}
struct AbsoluteCalibrationSample {
    var target: AbsoluteCalibrationTarget
    var screen: CalibrationPoint // Physical pixels in the current screen coordinate space.
}
enum AbsoluteCalibrationPlan {
    // Center is withheld from fitting. Its three receipts come from different paths.
    static let targets: [AbsoluteCalibrationTarget] = [.center,
        .init(x: 500, y: 500), .init(x: 9500, y: 500),
        .init(x: 9500, y: 9500), .init(x: 500, y: 9500),
        .center, .init(x: 9500, y: 5000), .center]
    static let fitIndices = [1, 2, 3, 4]
    static let validationIndices = [0, 5, 6, 7]
    static let centerIndices = [0, 5, 7]
}
enum AbsoluteCalibrationFit {
    struct Transform {
        var a: Double; var b: Double; var c: Double
        var d: Double; var e: Double; var f: Double
        func point(_ target: AbsoluteCalibrationTarget) -> CalibrationPoint {
            .init(x: a * Double(target.x) + b * Double(target.y) + c,
                  y: d * Double(target.x) + e * Double(target.y) + f)
        }
    }
    struct Result { var transform: Transform; var maxResidualPixels: Double }
    static func fit(_ samples: [AbsoluteCalibrationSample], tolerancePixels: Double) throws -> Result {
        guard samples.count >= 4, tolerancePixels.isFinite, tolerancePixels > 0,
              samples.allSatisfy({ (0...10000).contains($0.target.x) && (0...10000).contains($0.target.y) && $0.screen.x.isFinite && $0.screen.y.isFinite }) else {
            throw PilotError.message("绝对校准样本无效或不足，未保存映射。")
        }
        let rows = samples.map { [(Double($0.target.x) - 5000) / 5000, (Double($0.target.y) - 5000) / 5000, 1.0] }
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for row in rows { for i in 0..<3 { for j in 0..<3 { matrix[i][j] += row[i] * row[j] } } }
        func solve(_ values: [Double]) throws -> [Double] {
            var a = matrix
            var rhs = (0..<3).map { i in zip(rows, values).reduce(0.0) { $0 + $1.0[i] * $1.1 } }
            for column in 0..<3 {
                let pivot = (column..<3).max { abs(a[$0][column]) < abs(a[$1][column]) }!
                guard abs(a[pivot][column]) > 1e-8 else { throw PilotError.message("绝对校准样本共线或分布退化，未保存映射。") }
                if pivot != column { a.swapAt(pivot, column); rhs.swapAt(pivot, column) }
                let divisor = a[column][column]
                for j in column..<3 { a[column][j] /= divisor }; rhs[column] /= divisor
                for i in 0..<3 where i != column {
                    let factor = a[i][column]
                    for j in column..<3 { a[i][j] -= factor * a[column][j] }; rhs[i] -= factor * rhs[column]
                }
            }
            return rhs
        }
        let x = try solve(samples.map { $0.screen.x }), y = try solve(samples.map { $0.screen.y })
        let transform = Transform(a: x[0] / 5000, b: x[1] / 5000, c: x[2] - x[0] - x[1],
            d: y[0] / 5000, e: y[1] / 5000, f: y[2] - y[0] - y[1])
        guard [transform.a, transform.b, transform.c, transform.d, transform.e, transform.f].allSatisfy(\.isFinite),
              abs(transform.a * transform.e - transform.b * transform.d) > 1e-10 else {
            throw PilotError.message("绝对坐标映射不可逆，未保存校准。")
        }
        let residual = samples.map { sample in let point = transform.point(sample.target); return hypot(point.x - sample.screen.x, point.y - sample.screen.y) }.max() ?? .infinity
        guard residual <= tolerancePixels else { throw PilotError.message("绝对坐标拟合误差过大，未保存校准。") }
        return .init(transform: transform, maxResidualPixels: residual)
    }
    static func residual(_ sample: AbsoluteCalibrationSample, transform: Transform) -> Double {
        let point = transform.point(sample.target)
        return hypot(point.x - sample.screen.x, point.y - sample.screen.y)
    }
}
enum CalibrationCancellationScene: String { case active, inactive, background, unknown }
enum CalibrationCancellationSource: String, CaseIterable {
    case positioningStopButton = "positioning_stop_button"
    case measurementStopButton = "measurement_stop_button"
    case viewDisappeared = "view_disappeared"
    case sceneInactive = "scene_inactive"
    case sceneBackground = "scene_background"
    case sceneUnknown = "scene_unknown"
    case globalStop = "global_stop"

    var detail: String {
        switch self {
        case .positioningStopButton: return "已点击停止定位，未保存新的校准结果。"
        case .measurementStopButton: return "已点击停止测量，未保存新的校准结果。"
        case .viewDisappeared: return "已离开校准页面，本轮校准已取消，未保存新的结果。"
        case .sceneInactive: return "App 暂时失去前台交互，本轮校准已取消，未保存新的结果。"
        case .sceneBackground: return "App 已进入后台，本轮校准已取消，未保存新的结果。"
        case .sceneUnknown: return "App 的前台状态已变化，本轮校准已取消，未保存新的结果。"
        case .globalStop: return "已请求停止当前会话，校准已取消，未保存新的结果。"
        }
    }
}
struct AutomaticCalibrationState {
    enum Phase { case idle, positioning, detecting, sampling, verifying, completed, unavailable, error }
    var phase: Phase = .idle
    var detail = "在安全画布内检测真实指针位置，不使用AI猜测。"
    var id = UUID()
    var usesManualMarkers = false
    var isAwaitingMarker = false
    var markerCount = 0
    var usesClickProbes = false
    var isAwaitingProbe = false
    var probeCount = 0
    var sourceQualificationCount = 0
    var correlationVerified = false
    var probeSource: CalibrationProbeTouchSource?
    var probeWindow: CalibrationProbeWindow?
    var directProbeTouches = 0
    var otherProbeTouches = 0
    var lastProbeTouchDiagnostic = "尚未收到设备点击事件"
    var absoluteMode = false
    var surface: AbsoluteCalibrationSurface?
    var hidGeneration: UInt32?
    var controlRequested = false
    var isBusy: Bool { [.positioning, .detecting, .sampling, .verifying].contains(phase) }

    mutating func cancel(source: CalibrationCancellationSource, preservingFailure: Bool) {
        let keepDetail = preservingFailure || phase == .error || phase == .unavailable
        id = UUID() // Invalidate the old coroutine before awaiting verified STOP.
        phase = .error
        if !keepDetail || detail.isEmpty { detail = source.detail }
    }
}
enum CalibrationProbeTouchSource { case indirectPointer, direct, other }
enum CalibrationProbeTouchPhase { case began, ended, cancelled }
struct CalibrationProbeWindow {
    let actionID: String
    let openedAt: TimeInterval
    let deadline: TimeInterval
    var allowsCorrelatedDirect = false
    private(set) var eventCount = 0
    private(set) var source: CalibrationProbeTouchSource?
    private(set) var downAt: TimeInterval?
    private(set) var down: CalibrationPoint?
    private(set) var point: CalibrationPoint?
    private(set) var failure: String?
    private(set) var hardwareCompleted = false
    mutating func observe(point value: CalibrationPoint, source: CalibrationProbeTouchSource,
                          phase: CalibrationProbeTouchPhase, timestamp: TimeInterval, primaryButton: Bool) {
        // Standard HID carries no request ID into UIKit. Direct events are
        // candidates only for the explicit receipt + timing + stationary-point
        // challenge; this is causal correlation, not device authentication.
        guard failure == nil else { return }
        eventCount += 1
        if source == .direct && !allowsCorrelatedDirect { return }
        guard source == .indirectPointer || source == .direct else { failure = "收到不支持的触摸来源。"; return }
        guard timestamp.isFinite, timestamp >= openedAt, timestamp <= deadline else {
            failure = "设备点击事件落在本次接收窗口之外。"; return
        }
        guard value.x.isFinite, value.y.isFinite else { failure = "设备点击坐标无效。"; return }
        switch phase {
        case .began:
            guard (source == .direct || primaryButton), down == nil, point == nil else {
                failure = "点击按下事件重复，或鼠标事件不是主按钮。"; return
            }
            self.source = source; down = value; downAt = timestamp
        case .ended:
            guard let down, let downAt, self.source == source, point == nil else {
                failure = "点击缺少对应按下事件、来源变化或释放重复。"; return
            }
            let duration = timestamp - downAt
            guard duration >= 0, duration <= 0.5 else {
                failure = "点击持续\(String(format: "%.0f", duration * 1000))毫秒，已超出短点击范围。"; return
            }
            let drift = hypot(value.x - down.x, value.y - down.y)
            guard drift <= 1.5 else { failure = "点击期间移动了\(String(format: "%.1f", drift))点；未采纳本次落点。"; return }
            point = value
        case .cancelled: failure = "系统取消了设备点击事件。"
        }
    }
    mutating func completeHardware(actionID: String) {
        guard actionID == self.actionID else { failure = "设备点击回执与本次请求不一致。"; return }
        hardwareCompleted = true
    }
    var verifiedPoint: CalibrationPoint? { hardwareCompleted && failure == nil ? point : nil }
}
enum CalibrationFit {
    static func fit(_ samples: [CalibrationMotionSample], minSamplesPerAxis: Int = 4) throws -> (x: Double, y: Double) {
        let horizontal = samples.filter { $0.dx != 0 && $0.dy == 0 }
        let vertical = samples.filter { $0.dy != 0 && $0.dx == 0 }
        guard horizontal.count >= minSamplesPerAxis, vertical.count >= minSamplesPerAxis else { throw PilotError.message("真实观测样本不足。") }
        func slope(_ rows: [CalibrationMotionSample], x: Bool) throws -> Double {
            let axis = x ? "横向" : "纵向"
            let ratios = rows.map { row in
                x ? (row.after.x - row.before.x) / Double(row.dx) : (row.after.y - row.before.y) / Double(row.dy)
            }
            guard ratios.allSatisfy({ $0.isFinite && $0 >= 0.05 && $0 <= 30 }) else {
                throw PilotError.message("\(axis)未检测到正确方向的实际指针位移。")
            }
            let value = ratios.reduce(0, +) / Double(ratios.count)
            for (row, ratio) in zip(rows, ratios) {
                let cross = x ? abs(row.after.y - row.before.y) : abs(row.after.x - row.before.x)
                guard abs(ratio - value) <= max(0.1, value * 0.2), cross <= 1.5 else {
                    throw PilotError.message("\(axis)移动尺度为\(String(format: "%.2f", ratio))点/单位、均值\(String(format: "%.2f", value))，另一方向偏移\(String(format: "%.1f", cross))点；位置观测不稳定，未保存校准。")
                }
            }
            if rows.count >= 2 {
                for index in 1..<rows.count {
                    let previous = rows[index - 1], current = rows[index]
                    if previous.dx + current.dx == 0, previous.dy + current.dy == 0, previous.after == current.before {
                        let closure = hypot(current.after.x - previous.before.x, current.after.y - previous.before.y)
                        guard closure <= 1.5 else { throw PilotError.message("\(axis)往返后距起点\(String(format: "%.1f", closure))点，未闭合；未保存校准。") }
                    }
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
