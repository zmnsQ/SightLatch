import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SecretStore { static func load(_ account: String) throws -> String { "fake-key" } }
enum AddressPolicy { static func ai(_ value: String) throws -> URL { URL(string: value)! } }
final class Transport {
    static let shared = Transport()
    var response = Data(); var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> Data { requests.append(request); return response }
}
actor ChatGPTPlanClient {
    static let shared = ChatGPTPlanClient()
    func textResponse(model: String, instructions: String, task: String) async throws -> String { "基于目标的模拟服务响应，尚未查看屏幕。" }
}
struct AIClient { let configuration: PilotConfiguration }
@main struct Tests {
    static func main() async throws {
        var state = TaskPlanningState()
        let config = Data("config".utf8), now = Date()
        var direct = TaskPlanningState()
        let directID = direct.explicitGoalStart(goal: "search", configurationID: config, now: now)!
        precondition(direct.phase == .ready && direct.plan == nil && direct.isExplicitGoalStart)
        precondition(direct.explicitGoalStart(goal: "duplicate", configurationID: config) == nil)
        precondition(direct.consumePermission(goal: "search", configurationID: config, now: now))
        precondition(!direct.consumePermission(goal: "search", configurationID: config, now: now))
        direct.bindSession("direct-session")
        direct.observe(sessionID: "direct-session", phase: "停止", running: false)
        direct.recoverCaptureStartupFailure(sessionID: "direct-session", detail: "capture failed")
        precondition(direct.phase == .prerequisites && direct.requestID == directID && direct.plan == nil)
        let repaired = Data("repaired config".utf8)
        precondition(!direct.continueExplicitGoalStart(requestID: directID, goal: "other", configurationID: repaired))
        precondition(direct.continueExplicitGoalStart(requestID: directID, goal: "search", configurationID: repaired, now: now))
        precondition(direct.consumePermission(goal: "search", configurationID: repaired, now: now))
        direct.require([.init(kind: .calibration, title: "Calibration", detail: "Required", actionTitle: "Calibrate")])
        precondition(!direct.isBusy && !direct.consumePermission(goal: "search", configurationID: repaired))
        precondition(direct.continueExplicitGoalStart(requestID: directID, goal: "search", configurationID: repaired, now: now))
        precondition(!direct.consumePermission(goal: "search", configurationID: repaired, now: now.addingTimeInterval(121)))
        direct.cancel()
        precondition(!direct.continueExplicitGoalStart(requestID: directID, goal: "search", configurationID: repaired))
        direct.recoverCaptureStartupFailure(sessionID: "direct-session", detail: "late")
        precondition(direct.phase == .cancelled && direct.requestID == nil)
        let id = state.begin(goal: "search", configurationID: config)!
        precondition(state.begin(goal: "duplicate", configurationID: config) == nil)
        precondition(!state.consumePermission(goal: "search", configurationID: config))
        precondition(!state.authorize(requestID: id, goal: "search", configurationID: config))
        state.cancel(); state.receive("late response", requestID: id)
        precondition(state.phase == .cancelled && state.plan == nil)
        let newID = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: newID, now: now)
        precondition(!state.authorize(requestID: id, goal: "search", configurationID: config))
        precondition(!state.authorize(requestID: newID, goal: "different", configurationID: config))
        let third = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: third, now: now)
        precondition(state.expiresAt == nil, "Waiting for setup must not have an execution deadline")
        precondition(!state.isBusy, "A waiting text plan must permit independent calibration")
        precondition(state.authorize(requestID: third, goal: "search", configurationID: config, now: now.addingTimeInterval(3600)))
        precondition(state.expiresAt == now.addingTimeInterval(3720))
        precondition(!state.consumePermission(goal: "search", configurationID: config, now: now.addingTimeInterval(3721)))
        precondition(state.phase == .prerequisites && state.plan == "plan" && state.goal == "search")
        state.cancel()
        let fourth = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: fourth)
        precondition(!state.authorize(requestID: fourth, goal: "search", configurationID: Data("changed endpoint".utf8)))
        let fifth = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: fifth)
        var hardwareCalls = 0
        if state.consumePermission(goal: "search", configurationID: config) { hardwareCalls += 1 }
        precondition(hardwareCalls == 0)
        precondition(state.authorize(requestID: fifth, goal: "search", configurationID: config))
        precondition(!state.consumePermission(goal: "search"), "Configuration identity is required to consume a grant")
        if state.consumePermission(goal: "search", configurationID: config) { hardwareCalls += 1 }
        if state.consumePermission(goal: "search", configurationID: config) { hardwareCalls += 1 }
        precondition(hardwareCalls == 1)
        state.bindSession("session"); state.observe(sessionID: "stale", phase: "完成", running: false)
        precondition(state.phase == .ready)
        state.observe(sessionID: "session", phase: "观察", running: true); precondition(state.phase == .running)
        state.observe(sessionID: "session", phase: "完成", running: false); precondition(state.phase == .completed)
        var captureRecovery = TaskPlanningState()
        let captureID = captureRecovery.begin(goal: "search", configurationID: config)!
        captureRecovery.receive("keep capture plan", requestID: captureID)
        precondition(captureRecovery.authorize(requestID: captureID, goal: "search", configurationID: config))
        precondition(captureRecovery.consumePermission(goal: "search", configurationID: config))
        captureRecovery.bindSession("capture-session")
        captureRecovery.observe(sessionID: "capture-session", phase: "停止", running: false)
        precondition(captureRecovery.phase == .cancelled)
        captureRecovery.recoverCaptureStartupFailure(sessionID: "stale", detail: "wrong failure")
        precondition(captureRecovery.phase == .cancelled)
        captureRecovery.recoverCaptureStartupFailure(sessionID: "capture-session", detail: "capture startup failed")
        precondition(captureRecovery.phase == .prerequisites && captureRecovery.requestID == captureID)
        precondition(captureRecovery.plan == "keep capture plan" && captureRecovery.goal == "search")
        precondition(captureRecovery.prerequisites.first?.title == "屏幕捕获尚未开始")
        precondition(!captureRecovery.consumePermission(goal: "search", configurationID: config))
        captureRecovery.cancel()
        captureRecovery.recoverCaptureStartupFailure(sessionID: "capture-session", detail: "late failure")
        precondition(captureRecovery.phase == .cancelled && captureRecovery.requestID == nil)
        var recovery = TaskPlanningState()
        let recoveryID = recovery.begin(goal: "search", configurationID: config)!
        recovery.receive("retained plan", requestID: recoveryID)
        let calibration = TaskPrerequisite(kind: .calibration, title: "Calibration", detail: "Measure pointer", actionTitle: "Calibrate")
        recovery.require([calibration], requestID: recoveryID)
        precondition(recovery.phase == .prerequisites && !recovery.isBusy && recovery.requestID == recoveryID)
        precondition(recovery.plan == "retained plan" && recovery.goal == "search" && recovery.expiresAt == nil)
        precondition(!recovery.authorize(requestID: recoveryID, goal: "search", configurationID: config))
        precondition(!recovery.consumePermission(goal: "search", configurationID: config))
        precondition(recovery.preparationSatisfied(requestID: recoveryID, goal: "search", configurationID: config))
        precondition(recovery.phase == .awaitingPermission && recovery.prerequisites.isEmpty)
        precondition(!recovery.consumePermission(goal: "search", configurationID: config), "Rechecking is not authorization")
        precondition(recovery.authorize(requestID: recoveryID, goal: "search", configurationID: config))
        precondition(!recovery.consumePermission(goal: "search", configurationID: Data("changed endpoint".utf8)))
        precondition(recovery.phase == .error && recovery.plan == "retained plan")
        recovery.cancel()
        recovery.require([calibration], requestID: recoveryID)
        precondition(recovery.phase == .cancelled && recovery.prerequisites.isEmpty)
        precondition(!recovery.preparationSatisfied(requestID: recoveryID, goal: "search", configurationID: config))
        var networkRecovery = TaskPlanningState()
        let networkID = networkRecovery.begin(goal: "search", configurationID: config)!
        networkRecovery.receive("keep this plan", requestID: networkID)
        precondition(networkRecovery.authorize(requestID: networkID, goal: "search", configurationID: config))
        precondition(networkRecovery.consumePermission(goal: "search", configurationID: config))
        networkRecovery.require([.init(kind: .deviceConnection, title: "Connection", detail: "Timed out", actionTitle: "Check device")], requestID: networkID)
        precondition(networkRecovery.plan == "keep this plan" && networkRecovery.requestID == networkID)
        precondition(!networkRecovery.consumePermission(goal: "search", configurationID: config))
        precondition(networkRecovery.preparationSatisfied(requestID: networkID, goal: "search", configurationID: config))
        precondition(!networkRecovery.consumePermission(goal: "search", configurationID: config))
        precondition(networkRecovery.authorize(requestID: networkID, goal: "search", configurationID: config))
        precondition(networkRecovery.consumePermission(goal: "search", configurationID: config))
        precondition(!networkRecovery.consumePermission(goal: "search", configurationID: config))
        var changed = TaskPlanningState()
        let changedID = changed.begin(goal: "search", configurationID: config)!
        changed.receive("retained", requestID: changedID)
        changed.require([calibration])
        precondition(!changed.preparationSatisfied(requestID: changedID, goal: "other", configurationID: config))
        precondition(changed.phase == .error)
        var originalConfiguration = PilotConfiguration()
        originalConfiguration.model = "mock"
        let originalIdentity = TaskPlanningConfiguration.identity(originalConfiguration)
        var measured = originalConfiguration
        measured.relativeModeConfirmed = true; measured.calibratedAt = now
        measured.calibrationX = 275; measured.calibrationY = 300; measured.orientation = "landscape"
        measured.uploadConsent = true
        measured.automaticCalibrationProfile = PointerCalibrationProfile(context: .init(deviceURL: measured.deviceURL, phoneModel: "phone", orientation: "landscape", pixelWidth: 2000, pixelHeight: 1000, scale: 3), pixelsPer100X: 275, pixelsPer100Y: 300, verifiedAt: now)
        precondition(TaskPlanningConfiguration.identity(measured) == originalIdentity, "Only readiness/calibration changed")
        for field in ["provider", "endpoint", "model", "device", "steps", "navigation"] {
            var changedConfiguration = originalConfiguration
            switch field {
            case "provider": changedConfiguration.provider = "anthropic"
            case "endpoint": changedConfiguration.endpoint = "https://example.com/responses"
            case "model": changedConfiguration.model = "other"
            case "device": changedConfiguration.deviceURL = "http://192.168.1.4"
            case "steps": changedConfiguration.maxSteps += 1
            default: changedConfiguration.allowLowRiskNavigation = true
            }
            precondition(TaskPlanningConfiguration.identity(changedConfiguration) != originalIdentity)
        }
        var c = PilotConfiguration()
        for consent in [false, true] {
            c.textPlanningConsent = consent
            do { _ = try await AIClient(configuration: c).planGoal("test"); fatalError("Unconfigured model accepted") } catch {}
        }
        precondition(Transport.shared.requests.isEmpty)
        c.model = "mock"; c.textPlanningConsent = false // Legacy settings must not block explicit Send.
        for provider in ["responses", "openai", "anthropic", "gemini"] {
            c.provider = provider
            for complete in [false, true] {
                let body: [String: Any]
                let text = "基于目标的计划；尚未查看屏幕。<script>ARM()</script>"
                switch provider {
                case "responses": body = ["status": complete ? "completed" : "incomplete", "output": [["content": [["type": "output_text", "text": text]]]]]
                case "anthropic": body = ["stop_reason": complete ? "end_turn" : "max_tokens", "content": [["type": "text", "text": text]]]
                case "gemini": body = ["candidates": [["finishReason": complete ? "STOP" : "MAX_TOKENS", "content": ["parts": [["text": text]]]]]]
                default: body = ["choices": [["finish_reason": complete ? "stop" : "length", "message": ["content": text]]]]
                }
                Transport.shared.response = try JSONSerialization.data(withJSONObject: body)
                do { let plan = try await AIClient(configuration: c).planGoal("search"); precondition(complete && plan == text) }
                catch { if complete { throw error } }
                let payload = String(data: Transport.shared.requests.last!.httpBody!, encoding: .utf8)!
                precondition(!payload.contains("image_url") && !payload.contains("input_image") && !payload.contains("inlineData"))
            }
        }
        precondition(hardwareCalls == 1, "Plan/script text must not execute")
        c.provider = "chatgpt-plan"; c.chatGPTPlanConsent = true
        let plan = try await AIClient(configuration: c).planGoal("search"); precondition(!plan.isEmpty)
        print("PASS: goal-bound one-shot permissions, unexpired waiting plans, bounded execution grants, actionable readiness/recovery, changed config, calibration-independent identity, duplicate send, cancelled late response, session binding, 4 text-only provider payloads and completion guards, ChatGPT text route; zero real network/HID calls")
    }
}
