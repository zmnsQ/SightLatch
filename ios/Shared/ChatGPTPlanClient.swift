import Foundation

struct ChatGPTModel: Identifiable, Sendable {
    let id: String
    let displayName: String
}

enum ChatGPTRequestProfile {
    static func body(model: String, instructions: String, task: String, jpeg: Data?) throws -> Data {
        var content: [[String: Any]] = [["type": "input_text", "text": task]]
        if let jpeg {
            // Preserve the supplied UI pixels for this documented computer-use model.
            // https://developers.openai.com/api/docs/guides/tools-computer-use
            let detail = model == "gpt-6.1-sol" ? "original" : "low"
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "detail": detail])
        }
        var payload: [String: Any] = ["model": model, "instructions": instructions,
            "store": false, "stream": true, "input": [["role": "user", "content": content]]]
        // Explicitly documented support; do not infer capability from a model prefix.
        // https://developers.openai.com/api/docs/models/gpt-6.1-sol
        if jpeg != nil, model == "gpt-6.1-sol" {
            payload["reasoning"] = ["effort": "low"]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

enum ChatGPTResponsePolicy {
    static func acceptsEventStream(_ response: HTTPURLResponse, method: String?) -> Bool {
        guard (200..<300).contains(response.statusCode), method == "POST",
              response.url?.absoluteString == "https://api.openai.com/v1/responses" else { return false }
        // Observed on the physical device: the official SSE response can lack Content-Type.
        // A missing header may enter the parser, which still requires a complete SSE response.
        guard let type = response.value(forHTTPHeaderField: "Content-Type") else { return true }
        return type.lowercased().split(separator: ";", omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "text/event-stream"
    }
}

// A terminal event is mandatory. Partial model text never reaches the hardware planner.
struct ChatGPTSSEAccumulator {
    private(set) var text = ""
    private(set) var completed = false
    private var dataLines: [String] = []
    private var bufferedBytes = 0
    private let requireSSEPrefix: Bool
    private var validatedPrefix = false
    init(requireSSEPrefix: Bool = false) { self.requireSSEPrefix = requireSSEPrefix }
    mutating func consume(line input: String) throws {
        guard !completed else { return }
        var line = input
        if requireSSEPrefix && !validatedPrefix {
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if !line.isEmpty && !line.hasPrefix(":") {
                guard ["data:", "event:", "id:", "retry:"].contains(where: { line.hasPrefix($0) }) else {
                    throw ChatGPTAuthError.message("ChatGPT 响应不是有效事件流。")
                }
                validatedPrefix = true
            }
        }
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
        try await requestResponse(model: model, instructions: instructions, task: task, jpeg: jpeg)
    }
    func textResponse(model: String, instructions: String, task: String) async throws -> String {
        try await requestResponse(model: model, instructions: instructions, task: task, jpeg: nil)
    }
    private func requestResponse(model: String, instructions: String, task: String, jpeg: Data?) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await ChatGPTOAuth.shared.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = try ChatGPTRequestProfile.body(model: model, instructions: instructions, task: task, jpeg: jpeg)
        let (bytes, response) = try await ChatGPTHTTP.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthError.message("ChatGPT 网络响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { if data.count >= 16_384 { break }; data.append(byte) }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = root?["error"] as? [String: Any]
            if let code = error?["code"] as? String { throw ChatGPTAuthError.message(ChatGPTSSEAccumulator.message(code: code)) }
            throw ChatGPTAuthError.message("ChatGPT 请求未获准（HTTP \(http.statusCode)），请检查账户或稍后重试。")
        }
        guard ChatGPTResponsePolicy.acceptsEventStream(http, method: bytes.task.currentRequest?.httpMethod) else {
#if DEBUG
            let mime = http.mimeType?.lowercased()
            let categories = ["application/json": "json", "text/html": "html", "text/plain": "text_plain", "application/octet-stream": "octet_stream"]
            let category = mime.flatMap { categories[$0] } ?? (mime == nil ? "missing" : "other")
            let rawType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first.map(String.init)
            let rawCategory = rawType.flatMap { categories[$0] } ?? (rawType == nil ? "missing" : "other")
            print("[SightLatch ChatGPT] unexpected_response status=\(http.statusCode) content=\(category) header=\(rawCategory) official_url=\(http.url?.absoluteString == "https://api.openai.com/v1/responses") post=\(bytes.task.currentRequest?.httpMethod == "POST")")
            // Only classify a bounded body. Never log headers, URLs, text, tokens or arbitrary server strings.
            var prefix = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                if prefix.count >= 16_384 { break }
                prefix.append(byte)
                if prefix.count == 512,
                   let beginning = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   beginning.hasPrefix("data:") || beginning.hasPrefix("event:") || beginning.hasPrefix("<!doctype html") || beginning.hasPrefix("<html") { break }
            }
            let root = (try? JSONSerialization.jsonObject(with: prefix)) as? [String: Any]
            let text = String(data: prefix.prefix(512), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let shape = root != nil ? "json_object" : text.hasPrefix("data:") || text.hasPrefix("event:") ? "sse_prefix" : text.hasPrefix("<!doctype html") || text.hasPrefix("<html") ? "html_prefix" : prefix.isEmpty ? "empty" : "other"
            let object = root?["object"] as? String == "response" ? "response" : "other"
            let status = root?["status"] as? String
            let state = ["completed", "failed", "incomplete", "in_progress", "queued"].contains(status ?? "") ? status! : "other"
            print("[SightLatch ChatGPT] response_shape=\(shape) bytes=\(prefix.count) object=\(object) state=\(state) has_error=\(root?["error"] != nil) has_detail=\(root?["detail"] != nil)")
#endif
            throw ChatGPTAuthError.message("ChatGPT 没有返回所需事件流。")
        }
        var parser = ChatGPTSSEAccumulator(requireSSEPrefix: http.value(forHTTPHeaderField: "Content-Type") == nil)
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
