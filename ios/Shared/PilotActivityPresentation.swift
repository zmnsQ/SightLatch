import Foundation

/// Whitelisted lock-screen copy: never display task text, model output, URLs or tool arguments.
enum PilotActivityStage: String {
    case ready, observing, planning, executing, needsInput, failed, completed, stopped, unknown
    init(phase: String) {
        switch phase {
        case "待广播", "准备": self = .ready
        case "观察", "广播中": self = .observing
        case "规划", "思考": self = .planning
        case "执行": self = .executing
        case "暂停", "需输入", "等待用户": self = .needsInput
        case "硬件已停止，请结束广播": self = .failed
        case "完成", "已完成": self = .completed
        case "停止", "硬件已解除ARM": self = .stopped
        default:
            self = phase.contains("失败") || phase.contains("急停") || phase.contains("未确认") || phase.contains("核实") ? .failed : .unknown
        }
    }
    var title: String {
        switch self {
        case .ready: return "等待开始广播"
        case .observing: return "查看屏幕"
        case .planning: return "规划下一步"
        case .executing: return "执行操作"
        case .needsInput: return "需要你处理"
        case .failed: return "请检查会话"
        case .completed: return "任务已完成"
        case .stopped: return "自动操作已停止"
        case .unknown: return "会话状态"
        }
    }
    var symbol: String {
        switch self {
        case .ready: return "record.circle"
        case .observing: return "eye"
        case .planning: return "sparkles"
        case .executing: return "cursorarrow.motionlines"
        case .needsInput: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    var summary: String {
        switch self {
        case .ready: return "打开聊天，确认后从系统开始屏幕广播。"
        case .needsInput: return "打开聊天查看原因；不会自动确认敏感操作。"
        case .failed: return "打开聊天检查；停止未确认时请物理急停。"
        case .completed, .stopped: return "请从系统结束屏幕广播；物理急停始终优先。"
        default: return "仅显示进度摘要；打开聊天查看实际操作记录。"
        }
    }
    var needsAttention: Bool { self == .needsInput || self == .failed || self == .completed }
    var isTerminal: Bool { self == .completed || self == .stopped }
}
