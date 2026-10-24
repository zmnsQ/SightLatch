import Foundation

// Deterministic ActivityKit doubles. The publisher and ContentState below are
// extracted verbatim by the runner; no replacement delivery policy is tested.
struct PilotStatus {
    var phase: String; var detail: String; var steps: Int
    var updatedAt = Date(); var sessionID: String; var userMessage: String? = nil
}
struct SessionCommand {
    struct Execution {
        enum Phase { case awaitingCapture, startingHardware, active }
        var phase: Phase; var startedAt: Date?; var expiresAt: Date?; var isUnlimited = false
    }
    var id: String; var generation = 0; var running = true; var execution: Execution?
    var executionStartedAt: Date? { execution?.startedAt }
}
struct LocalizedStringResource: ExpressibleByStringLiteral {
    let value: String
    init(stringLiteral value: String) { self.value = value }
}
struct AlertConfiguration {
    enum Sound { case `default` }
    var title: LocalizedStringResource; var body: LocalizedStringResource; var sound: Sound
}
struct ActivityContent {
    var state: PilotActivityAttributes.ContentState
    var staleDate: Date?
    var relevanceScore: Double = 0
}
enum ActivityUIDismissalPolicy { case after(Date) }
private enum ActivityRegistry { static var values: [AnyObject] = [] }
final class Activity<A> {
    static var activities: [Activity<A>] { ActivityRegistry.values.compactMap { $0 as? Activity<A> } }
    let attributes: PilotActivityAttributes
    var updates: [ActivityContent] = []; var alerts: [AlertConfiguration] = []; var ends = 0
    init(sessionID: String) { attributes = .init(sessionID: sessionID); ActivityRegistry.values.append(self) }
    func update(_ content: ActivityContent, alertConfiguration: AlertConfiguration?, timestamp: Date) async {
        updates.append(content); if let alertConfiguration { alerts.append(alertConfiguration) }
    }
    func end(_ content: ActivityContent?, dismissalPolicy: ActivityUIDismissalPolicy, timestamp: Date) async { ends += 1 }
}
final class SharedStore {
    static let shared = SharedStore()
    var command: SessionCommand?
    var status = PilotStatus(phase: "待机", detail: "", steps: 0, sessionID: "")
    var claims = Set<String>()
    var diagnostics: [String: Data] = [:]
    func claimActivityAlert(sessionID: String, key: String) -> Bool { claims.insert(sessionID + ":" + key).inserted }
    func write<T: Encodable>(_ value: T, to name: String) throws { diagnostics[name] = try JSONEncoder().encode(value) }
}

@main
struct PublisherTests {
    static func main() async {
        let store = SharedStore.shared
        let publisher = PilotActivityPublisher()
        let start = Date(timeIntervalSince1970: 1000)
        store.command = SessionCommand(id: "live", execution: .init(phase: .active, startedAt: start, expiresAt: start.addingTimeInterval(1800)))
        let activity = Activity<PilotActivityAttributes>(sessionID: "live")
        for (i, phase) in ["观察", "规划", "执行", "观察"].enumerated() {
            let status = PilotStatus(phase: phase, detail: "", steps: i / 3, updatedAt: start.addingTimeInterval(Double(i)), sessionID: "live")
            await publisher.publish(status)
        }
        precondition(activity.updates.map { $0.state.phase } == ["观察", "规划", "执行", "观察"], "Real phase changes must not be merged by a five-second throttle")
        let latest = PilotStatus(phase: "观察", detail: "", steps: 1, updatedAt: start.addingTimeInterval(3), sessionID: "live")
        await publisher.publish(latest)
        precondition(activity.updates.count == 4, "Polling the same snapshot must not animate or notify again")
        precondition(activity.updates.last!.state.executionExpiresAt == start.addingTimeInterval(1800))
        var help = PilotStatus(phase: "暂停", detail: "当前目标需要确认", steps: 1, updatedAt: start.addingTimeInterval(4), sessionID: "live", userMessage: "请确认当前聊天；token=secret-value 不会使用")
        await publisher.publish(help)
        precondition(activity.alerts.count == 1 && activity.ends == 0, "A needs-input alert must remain available to open")
        let body = activity.alerts[0].body.value
        precondition(body.contains("请确认当前聊天") && !body.contains("secret-value"), "Show the explicit AI short message, with secret redaction")
        help.updatedAt = start.addingTimeInterval(5)
        await publisher.publish(help)
        precondition(activity.alerts.count == 1, "Same essential event can alert once across status refreshes")
        var stale = help; stale.updatedAt = start
        await publisher.publish(stale)
        precondition(activity.updates.last!.state.updatedAt == help.updatedAt)
        store.command!.running = false
        var revoked = latest; revoked.updatedAt = start.addingTimeInterval(6)
        await publisher.publish(revoked, running: true)
        precondition(activity.updates.last!.state.running == false && activity.updates.last!.state.phase == "停止", "A stale caller's true cannot revive a revoked command")
        precondition(activity.ends == 0, "Do not make a delayed STOP failure impossible to publish")
        let completed = PilotStatus(phase: "完成", detail: "", steps: 1, updatedAt: start.addingTimeInterval(7), sessionID: "live")
        await publisher.publish(completed, running: false)
        let failedStop = PilotStatus(phase: "请核实硬件停止", detail: "设备停止尚未确认", steps: 1, updatedAt: start.addingTimeInterval(8), sessionID: "live")
        await publisher.publish(failedStop, running: false)
        precondition(activity.updates.last!.state.phase == "请核实硬件停止" && activity.alerts.last!.body.value.contains("停止"),
                     "A failed hardware cleanup after task completion must replace the completion surface")

        store.command = SessionCommand(id: "extension", execution: .init(phase: .active, startedAt: start, expiresAt: nil, isUnlimited: true))
        let pending = PilotStatus(phase: "暂停", detail: "网络需要检查", steps: 0, updatedAt: start, sessionID: "extension")
        await publisher.publish(pending)
        let noMatch = try! JSONDecoder().decode(PilotActivityDeliveryDiagnostic.self, from: store.diagnostics.values.first { data in
            (try? JSONDecoder().decode(PilotActivityDeliveryDiagnostic.self, from: data).sessionID) == "extension"
        }!)
        precondition(noMatch.matchedActivities == 0 && !noMatch.submitted && !noMatch.alertRequested)
        let restored = Activity<PilotActivityAttributes>(sessionID: "extension")
        await publisher.publish(pending)
        precondition(restored.alerts.count == 1, "No extension match must not consume the essential alert claim")
        let unlimited = PilotActivityPublisher.state(PilotStatus(phase: "观察", detail: "", steps: 1, sessionID: "extension"), command: store.command, running: true)
        precondition(unlimited.isUnlimited == true && unlimited.executionStartedAt == start && unlimited.executionExpiresAt == nil)
        store.command!.execution!.phase = .awaitingCapture
        let preparing = PilotActivityPublisher.state(PilotStatus(phase: "观察", detail: "", steps: 0, sessionID: "extension"), command: store.command, running: true)
        precondition(preparing.phase == "待广播" && preparing.executionStartedAt == nil && preparing.executionExpiresAt == nil && preparing.isUnlimited == false)
        store.command!.execution!.phase = .active
        store.status = pending
        await publisher.finishAfterHardwareStop(sessionID: "extension")
        precondition(restored.ends == 0, "Verified STOP must preserve an AI request that still needs to be read")
        store.status = PilotStatus(phase: "完成", detail: "", steps: 1, updatedAt: start.addingTimeInterval(10), sessionID: "extension")
        await publisher.finishAfterHardwareStop(sessionID: "extension")
        precondition(restored.ends == 1 && restored.updates.last!.state.phase == "完成")
        precondition(restored.alerts.count == 2, "Completion alert is requested before the verified terminal activity ends")
        print("PASS: actual activity publisher phase delivery, duplicate/alert dedup, explicit redacted AI message, revoked authority, zero-match diagnostics, finite/unlimited preparation clocks")
    }
}
