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
            let stage = PilotActivityStage(phase: context.state.phase)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: stage.symbol).font(.title2).foregroundStyle(tint(stage))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SightLatch · \(stage.title)").font(.headline).lineLimit(1)
                        Text("已执行 \(context.state.steps) 步").font(.subheadline.monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }
                Text(context.isStale ? "进度暂未更新，打开聊天核实。" : stage.summary)
                    .font(.caption).lineLimit(2)
                HStack {
                    Text(context.state.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    controls(stage: stage)
                }
            }
            .padding().activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white).foregroundStyle(.white)
            .widgetURL(chatURL)
        } dynamicIsland: { context in
            let stage = PilotActivityStage(phase: context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("SightLatch", systemImage: stage.symbol).foregroundStyle(tint(stage)).font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.steps) 步").font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) { Text(stage.title).font(.caption).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.isStale ? "进度暂未更新，打开聊天核实。" : stage.summary).font(.caption).lineLimit(2)
                        HStack {
                            Link("打开聊天", destination: chatURL)
                            Spacer()
                            controls(stage: stage)
                        }.font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "clock.badge.exclamationmark" : stage.symbol).foregroundStyle(tint(stage))
                    .accessibilityLabel(context.isStale ? "进度已过期" : stage.title)
            } compactTrailing: {
                Text(context.isStale ? "?" : "\(context.state.steps)").monospacedDigit()
                    .accessibilityLabel("\(stage.title)，已执行 \(context.state.steps) 步")
            } minimal: {
                Image(systemName: context.isStale ? "clock.badge.exclamationmark" : stage.symbol).foregroundStyle(tint(stage))
                    .accessibilityLabel(context.isStale ? "进度已过期" : stage.title)
            }
            .widgetURL(chatURL).keylineTint(tint(stage))
        }
    }
    @ViewBuilder
    private func controls(stage: PilotActivityStage) -> some View {
        if !stage.isTerminal {
            Button(intent: RefreshPilotStatusIntent()) { Label("刷新", systemImage: "arrow.clockwise") }
            Button(intent: StopPilotSessionIntent()) { Label("停止", systemImage: "stop.fill") }.tint(.red)
        }
    }
    private func tint(_ stage: PilotActivityStage) -> Color {
        switch stage {
        case .failed: return .red
        case .needsInput: return .orange
        case .completed: return .green
        case .stopped: return .gray
        default: return .teal
        }
    }
}
