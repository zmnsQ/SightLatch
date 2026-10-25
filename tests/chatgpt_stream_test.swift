import Foundation

enum ChatGPTAuthError: Error { case message(String) }

func response(_ type: String? = nil, url: String = "https://api.openai.com/v1/responses", status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/2", headerFields: type.map { ["Content-Type": $0] } ?? [:])!
}
func mustFail(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Invalid stream accepted") } catch {}
}

@main struct StreamTests {
    static func main() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        func payload(_ model: String, jpeg: Data?) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: ChatGPTRequestProfile.body(model: model,
                instructions: "Choose one action", task: "Observe this screen", jpeg: jpeg)) as! [String: Any]
        }
        let visual = try payload("gpt-6.1-sol", jpeg: jpeg)
        precondition(visual["model"] as? String == "gpt-6.1-sol")
        precondition((visual["reasoning"] as? [String: String]) == ["effort": "low"])
        precondition(visual["store"] as? Bool == false && visual["stream"] as? Bool == true)
        precondition(visual["service_tier"] == nil)
        let input = visual["input"] as! [[String: Any]], content = input[0]["content"] as! [[String: Any]]
        precondition(content.count == 2 && content[0]["type"] as? String == "input_text")
        precondition(content[1]["image_url"] as? String == "data:image/jpeg;base64," + jpeg.base64EncodedString())
        precondition(content[1]["detail"] as? String == "original")
        let planning = try payload("gpt-6.1-sol", jpeg: nil)
        precondition(planning["reasoning"] == nil)
        precondition(Set(planning.keys) == Set(["model", "instructions", "store", "stream", "input"]))
        for model in ["gpt-4.1", "unknown-model", "gpt-6.1-sol-preview", "gpt-6.1-sol-2026-10-23"] {
            let other = try payload(model, jpeg: jpeg)
            precondition(other["model"] as? String == model && other["reasoning"] == nil)
            let otherInput = other["input"] as! [[String: Any]]
            let otherContent = otherInput[0]["content"] as! [[String: Any]]
            precondition(otherContent.count == 2 && otherContent[1]["detail"] as? String == "low")
        }
        precondition(ChatGPTResponsePolicy.acceptsEventStream(response(), method: "POST"))
        precondition(ChatGPTResponsePolicy.acceptsEventStream(response("Text/Event-Stream; charset=utf-8"), method: "POST"))
        for mime in ["application/json", "text/html", "", "text/event-stream-not-valid"] {
            precondition(!ChatGPTResponsePolicy.acceptsEventStream(response(mime), method: "POST"))
        }
        precondition(!ChatGPTResponsePolicy.acceptsEventStream(response(url: "https://example.com/v1/responses"), method: "POST"))
        precondition(!ChatGPTResponsePolicy.acceptsEventStream(response(status: 401), method: "POST"))
        precondition(!ChatGPTResponsePolicy.acceptsEventStream(response(), method: "GET"))
        var valid = ChatGPTSSEAccumulator(requireSSEPrefix: true)
        for line in [": keep-alive", "", "event: response.output_text.delta", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"计划\"}", "", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}", ""] {
            try valid.consume(line: line)
        }
        let result = try valid.result()
        precondition(result == "计划")
        for body in ["<html>not a stream</html>", "{\"status\":\"completed\"}"] {
            mustFail { var parser = ChatGPTSSEAccumulator(requireSSEPrefix: true); try parser.consume(line: body) }
        }
        mustFail {
            var incomplete = ChatGPTSSEAccumulator(requireSSEPrefix: true)
            try incomplete.consume(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}")
            try incomplete.consume(line: "")
            _ = try incomplete.result()
        }
        mustFail {
            var failed = ChatGPTSSEAccumulator(requireSSEPrefix: true)
            try failed.consume(line: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\"}}")
            try failed.consume(line: "")
        }
        print("PASS: documented model visual-only low effort and original image detail wire payload; unchanged text/unknown-model defaults; complete SSE required, MIME/URL/method/status and incomplete stream rejection")
    }
}
