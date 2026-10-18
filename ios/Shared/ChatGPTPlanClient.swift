import Foundation

struct ChatGPTModel: Identifiable, Sendable {
    let id: String
    let displayName: String
}

// A terminal event is mandatory. Partial model text never reaches the hardware planner.
struct ChatGPTSSEAccumulator {
    private(set) var text = ""
    private(set) var completed = false
    private var dataLines: [String] = []
    private var bufferedBytes = 0
    mutating func consume(line: String) throws {
        guard !completed else { return }
        if line.isEmpty {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true); bufferedBytes = 0
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { throw ChatGPTAuthError.message("ChatGPT 事件流格式无效。") }
            switch type {
            case "response.output_text.delta":
                text += object["delta"] as? String ?? ""
                guard text.utf8.count < 8000 else { throw ChatGPTAuthError.message("ChatGPT 动作响应过长。") }
            case "response.completed":
                guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else {
                    throw ChatGPTAuthError.message("ChatGPT 未返回完整完成状态。")
                }
                completed = true
            case "response.failed", "response.incomplete", "error":
                let response = object["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any])
                throw ChatGPTAuthError.message(Self.message(code: error?["code"] as? String ?? object["code"] as? String))
            default: break
            }
        } else if line.hasPrefix("data:") {
            let raw = String(line.dropFirst(5))
            let value = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
            bufferedBytes += value.utf8.count
            guard bufferedBytes < 1_000_000 else { throw ChatGPTAuthError.message("ChatGPT 事件超出大小限制。") }
            dataLines.append(value)
        }
    }
    func result() throws -> String {
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTAuthError.message("ChatGPT 响应中断或没有完成，未执行任何动作。")
        }
        return text
    }
    static func message(code: String?) -> String {
        switch code {
        case "subscription_sharing_user_not_eligible": return "此账户、工作区或地区暂不支持 ChatGPT 套餐调用。"
        case "subscription_sharing_usage_limit_exceeded": return "ChatGPT 套餐或本应用已达额度上限，请到 ChatGPT 设置查看用量；不会自动使用 API Key。"
        case "subscription_sharing_usage_unavailable": return "暂时无法查询 ChatGPT 用量，请稍后重试。"
        default: return "ChatGPT 请求未完成，未执行任何动作。"
        }
    }
}

actor ChatGPTPlanClient {
    static let shared = ChatGPTPlanClient()
    func models() async throws -> [ChatGPTModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(try await ChatGPTOAuth.shared.accessToken())", forHTTPHeaderField: "Authorization")
        let data = try await ChatGPTHTTP.send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { throw ChatGPTAuthError.message("ChatGPT 模型目录格式无效。") }
        return models.compactMap { item in
            guard item["visibility"] as? String == "list", let id = item["slug"] as? String,
                  let name = item["display_name"] as? String else { return nil }
            return ChatGPTModel(id: id, displayName: name)
        }
    }
    func response(model: String, instructions: String, task: String, jpeg: Data) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await ChatGPTOAuth.shared.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instructions,
            "store": false, "stream": true,
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": task],
                ["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "detail": "low"]]]]])
        let (bytes, response) = try await ChatGPTHTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthError.message("ChatGPT 网络响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { if data.count >= 16_384 { break }; data.append(byte) }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = root?["error"] as? [String: Any]
            if let code = error?["code"] as? String { throw ChatGPTAuthError.message(ChatGPTSSEAccumulator.message(code: code)) }
            throw ChatGPTAuthError.message("ChatGPT 请求未获准（HTTP \(http.statusCode)），请检查账户或稍后重试。")
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw ChatGPTAuthError.message("ChatGPT 没有返回所需事件流。")
        }
        var parser = ChatGPTSSEAccumulator()
        // bytes.lines can omit empty lines on some Foundation implementations. Parse bytes explicitly.
        var line = Data(); var total = 0
        for try await byte in bytes {
            try Task.checkCancellation(); total += 1
            guard total <= 2_000_000, line.count <= 1_000_000 else { throw ChatGPTAuthError.message("ChatGPT 事件流超出限制。") }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                guard let string = String(data: line, encoding: .utf8) else { throw ChatGPTAuthError.message("ChatGPT 事件流编码无效。") }
                try parser.consume(line: string); line.removeAll(keepingCapacity: true)
                if parser.completed { return try parser.result() }
            } else { line.append(byte) }
        }
        // EOF without the event delimiter/completed event is deliberately not a success.
        return try parser.result()
    }
}
