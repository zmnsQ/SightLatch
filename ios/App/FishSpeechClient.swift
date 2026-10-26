import Foundation
import Security

/// The model header is explicit: Fish otherwise falls back to its paid default.
enum FishSpeechModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case s21ProFree = "s2.1-pro-free"
    case s21Pro = "s2.1-pro"
    case s2Pro = "s2-pro"

    static let defaultModel: Self = .s21ProFree
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .s21ProFree: return "S2.1 Pro · 免费开发版"
        case .s21Pro: return "S2.1 Pro"
        case .s2Pro: return "S2 Pro"
        }
    }
}

struct FishSpeechConfiguration: Equatable, Sendable {
    var model: FishSpeechModel = .defaultModel
    var referenceID: String = ""
}

enum FishSpeechError: Error, LocalizedError, Equatable {
    case missingAPIKey, invalidAPIKey, invalidVoice, invalidText
    case unauthorized, noCredit, rateLimited, unavailable, invalidAudio, audioTooLarge
    case timedOut, connection, keychain

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请先保存 Fish Audio API Key。"
        case .invalidAPIKey: return "API Key 格式不正确，请重新粘贴。"
        case .invalidVoice: return "请填写有效的 Fish Audio 音色 ID。"
        case .invalidText: return "这段播报暂时无法生成，请缩短后重试。"
        case .unauthorized: return "Fish Audio 密钥无效或无权使用此音色，请检查设置。"
        case .noCredit: return "Fish Audio 余额不足，请检查账户或选择免费开发版。"
        case .rateLimited: return "Fish Audio 请求较多，请稍后再试。"
        case .unavailable: return "Fish Audio 暂时不可用，请稍后再试。"
        case .invalidAudio: return "Fish Audio 未返回可播放的音频，请重试。"
        case .audioTooLarge: return "本次语音过长，未播放。"
        case .timedOut: return "Fish Audio 响应超时，请稍后再试。"
        case .connection: return "暂时无法连接 Fish Audio，请检查网络。"
        case .keychain: return "无法读写 Fish Audio 密钥，请解锁设备后重试。"
        }
    }
}

/// App-only credentials: never included in workspace exports or shared task files.
enum FishSpeechKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "SightLatch.FishAudio",
         kSecAttrAccount as String: "https://api.fish.audio/v1/tts"]
    }

    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw FishSpeechError.keychain }
        return key.isEmpty ? nil : key
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw FishSpeechError.keychain }
            return
        }
        try FishSpeechClient.validateAPIKey(key)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, new in new }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw FishSpeechError.keychain }
        } else if status != errSecSuccess { throw FishSpeechError.keychain }
    }
}

/// Short task feedback only. No synthesis retry, disk cache, or fallback voice.
struct FishSpeechClient: Sendable {
    static let endpoint = URL(string: "https://api.fish.audio/v1/tts")!
    static let maximumAudioBytes = 4 * 1024 * 1024
    private let protocolClasses: [AnyClass]?

    init() { protocolClasses = nil }
    // Allows a local URLProtocol fixture; production always uses the fixed HTTPS endpoint.
    init(protocolClasses: [AnyClass]) { self.protocolClasses = protocolClasses }

    func synthesize(text: String, configuration: FishSpeechConfiguration,
                    apiKey: String) async throws -> Data {
        try Task.checkCancellation()
        let request = try Self.makeRequest(text: text, configuration: configuration, apiKey: apiKey)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let session = URLSession(configuration: config, delegate: FishSpeechRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            try Self.validateResponse(response)
            var audio = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard audio.count < Self.maximumAudioBytes else { throw FishSpeechError.audioTooLarge }
                audio.append(byte)
            }
            try Task.checkCancellation()
            guard Self.hasMP3Signature(audio) else { throw FishSpeechError.invalidAudio }
            return audio
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FishSpeechError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? FishSpeechError.timedOut : FishSpeechError.connection
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw FishSpeechError.connection
        }
    }

    static func validateAPIKey(_ key: String) throws {
        guard !key.isEmpty else { throw FishSpeechError.missingAPIKey }
        guard key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw FishSpeechError.invalidAPIKey
        }
    }

    static func makeRequest(text: String, configuration: FishSpeechConfiguration, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateAPIKey(key)
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 1200 else { throw FishSpeechError.invalidText }
        let referenceID = configuration.referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard referenceID.count <= 128,
              referenceID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw FishSpeechError.invalidVoice }
        var body: [String: Any] = ["text": phrase, "format": "mp3", "mp3_bitrate": 128,
                                  "latency": "normal", "normalize": true]
        if !referenceID.isEmpty { body["reference_id"] = referenceID }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(configuration.model.rawValue, forHTTPHeaderField: "model")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw FishSpeechError.invalidAudio }
        switch http.statusCode {
        case 200...299: break
        case 400, 404, 422: throw FishSpeechError.invalidVoice
        case 401, 403: throw FishSpeechError.unauthorized
        case 402: throw FishSpeechError.noCredit
        case 429: throw FishSpeechError.rateLimited
        default: throw FishSpeechError.unavailable
        }
        guard http.expectedContentLength <= maximumAudioBytes else { throw FishSpeechError.audioTooLarge }
        // Some gateways return binary data without the audio MIME type. The MP3 signature is checked below.
        if let mime = http.mimeType?.lowercased(),
           !["audio/mpeg", "audio/mp3", "audio/x-mpeg", "application/octet-stream"].contains(mime) {
            throw FishSpeechError.invalidAudio
        }
    }

    static func hasMP3Signature(_ audio: Data) -> Bool {
        let prefix = Array(audio.prefix(4))
        guard prefix.count == 4 else { return false }
        if prefix[0...2].elementsEqual([0x49, 0x44, 0x33]) { return audio.count >= 10 }
        // MPEG audio frame sync, valid version/layer, and non-reserved bitrate/sample-rate.
        return prefix[0] == 0xff && prefix[1] & 0xe0 == 0xe0 &&
            prefix[1] & 0x18 != 0x08 && prefix[1] & 0x06 != 0 &&
            prefix[2] & 0xf0 != 0xf0 && prefix[2] & 0x0c != 0x0c
    }
}

/// Never forward the Bearer token or speech text to a redirect destination.
final class FishSpeechRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
