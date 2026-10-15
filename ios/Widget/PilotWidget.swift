import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct PilotWidgetBundle: WidgetBundle {
    var body: some Widget { PilotLiveActivity() }
}
struct PilotLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PilotActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.motionlines").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("HIDPilot · \(context.state.phase)").font(.headline)
                    Text("\(context.state.steps) 步 · 最后更新 \(context.state.updatedAt.formatted(date: .omitted, time: .standard))").font(.caption)
                    Text(context.isStale ? "状态已过期，点刷新读取最新快照" : "状态可能延迟；物理急停始终优先").font(.caption2)
                    HStack {
                        Button(intent: RefreshPilotStatusIntent()) { Label("刷新", systemImage: "arrow.clockwise") }
                        Button(intent: StopPilotSessionIntent()) { Label("停止", systemImage: "stop.fill") }.tint(.red)
                    }.buttonStyle(.bordered).font(.caption)
                }
                Spacer()
            }.padding().activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("HIDPilot", systemImage: "cursorarrow.motionlines") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.steps) 步") }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text(context.isStale ? "状态可能过期" : context.state.phase)
                        HStack {
                            Button(intent: RefreshPilotStatusIntent()) { Label("刷新", systemImage: "arrow.clockwise") }
                            Button(intent: StopPilotSessionIntent()) { Label("停止", systemImage: "stop.fill") }.tint(.red)
                        }.buttonStyle(.bordered).font(.caption)
                    }
                }
            } compactLeading: { Image(systemName: "cursorarrow.motionlines") }
              compactTrailing: { Text(context.isStale ? "?" : "\(context.state.steps)") }
              minimal: { Image(systemName: "cursorarrow") }
        }
    }
}
