import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct PilotWidgetBundle: WidgetBundle {
    var body: some Widget { PilotLiveActivity() }
}

struct PilotLiveActivity: Widget {
    // Canvas fixtures keep production appearance but cannot invoke intents or links.
    var previewOnly = false
    private let chatURL = URL(string: "sightlatch://chat")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PilotActivityAttributes.self) { context in
            let snapshot = PilotActivitySnapshot(context)
            VStack(alignment: .leading, spacing: snapshot.hasClarification ? 6 : 10) {
                HStack(spacing: 10) {
                    PilotActivityStateSymbol(snapshot: snapshot, size: 22)
                        .accessibilityHidden(true)
                    PilotActivityPhase(snapshot: snapshot)
                    Spacer(minLength: 8)
                    if snapshot.hasClarification && snapshot.canStop {
                        PilotActivityStopButton(compact: true)
                    } else {
                        Text("SightLatch").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                PilotActivityMessage(snapshot: snapshot)
                if snapshot.hasClarification {
                    PilotActivityChoices(snapshot: snapshot)
                } else {
                    HStack(spacing: 12) {
                        PilotActivityMetrics(snapshot: snapshot)
                        Spacer(minLength: 0)
                        if snapshot.canStop { PilotActivityStopButton() }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, snapshot.hasClarification ? 10 : 12)
            .activityBackgroundTint(nil)
            .allowsHitTesting(!previewOnly)
            .widgetURL(previewOnly ? nil : chatURL)
        } dynamicIsland: { context in
            let snapshot = PilotActivitySnapshot(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    HStack(spacing: 8) {
                        PilotActivityStateSymbol(snapshot: snapshot, size: 19)
                            .accessibilityHidden(true)
                        PilotActivityPhase(snapshot: snapshot)
                    }.foregroundStyle(.white).frame(height: 32)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if snapshot.hasClarification && snapshot.canStop {
                            PilotActivityStopButton(compact: true).allowsHitTesting(!previewOnly)
                        } else {
                            PilotActivityTimeValue(snapshot: snapshot)
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                        }
                    }.frame(height: 32)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        PilotActivityMessage(snapshot: snapshot, inIsland: true).foregroundStyle(.white)
                        if snapshot.hasClarification {
                            PilotActivityChoices(snapshot: snapshot).allowsHitTesting(!previewOnly)
                        } else {
                            HStack(spacing: 12) {
                                PilotActivitySteps(steps: snapshot.steps)
                                Spacer(minLength: 0)
                                if snapshot.canStop { PilotActivityStopButton().allowsHitTesting(!previewOnly) }
                            }
                        }
                    }
                }
            } compactLeading: {
                PilotActivityStateSymbol(snapshot: snapshot, size: 18)
                    .accessibilityLabel(snapshot.accessibilitySummary)
            } compactTrailing: {
                Text(snapshot.compactTitle).font(.caption2.weight(.semibold))
                    .foregroundStyle(snapshot.stage.needsAttention ? snapshot.accent : .white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel(snapshot.accessibilitySummary)
            } minimal: {
                PilotActivityStateSymbol(snapshot: snapshot, size: 20)
                    .accessibilityLabel(snapshot.accessibilitySummary)
            }
            .widgetURL(previewOnly ? nil : chatURL).keylineTint(snapshot.accent)
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
    var clarificationOptions: [PilotClarificationAction] {
        guard running, !stage.isTerminal,
              let questionID = state.clarificationID, !questionID.isEmpty,
              let options = state.clarificationOptions, (1...3).contains(options.count),
              options.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(options.map(\.id)).count == options.count else { return [] }
        return options
    }
    var hasClarification: Bool { !clarificationOptions.isEmpty }
    var choicesNeedFullView: Bool {
        let labelLimit = clarificationOptions.count == 3 ? 14 : clarificationOptions.count == 2 ? 22 : 40
        return clarificationOptions.contains { $0.title.count > labelLimit }
    }
    var stageTitle: String { hasClarification ? "等你选择" : staleWhileExecuting ? "等待状态更新" : stage.title }
    var symbol: String { hasClarification ? "questionmark.bubble" : staleWhileExecuting ? "clock.badge.exclamationmark" : stage.symbol }
    var compactTitle: String {
        if hasClarification { return "待选择" }
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
        if hasClarification { return .blue }
        if staleWhileExecuting { return .orange }
        switch stage {
        case .failed: return .red
        case .needsInput: return .orange
        case .completed: return .green
        case .stopped: return .secondary
        default: return .blue
        }
    }
    var notice: PilotActivityNotice? { state.noticeCode.flatMap(PilotActivityNotice.init(rawValue:)) }
    var actionSummary: String {
        if hasClarification {
            return PilotActivitySummary.userMessage(state.noticeMessage) ?? "选择一个选项，继续当前任务。"
        }
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
    var accessibilitySummary: String {
        if hasClarification { return "SightLatch，等待你的选择，展开实时活动或回到 App 回答" }
        if stage.needsAttention { return "SightLatch，\(stageTitle)，打开 App 查看详情" }
        return "SightLatch，\(stageTitle)，已执行 \(steps) 步，\(actionSummary)"
    }
}

private struct PilotActivityMessage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: PilotActivitySnapshot
    var inIsland = false
    var body: some View {
        // The fixed system surface cannot hold a large-type question and all
        // choices. Its explicit App link below provides the complete content.
        if !snapshot.hasClarification || !dynamicTypeSize.isAccessibilitySize {
            Text(snapshot.actionSummary)
                .font((inIsland ? Font.caption : .subheadline).weight(snapshot.stage.needsAttention ? .medium : .regular))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive(snapshot.hasClarification || snapshot.stage.needsAttention)
                .id(snapshot.actionSummary)
                .transition(.opacity)
                .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.22), value: snapshot.actionSummary)
        }
    }
}

/// Choices are the current runtime's opaque IDs, never inferred from message text.
private struct PilotActivityChoices: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: PilotActivitySnapshot
    var body: some View {
        if let questionID = snapshot.state.clarificationID, snapshot.hasClarification {
            if dynamicTypeSize.isAccessibilitySize || snapshot.choicesNeedFullView {
                Link(destination: URL(string: "sightlatch://chat")!) {
                    Label("在 App 回答", systemImage: "arrow.up.forward")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .modifier(PilotActivityChoiceSurface())
                }
                .buttonStyle(.plain)
                .accessibilityHint("在 App 查看完整问题和选项")
            } else {
                HStack(spacing: 8) {
                    ForEach(snapshot.clarificationOptions) { option in
                        Button(intent: AnswerPilotClarificationIntent(sessionID: snapshot.attributes.sessionID,
                            questionID: questionID, optionID: option.id)) {
                            Text(option.title).font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center).lineLimit(2)
                                .modifier(PilotActivityChoiceSurface())
                                .privacySensitive()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("回答当前问题，再读取新画面继续")
                    }
                }
            }
        }
    }
}

/// Forty-four points is the entire button, including its background. Native
/// bordered padding must not silently add height inside the constrained island.
private struct PilotActivityChoiceSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(.blue)
            .background(Color.blue.opacity(0.17), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
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
            .transition(.opacity)
            .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.22), value: snapshot.stageTitle)
    }
}

private struct PilotActivityMetrics: View {
    let snapshot: PilotActivitySnapshot
    var body: some View {
        HStack(spacing: 8) {
            PilotActivitySteps(steps: snapshot.steps)
            if snapshot.timerInterval != nil || snapshot.isUnlimited {
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                PilotActivityTimeValue(snapshot: snapshot).foregroundStyle(.secondary)
            }
        }.font(.caption2).accessibilityElement(children: .combine)
    }
}

private struct PilotActivityTimeValue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let snapshot: PilotActivitySnapshot
    var body: some View {
        if let interval = snapshot.timerInterval {
            Text(timerInterval: interval, countsDown: true, showsHours: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
                .frame(maxWidth: 78, alignment: .trailing)
                .contentTransition(reduceMotion || isLuminanceReduced ? .identity : .numericText(countsDown: true))
                .accessibilityLabel("剩余执行时间")
                .accessibilityValue(Text(timerInterval: interval, countsDown: true, showsHours: true))
        } else if snapshot.isUnlimited {
            Label("不限时", systemImage: "infinity").labelStyle(.titleOnly)
        } else {
            EmptyView()
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
            .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.22), value: steps)
    }
}

private struct PilotActivityStopButton: View {
    var compact = false
    var body: some View {
        Button(intent: StopPilotSessionIntent()) {
            Label("停止", systemImage: "stop.fill")
                .font(.caption.weight(.medium))
                .frame(minWidth: 54, minHeight: compact ? 32 : 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).tint(.red).foregroundStyle(.red)
        .accessibilityLabel("停止 SightLatch 会话")
    }
}

/// Use a presentation-sized system symbol instead of archiving a 1024px raster
/// into the minimal island. Only real symbol changes receive a short transition.
private struct PilotActivityStateSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let snapshot: PilotActivitySnapshot
    let size: CGFloat
    var body: some View {
        Image(systemName: snapshot.symbol)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(snapshot.accent)
            .frame(width: size + 2, height: size + 2)
            .contentTransition(reduceMotion || isLuminanceReduced ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.22), value: snapshot.symbol)
            .accessibilityElement(children: .ignore)
    }
}


#if DEBUG
/// Synthetic Canvas-only data. Dates are anchored once per preview load so the
/// countdown remains useful; no store, activity request or hardware is involved.
private enum PilotActivityPreviewData {
    static let now = Date()
    static let attributes = PilotActivityAttributes(
        sessionID: "canvas-preview-only",
        taskSummary: "微信操作任务"
    )
    static let executing = PilotActivityAttributes.ContentState(
        phase: "执行", steps: 4, updatedAt: now,
        actionSummary: "定位并点击当前目标",
        executionStartedAt: now.addingTimeInterval(-80),
        executionExpiresAt: now.addingTimeInterval(220),
        eventID: "canvas-executing", running: true
    )
    static let twoChoices = PilotActivityAttributes.ContentState(
        phase: "等待确认", steps: 3, updatedAt: now,
        executionStartedAt: now.addingTimeInterval(-90),
        executionExpiresAt: now.addingTimeInterval(210),
        eventID: "canvas-two-choices", noticeCode: "recipient", running: true,
        noticeMessage: "找到两位叫“林小北”的示例联系人，你想打开哪一个聊天？",
        clarificationID: "canvas-question-two",
        clarificationOptions: [
            .init(id: "canvas-work", title: "林小北 · 工作"),
            .init(id: "canvas-family", title: "林小北 · 家人")
        ]
    )
    static let threeChoices = PilotActivityAttributes.ContentState(
        phase: "等待确认", steps: 6, updatedAt: now,
        executionStartedAt: now.addingTimeInterval(-120),
        executionExpiresAt: now.addingTimeInterval(180),
        eventID: "canvas-three-choices", noticeCode: "recipient", running: true,
        noticeMessage: "这三位示例联系人的名字相近。请选择你要打开的聊天；也可以回到 App 补充说明。",
        clarificationID: "canvas-question-three",
        clarificationOptions: [
            .init(id: "canvas-team-a", title: "小北 · 产品设计团队"),
            .init(id: "canvas-team-b", title: "小北 · 城市摄影小组"),
            .init(id: "canvas-team-c", title: "小北 · 周末读书计划")
        ]
    )
}

#Preview("锁屏 · 普通执行", as: .content, using: PilotActivityPreviewData.attributes) {
    PilotLiveActivity(previewOnly: true)
} contentStates: {
    PilotActivityPreviewData.executing
}

#Preview("展开 · 两个选项", as: .dynamicIsland(.expanded), using: PilotActivityPreviewData.attributes) {
    PilotLiveActivity(previewOnly: true)
} contentStates: {
    PilotActivityPreviewData.twoChoices
}

#Preview("展开 · 三个长标题", as: .dynamicIsland(.expanded), using: PilotActivityPreviewData.attributes) {
    PilotLiveActivity(previewOnly: true)
} contentStates: {
    PilotActivityPreviewData.threeChoices
}

#Preview("锁屏 · 澄清问题", as: .content, using: PilotActivityPreviewData.attributes) {
    PilotLiveActivity(previewOnly: true)
} contentStates: {
    PilotActivityPreviewData.twoChoices
    PilotActivityPreviewData.threeChoices
}

#Preview("紧凑 · 执行与选择", as: .dynamicIsland(.compact), using: PilotActivityPreviewData.attributes) {
    PilotLiveActivity(previewOnly: true)
} contentStates: {
    PilotActivityPreviewData.executing
    PilotActivityPreviewData.twoChoices
}

#Preview("最小 · 执行与选择", as: .dynamicIsland(.minimal), using: PilotActivityPreviewData.attributes) {
    PilotLiveActivity(previewOnly: true)
} contentStates: {
    PilotActivityPreviewData.executing
    PilotActivityPreviewData.twoChoices
}
#endif
