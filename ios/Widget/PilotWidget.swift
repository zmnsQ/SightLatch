import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct PilotWidgetBundle: WidgetBundle {
    var body: some Widget { PilotLiveActivity() }
}

struct PilotLiveActivity: Widget {
    private let chatURL = URL(string: "sightlatch://chat")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PilotActivityAttributes.self) { context in
            let snapshot = PilotActivitySnapshot(context)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    PilotActivityPresence(snapshot: snapshot, size: 29)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SightLatch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        PilotActivityPhase(snapshot: snapshot)
                    }
                    Spacer(minLength: 6)
                    PilotActivitySteps(steps: snapshot.steps)
                }
                PilotActivityDetails(snapshot: snapshot)
            }
            .padding(.horizontal, 17).padding(.vertical, 15)
            .activityBackgroundTint(nil)
            .widgetURL(chatURL)
        } dynamicIsland: { context in
            let snapshot = PilotActivitySnapshot(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        PilotActivityPresence(snapshot: snapshot, size: 28)
                        PilotActivityPhase(snapshot: snapshot)
                    }
                    .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: chatURL) {
                        Label(snapshot.stage.needsAttention ? "查看" : "会话", systemImage: "arrow.up.forward")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 30)
                    }
                    .tint(snapshot.accent).accessibilityLabel("打开 SightLatch 查看当前步骤")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PilotActivityDetails(snapshot: snapshot)
                        .foregroundStyle(.white).padding(.top, 5).padding(.bottom, 3)
                }
            } compactLeading: {
                PilotActivityPresence(snapshot: snapshot, size: 22)
                    .accessibilityLabel(snapshot.accessibilitySummary)
            } compactTrailing: {
                HStack(spacing: 3) {
                    PilotActivitySymbol(snapshot: snapshot)
                    Text(snapshot.compactTitle).font(.system(size: 10, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.accessibilitySummary)
            } minimal: {
                PilotActivityPresence(snapshot: snapshot, size: 22)
                    .accessibilityLabel(snapshot.accessibilitySummary)
            }
            .widgetURL(chatURL).keylineTint(.blue)
        }
    }
}

private struct PilotActivitySnapshot {
    let attributes: PilotActivityAttributes
    let state: PilotActivityAttributes.ContentState
    let isStale: Bool

    init(_ context: ActivityViewContext<PilotActivityAttributes>) {
        attributes = context.attributes; state = context.state; isStale = context.isStale
    }
    var stage: PilotActivityStage { PilotActivityStage(phase: state.phase) }
    var steps: Int { max(0, state.steps) }
    var running: Bool { state.running ?? !stage.isTerminal }
    var isWaitingForCapture: Bool { stage == .ready && state.executionStartedAt == nil }
    var staleWhileExecuting: Bool { isStale && running && !stage.isTerminal && !stage.needsAttention && !isWaitingForCapture }
    var stageTitle: String { staleWhileExecuting ? "等待状态更新" : stage.title }
    var symbol: String { staleWhileExecuting ? "clock.badge.exclamationmark" : stage.symbol }
    var compactTitle: String {
        if staleWhileExecuting { return "等待" }
        switch stage {
        case .ready: return "待共享"
        case .starting: return "连接"
        case .observing: return "观察"
        case .planning: return "思考"
        case .executing: return steps > 0 ? "\(steps)步" : "执行"
        case .needsInput, .failed: return "请查看"
        case .completed: return "完成"
        case .stopped: return "已停止"
        case .unknown: return "会话"
        }
    }
    var accent: Color {
        if staleWhileExecuting { return .orange }
        switch stage {
        case .failed: return .red
        case .needsInput: return .orange
        case .completed: return .green
        case .stopped: return .secondary
        default: return .blue
        }
    }
    var taskSummary: String {
        switch attributes.taskSummary {
        case "微信消息任务": return "微信消息任务"
        case "微信操作任务": return "微信操作任务"
        default: return "屏幕操作任务"
        }
    }
    var notice: PilotActivityNotice? { state.noticeCode.flatMap(PilotActivityNotice.init(rawValue:)) }
    var actionSummary: String {
        if stage.needsAttention {
            if let message = PilotActivitySummary.userMessage(state.noticeMessage) { return message }
            if let notice { return notice.text }
        }
        if isWaitingForCapture { return "开始共享后自动继续" }
        if staleWhileExecuting { return "点按查看会话，自动操作不会因刷新恢复" }
        if stage.isTerminal { return "本轮控制已结束，请从系统结束屏幕广播" }
        let fallback = PilotActivitySummary.action(phase: state.phase, detail: "")
        // Only closed semantic strings cross the Lock Screen boundary.
        let allowed = [fallback, "调整指针位置", "点击当前目标", "滚动当前页面", "使用键盘快捷键", "准备文字输入",
                       "发送本次授权消息", "填入本次授权正文", "定位并点击当前目标", "定位当前目标"]
        return state.actionSummary.flatMap { allowed.contains($0) ? $0 : nil } ?? fallback
    }
    var timerInterval: ClosedRange<Date>? {
        guard running, !stage.isTerminal, !stage.needsAttention else { return nil }
        return PilotActivitySummary.executionInterval(startedAt: state.executionStartedAt, expiresAt: state.executionExpiresAt)
    }
    var isUnlimited: Bool { running && !stage.isTerminal && state.executionStartedAt != nil && state.isUnlimited == true && state.executionExpiresAt == nil }
    var canStop: Bool { !stage.isTerminal && (running || stage == .failed) }
    var eventID: String { state.eventID ?? "\(state.updatedAt.timeIntervalSince1970):\(state.phase):\(steps)" }
    var orbitAngle: Double {
        let stages: [PilotActivityStage] = [.ready, .starting, .observing, .planning, .executing, .needsInput, .failed, .completed, .stopped, .unknown]
        return Double(((stages.firstIndex(of: stage) ?? 0) * 47 + steps * 31) % 360)
    }
    var accessibilitySummary: String { "SightLatch，\(stageTitle)，已执行 \(steps) 步，\(actionSummary)" }
}

private struct PilotActivityDetails: View {
    let snapshot: PilotActivitySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.taskSummary).font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Text(snapshot.actionSummary).font(.subheadline.weight(snapshot.stage.needsAttention ? .medium : .regular))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if snapshot.canStop {
                    Button(intent: StopPilotSessionIntent()) {
                        VStack(spacing: 3) {
                            Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold))
                            Text("停止").font(.system(size: 10, weight: .medium))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).tint(.red).foregroundStyle(.red)
                    .accessibilityLabel("停止 SightLatch 会话")
                }
            }
            PilotActivityTime(snapshot: snapshot)
        }
    }
}

private struct PilotActivityPhase: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let snapshot: PilotActivitySnapshot
    var body: some View {
        Text(snapshot.stageTitle).font(.subheadline.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .id(snapshot.stageTitle)
            .transition(reduceMotion || isLuminanceReduced ? .identity : .opacity.combined(with: .offset(y: 2)))
            .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.3), value: snapshot.stageTitle)
    }
}

private struct PilotActivityTime: View {
    let snapshot: PilotActivitySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PilotActivitySteps(steps: snapshot.steps)
                Spacer(minLength: 0)
                if let interval = snapshot.timerInterval {
                    HStack(spacing: 4) {
                        Text("剩余").foregroundStyle(.secondary)
                        Text(timerInterval: interval, countsDown: true, showsHours: true)
                            .monospacedDigit().multilineTextAlignment(.trailing)
                            .frame(maxWidth: 75, alignment: .trailing)
                    }.accessibilityElement(children: .combine)
                } else if snapshot.isUnlimited {
                    Text("持续运行").foregroundStyle(.secondary)
                } else if snapshot.isWaitingForCapture {
                    Text("等待屏幕共享").foregroundStyle(.secondary)
                } else {
                    Text(snapshot.state.updatedAt, style: .time).monospacedDigit().foregroundStyle(.secondary)
                }
            }.font(.caption2)
            if let interval = snapshot.timerInterval {
                // Persisted authorization time, not an invented task-completion percentage.
                ProgressView(timerInterval: interval, countsDown: false)
                    .progressViewStyle(.linear).labelsHidden().tint(snapshot.accent)
                    .frame(height: 3).accessibilityLabel("本次执行时间")
            }
        }
    }
}

private struct PilotActivitySteps: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let steps: Int
    var body: some View {
        Text("已执行 \(steps) 步").font(.caption2).foregroundStyle(.secondary)
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .contentTransition(reduceMotion || isLuminanceReduced ? .identity : .numericText())
            .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.3), value: steps)
    }
}

/// Brand stays stable; a short arc transition marks actual phase/step changes.
/// No timer, repeatForever, or claim of animation while the system is idle.
private struct PilotActivityPresence: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let snapshot: PilotActivitySnapshot
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().trim(from: 0.02, to: 0.3)
                .stroke(snapshot.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(snapshot.orbitAngle))
                .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.45), value: snapshot.orbitAngle)
            Image("BrandMark").resizable().scaledToFit().padding(size * 0.14)
        }
        .frame(width: size, height: size).accessibilityElement(children: .ignore)
    }
}

private struct PilotActivitySymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let snapshot: PilotActivitySnapshot
    private var image: some View {
        Image(systemName: snapshot.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(snapshot.accent)
    }
    var body: some View {
        Group {
            if reduceMotion || isLuminanceReduced { image }
            else {
                image.symbolEffect(.pulse, options: .nonRepeating.speed(1.5), value: snapshot.eventID)
                    .contentTransition(.symbolEffect(.replace))
            }
        }.accessibilityHidden(true)
    }
}
