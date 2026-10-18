import Foundation
import FoundationNetworking

enum SecretStore { static func load(_ account: String) throws -> String { "fake-key" } }
enum AddressPolicy {
    static func device(_ value: String) throws -> URL { URL(string: value)! }
    static func ai(_ value: String) throws -> URL { URL(string: value)! }
}
final class Transport {
    static let shared = Transport()
    var response = Data()
    var requestBody = Data()
    func send(_ request: URLRequest) async throws -> Data { requestBody = request.httpBody!; return response }
}
actor ChatGPTPlanClient {
    static let shared = ChatGPTPlanClient()
    func response(model: String, instructions: String, task: String, jpeg: Data) async throws -> String { throw CancellationError() }
}
@main struct ModelCompletionTests {
    static func main() async throws {
        let proposal = """
        {"type":"wait","purpose":"navigation","risk":"low","requiresConfirmation":false,"reason":"等待新画面","pointerVisible":false,"highRisk":false,"confidence":1}
        """
        for provider in ["responses", "openai", "anthropic", "gemini"] {
            var configuration = PilotConfiguration()
            configuration.model = "fake-model"; configuration.uploadConsent = true
            configuration.provider = provider; configuration.gatewayVisionConfirmed = true
            for complete in [false, true] {
                let body: [String: Any]
                switch provider {
                case "responses": body = ["status": complete ? "completed" : "incomplete", "output": [["content": [["type": "output_text", "text": proposal]]]]]
                case "anthropic": body = ["stop_reason": complete ? "end_turn" : "max_tokens", "content": [["type": "text", "text": proposal]]]
                case "gemini": body = ["candidates": [["finishReason": complete ? "STOP" : "MAX_TOKENS", "content": ["parts": [["text": proposal]]]]]]
                default: body = ["choices": [["finish_reason": complete ? "stop" : "length", "message": ["content": proposal]]]]
                }
                Transport.shared.response = try JSONSerialization.data(withJSONObject: body)
                do {
                    let result = try await AIClient(configuration: configuration).propose(jpeg: Data(), task: "observe", frameID: "new", context: "TOOL_RESULT_MARKER")
                    precondition(complete && result.type == .wait, "Incomplete response was accepted")
                } catch { if complete { throw error } }
                let sent = String(data: Transport.shared.requestBody, encoding: .utf8)!
                precondition(sent.contains("TOOL_RESULT_MARKER"), "Provider lost session context")
            }
        }
        print("PASS: four provider completion guards and tool-result context; no real API calls")
    }
}
