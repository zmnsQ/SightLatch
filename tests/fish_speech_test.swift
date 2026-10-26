import Foundation

private final class FishSpeechFixture: URLProtocol, @unchecked Sendable {
    struct Reply {
        var code = 200
        var mime = "audio/mpeg"
        var data = Data([0xff, 0xfb, 0x90, 0x00, 1, 2, 3, 4])
        var declaredBytes: Int?
        var wait = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var stopped = false

    static func configure(_ value: Reply) {
        lock.lock(); defer { lock.unlock() }
        reply = value; requests = []; stopped = false
    }
    static var snapshot: (requests: [URLRequest], stopped: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stopped)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let reply = Self.reply
        Self.requests.append(request)
        Self.lock.unlock()
        if reply.wait { return }
        var headers = ["Content-Type": reply.mime]
        if let size = reply.declaredBytes { headers["Content-Length"] = String(size) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stopped = true
    }
}

@main
struct FishSpeechTests {
    static func expect(_ error: FishSpeechError, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("expected \(error)") }
        catch let actual as FishSpeechError { precondition(actual == error) }
        catch { preconditionFailure("unexpected \(error)") }
    }
    static func expectAsync(_ error: FishSpeechError, client: FishSpeechClient) async {
        do {
            _ = try await client.synthesize(text: "正在查看画面。", configuration: .init(), apiKey: "fixture-only-key")
            preconditionFailure("expected \(error)")
        } catch let actual as FishSpeechError { precondition(actual == error) }
        catch { preconditionFailure("unexpected \(error)") }
    }
    static func main() async throws {
        let request = try FishSpeechClient.makeRequest(text: "  正在查看画面。  ",
            configuration: .init(model: .s21Pro, referenceID: "voice_fixture-123"), apiKey: "fixture-only-key")
        precondition(request.url?.absoluteString == "https://api.fish.audio/v1/tts")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-key")
        precondition(request.value(forHTTPHeaderField: "model") == "s2.1-pro")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(request.timeoutInterval == 20)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["text"] as? String == "正在查看画面。")
        precondition(body["format"] as? String == "mp3")
        precondition(body["reference_id"] as? String == "voice_fixture-123")
        let defaultRequest = try FishSpeechClient.makeRequest(text: "你好", configuration: .init(), apiKey: "fixture-only-key")
        precondition(defaultRequest.value(forHTTPHeaderField: "model") == "s2.1-pro-free")
        let defaultBody = try JSONSerialization.jsonObject(with: defaultRequest.httpBody!) as! [String: Any]
        precondition(defaultBody["reference_id"] == nil)
        precondition(defaultBody["apiKey"] == nil)
        expect(.missingAPIKey) { _ = try FishSpeechClient.makeRequest(text: "你好", configuration: .init(), apiKey: "") }
        expect(.invalidAPIKey) { _ = try FishSpeechClient.makeRequest(text: "你好", configuration: .init(), apiKey: "fixture\r\nInjected: value") }
        expect(.invalidText) { _ = try FishSpeechClient.makeRequest(text: " ", configuration: .init(), apiKey: "fixture") }
        expect(.invalidText) { _ = try FishSpeechClient.makeRequest(text: String(repeating: "你", count: 1201), configuration: .init(), apiKey: "fixture") }
        expect(.invalidVoice) { _ = try FishSpeechClient.makeRequest(text: "你好", configuration: .init(referenceID: "https://outside.test/voice"), apiKey: "fixture") }

        let client = FishSpeechClient(protocolClasses: [FishSpeechFixture.self])
        FishSpeechFixture.configure(.init())
        let audio = try await client.synthesize(text: "正在查看画面。", configuration: .init(), apiKey: "fixture-only-key")
        precondition(audio.count == 8 && FishSpeechFixture.snapshot.requests.count == 1)
        FishSpeechFixture.configure(.init(mime: "application/octet-stream"))
        _ = try await client.synthesize(text: "你好", configuration: .init(), apiKey: "fixture-only-key")
        FishSpeechFixture.configure(.init(mime: "application/json", data: Data("{\"api_key\":\"do-not-echo\"}".utf8)))
        await expectAsync(.invalidAudio, client: client)
        FishSpeechFixture.configure(.init(data: Data("not audio".utf8)))
        await expectAsync(.invalidAudio, client: client)
        FishSpeechFixture.configure(.init(declaredBytes: FishSpeechClient.maximumAudioBytes + 1))
        await expectAsync(.audioTooLarge, client: client)
        FishSpeechFixture.configure(.init(data: Data(repeating: 0xff, count: FishSpeechClient.maximumAudioBytes + 1)))
        await expectAsync(.audioTooLarge, client: client)
        for (status, error) in [(400, FishSpeechError.invalidVoice), (401, .unauthorized), (402, .noCredit),
                                (403, .unauthorized), (422, .invalidVoice), (429, .rateLimited), (500, .unavailable), (302, .unavailable)] {
            FishSpeechFixture.configure(.init(code: status, mime: "application/json", data: Data("do-not-echo-key-or-text".utf8)))
            await expectAsync(error, client: client)
            precondition(FishSpeechFixture.snapshot.requests.count == 1) // Errors never trigger billed retries.
            precondition(!error.localizedDescription.contains("do-not-echo"))
        }
        FishSpeechFixture.configure(.init(wait: true))
        let synthesis = Task {
            try await client.synthesize(text: "你好", configuration: .init(), apiKey: "fixture-only-key")
        }
        for _ in 0..<100 where FishSpeechFixture.snapshot.requests.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(FishSpeechFixture.snapshot.requests.count == 1)
        synthesis.cancel()
        do { _ = try await synthesis.value; preconditionFailure("cancelled speech must not succeed") }
        catch is CancellationError {}
        precondition(FishSpeechFixture.snapshot.stopped)

        let redirectSession = URLSession(configuration: .ephemeral)
        let redirectTask = redirectSession.dataTask(with: URL(string: "https://api.fish.audio/v1/tts")!)
        let redirect = HTTPURLResponse(url: FishSpeechClient.endpoint, statusCode: 307, httpVersion: nil,
            headerFields: ["Location": "https://other.example/tts"])!
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            FishSpeechRedirectPolicy().urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: redirect,
                newRequest: URLRequest(url: URL(string: "https://other.example/tts")!)) { next in
                    precondition(next == nil); done.resume()
                }
        }
        redirectSession.invalidateAndCancel()
        print("PASS: Fish TTS request contract, MP3 validation, byte caps, safe errors, no retries, cancellation, and redirect refusal")
    }
}
