import Foundation
import FoundationNetworking

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
        let id = state.begin(goal: "search", configurationID: config)!
        precondition(state.begin(goal: "duplicate", configurationID: config) == nil)
        precondition(!state.consumePermission(goal: "search"))
        precondition(!state.authorize(requestID: id, goal: "search", configurationID: config))
        state.cancel(); state.receive("late response", requestID: id)
        precondition(state.phase == .cancelled && state.plan == nil)
        let newID = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: newID, now: now)
        precondition(!state.authorize(requestID: id, goal: "search", configurationID: config))
        precondition(!state.authorize(requestID: newID, goal: "different", configurationID: config))
        let third = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: third, now: now)
        precondition(!state.authorize(requestID: third, goal: "search", configurationID: config, now: now.addingTimeInterval(121)))
        let fourth = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: fourth)
        precondition(!state.authorize(requestID: fourth, goal: "search", configurationID: Data("changed endpoint".utf8)))
        let fifth = state.begin(goal: "search", configurationID: config)!
        state.receive("plan", requestID: fifth)
        var hardwareCalls = 0
        if state.consumePermission(goal: "search") { hardwareCalls += 1 }
        precondition(hardwareCalls == 0)
        precondition(state.authorize(requestID: fifth, goal: "search", configurationID: config))
        if state.consumePermission(goal: "search") { hardwareCalls += 1 }
        if state.consumePermission(goal: "search") { hardwareCalls += 1 }
        precondition(hardwareCalls == 1)
        state.bindSession("session"); state.observe(sessionID: "stale", phase: "完成", running: false)
        precondition(state.phase == .ready)
        state.observe(sessionID: "session", phase: "观察", running: true); precondition(state.phase == .running)
        state.observe(sessionID: "session", phase: "完成", running: false); precondition(state.phase == .completed)
        var c = PilotConfiguration()
        for consent in [false, true] {
            c.textPlanningConsent = consent
            do { _ = try await AIClient(configuration: c).planGoal("test"); fatalError("Unconfigured model accepted") } catch {}
        }
        precondition(Transport.shared.requests.isEmpty)
        c.model = "mock"; c.textPlanningConsent = true
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
        print("PASS: goal-bound one-shot permissions, expiry, changed config, duplicate send, cancelled late response, session binding, 4 text-only provider payloads and completion guards, ChatGPT text route; zero real network/HID calls")
    }
}
